/// 用户自填接口的三家格式共用的传输:发请求、收流、非流式回落、拉模型列表、连通测试。
/// 各家只管地址、鉴权头、请求体和响应字段(见 openai / gemini / anthropic 三个实现)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../l10n/l10n.dart';
import '../assistant_settings.dart' show ThinkLevel;
import '../custom_endpoint.dart';
import '../model_catalog.dart'
    show ModelDirectory, ModelDirectoryCache, declaredKind;
import '../domain/agent_event.dart' show AgentFailure;
import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'llm_provider.dart';
import 'openai_provider.dart';
import 'responses_provider.dart';
import 'ollama_provider.dart';

/// 这个接口按它的格式该用哪家实现。
HttpLlmProvider llmProviderFor(CustomEndpoint e) => switch (e.route) {
  EndpointRoute.chat => OpenAiProvider(e),
  EndpointRoute.responses => ResponsesProvider(e),
  EndpointRoute.gemini => GeminiProvider(e),
  EndpointRoute.messages => AnthropicProvider(e),
  EndpointRoute.ollama => OllamaProvider(e),
};

/// 两帧之间至少隔这么久。快的模型一秒吐几十个 token,每个都推一帧等于每秒几十次整块重建。
const _frameMs = 60;

abstract class HttpLlmProvider implements LlmProvider {
  HttpLlmProvider(this.endpoint);

  final CustomEndpoint endpoint;

  String get apiKey => endpoint.apiKey.trim();

  @override
  LlmCapabilities get capabilities =>
      const LlmCapabilities(streaming: true, thinking: true);

  /// 对话地址。
  Uri chatUri({required bool stream}) => endpoint.chatUri;

  /// 这家必带的头(鉴权、版本)。对话和拉模型列表都带。
  Map<String, String> get authHeaders;

  /// 请求体。带图的那条消息图在前、字在后,只发图时不塞空的文字段。
  Map<String, dynamic> requestBody(LlmRequest request, {required bool stream});

  /// 思考等级 → 请求体里的字段。[ThinkLevel.auto] 不发档位。
  Map<String, dynamic> thinkFields(ThinkLevel level);

  /// 流式响应的一帧 → 这一帧新增的字。认不出的帧当没字,不抛。
  LlmText parseDelta(Object? frame);

  /// 非流式响应 → 正文。思考摘要不算正文。形状不对返回空串。
  String parseResponse(Object? body);

  bool get newlineDelimited => false;

  /// 模型列表地址。
  Uri get modelsUri => endpoint.catalogUri;

  /// 模型列表响应 → 模型 id,去重、排序。形状不对返回空表。
  List<String> parseModels(Object? body);

  /// [parseModels] 共用的取法:每项取 `id`(没有取 `name`),去掉 `models/` 前缀。
  List<String> modelIdsOf(Object? list) {
    if (list is! List) return const [];
    final out = <String>[];
    for (final m in list) {
      if (m is! Map) continue;
      final id = (m['id'] ?? m['name'])?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final bare = id.startsWith('models/') ? id.substring(7) : id;
      if (bare.isNotEmpty && !out.contains(bare)) out.add(bare);
    }
    out.sort();
    return out;
  }

  @override
  Stream<LlmText> chat(
    LlmRequest request, {
    required http.Client client,
    bool stream = true,
    Duration? timeout,
  }) async* {
    final uri = chatUri(stream: stream);
    final req = http.Request('POST', uri)
      ..headers.addAll(
        endpoint.withHeaders({
          'Content-Type': 'application/json',
          'Accept': !stream
              ? 'application/json'
              : newlineDelimited
              ? 'application/x-ndjson'
              : 'text/event-stream',
          ...authHeaders,
        }),
      )
      ..bodyBytes = utf8.encode(
        jsonEncode(requestBody(request, stream: stream)),
      );

    final noReply = AgentFailure(
      l10nNow.modelNoReplyIn('${timeout?.inSeconds}'),
    );
    Future<T> limited<T>(Future<T> f) async {
      if (timeout == null) return f;
      try {
        return await f.timeout(timeout);
      } on TimeoutException {
        throw noReply;
      }
    }

    Future<String> readAll(http.StreamedResponse r) =>
        limited(r.stream.bytesToString());

    final http.StreamedResponse resp;
    try {
      resp = await limited(client.send(req));
    } on AgentFailure {
      rethrow;
    } catch (e) {
      throw AgentFailure('$e');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw AgentFailure.http(resp.statusCode, await readAll(resp));
    }
    final Stream<String> lines;
    final media = (resp.headers['content-type'] ?? '').toLowerCase();
    if (stream &&
        (media.contains('event-stream') ||
            (newlineDelimited && media.contains('ndjson')))) {
      final all = resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      lines = timeout == null
          ? all
          : all.timeout(timeout, onTimeout: (sink) => sink.addError(noReply));
    } else {
      // 没开流,或者中转不认流式:收完整段按非流式解析
      final raw = await readAll(resp);
      final text = parseResponse(_tryJson(raw));
      if (text.isNotEmpty ||
          !stream ||
          (!raw.contains('data:') &&
              !(newlineDelimited && raw.trim().contains('\n')))) {
        yield (text: text, reasoning: '');
        return;
      }
      // 类型写着 json、身子却是一串 SSE 帧:按帧收,只是整段一起到
      lines = Stream.fromIterable(const LineSplitter().convert(raw));
    }

    final text = StringBuffer();
    final reasoning = StringBuffer();
    var lastFrame = 0;
    await for (final line in lines) {
      // `event:` 行与 `:` 心跳不看:三家的 data 自带类型
      if (!newlineDelimited && !line.startsWith('data:')) continue;
      final data = newlineDelimited ? line.trim() : line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final frame = _tryJson(data);
      // Claude 的报错是流中间的一帧,不是 HTTP 状态码
      if (frame is Map &&
          (frame['error'] != null ||
              frame['type'] == 'error' ||
              frame['type'] == 'response.failed')) {
        throw AgentFailure(endpoint.redactSecrets(data));
      }
      final d = parseDelta(frame);
      if (d.text.isEmpty && d.reasoning.isEmpty) continue;
      text.write(d.text);
      reasoning.write(d.reasoning);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastFrame < _frameMs) continue;
      lastFrame = now;
      yield (text: text.toString(), reasoning: reasoning.toString());
    }
    // 收尾补一帧:最后几个字多半还卡在上面那道攒帧里
    yield (text: text.toString(), reasoning: reasoning.toString());
  }

  /// 拉模型列表。失败抛 [AgentFailure],内容是原始错误。
  Future<List<String>> listModels({http.Client? client}) async =>
      (await modelCatalog(client: client)).keys.toList();

  Future<Map<String, EndpointModelKind>> modelCatalog({
    http.Client? client,
  }) async =>
      (await discoverModels(client: client)).map((k, v) => MapEntry(k, v.kind));

  Future<Map<String, CatalogModel>> discoverModels({
    http.Client? client,
    Future<ModelDirectory> Function(http.Client)? loadDirectory,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final rowsById = <String, Map>{};
      final out = <String, CatalogModel>{};
      final transportHints = <String, EndpointModelKind>{};
      final preset = endpoint.preset?.label;
      final seen = <Uri>{};
      final firstPage = preset == 'OpenRouter'
          ? modelsUri.replace(
              path: '${modelsUri.path}/user',
              queryParameters: {
                ...modelsUri.queryParameters,
                'output_modalities': 'all',
              },
            )
          : modelsUri;
      Uri? next = firstPage;
      while (next != null && seen.add(next)) {
        final page = await _catalogPage(c, next);
        final rows = page['data'] ?? page['models'];
        final details = {
          if (rows is List)
            for (final row in rows.whereType<Map>())
              (row['id'] ?? row['name'] ?? '').toString().trim().replaceFirst(
                RegExp(r'^models/'),
                '',
              ): row,
        };
        for (final id in parseModels(page)) {
          final row = details[id] ?? {};
          rowsById[id] = row;
          final kind = declaredKind(row, anthropic: preset == 'Claude');
          out[id] = kind == EndpointModelKind.unknown
              ? CatalogModel.unknown
              : CatalogModel(kind, ModelEvidence.provider);
        }
        final current = next;
        final token = page['nextPageToken'];
        final last = page['last_id'];
        next = token is String && token.isNotEmpty
            ? firstPage.replace(
                queryParameters: {
                  ...firstPage.queryParameters,
                  'pageToken': token,
                },
              )
            : page['has_more'] == true && last is String && last.isNotEmpty
            ? firstPage.replace(
                queryParameters: {
                  ...firstPage.queryParameters,
                  'after_id': last,
                },
              )
            : null;
        final links = page['links'];
        if (next == null && links is Map && links['next'] is String) {
          final more = current.resolve(links['next'] as String);
          if (more.isScheme(current.scheme) &&
              more.host == current.host &&
              more.port == current.port &&
              more.path == firstPage.path &&
              more.userInfo.isEmpty) {
            next = more;
          }
        }
      }
      if (preset == 'OpenRouter') {
        try {
          final imagePage = await _catalogPage(
            c,
            endpoint.uriForPath('/images/models'),
          );
          for (final id in modelIdsOf(imagePage['data'])) {
            // The global image directory may include models excluded by this key.
            final prior = out[id]?.kind;
            if (prior == null) continue;
            out[id] = CatalogModel(
              prior.supports(false)
                  ? EndpointModelKind.chatAndImage
                  : EndpointModelKind.image,
              ModelEvidence.provider,
            );
          }
        } on AgentFailure {
          if (out.isEmpty) rethrow;
        }
      }
      if (out.isEmpty) throw AgentFailure(l10nNow.epNoModels);
      if (endpoint.route == EndpointRoute.ollama) {
        final ids = out.keys
            .where((id) => out[id]!.kind == EndpointModelKind.unknown)
            .toList();
        for (var start = 0; start < ids.length; start += 6) {
          await Future.wait(
            ids.skip(start).take(6).map((id) async {
              try {
                final resp = await c
                    .post(
                      modelsUri.resolve('show'),
                      headers: endpoint.withHeaders({
                        'Content-Type': 'application/json',
                        ...authHeaders,
                      }),
                      body: jsonEncode({'model': id}),
                    )
                    .timeout(const Duration(seconds: 5));
                if (resp.statusCode != 200) return;
                final data = _tryJson(utf8.decode(resp.bodyBytes));
                if (data is! Map) return;
                final kind = declaredKind(data);
                if (kind != EndpointModelKind.unknown) {
                  out[id] = CatalogModel(kind, ModelEvidence.provider);
                }
              } on Exception {
                /* Older servers may omit model details. */
              }
            }),
          );
        }
      } else if (preset == null &&
          out.values.any((v) => v.kind == EndpointModelKind.unknown)) {
        // Optional New API metadata is public on some relays. Never send the user's key or URL query.
        final base = Uri.parse(endpoint.effectiveBase);
        final prefix = base.path
            .replaceFirst(RegExp(r'/(?:v\d+(?:beta|alpha)?|api)/?$'), '')
            .replaceFirst(RegExp(r'/$'), '');
        final pricing = Uri(
          scheme: base.scheme,
          host: base.host,
          port: base.hasPort ? base.port : null,
          path: '$prefix/api/pricing',
        );
        try {
          final response = await c
              .get(pricing)
              .timeout(const Duration(seconds: 4));
          final body = response.statusCode == 200
              ? _tryJson(utf8.decode(response.bodyBytes))
              : null;
          final rows = body is Map ? body['data'] : null;
          final definitions = body is Map ? body['supported_endpoint'] : null;
          if (rows is List) {
            for (final row in rows.whereType<Map>()) {
              final id = row['model_name'];
              if (id is! String || out[id]?.kind != EndpointModelKind.unknown) {
                continue;
              }
              final types = row['supported_endpoint_types'];
              final enriched = {
                ...row,
                if (types is List && definitions is Map)
                  'supported_endpoint_types': [
                    ...types,
                    for (final t in types)
                      if (definitions['$t'] case {'path': final String path})
                        path,
                  ],
              };
              final kind = declaredKind(enriched);
              if (kind == EndpointModelKind.chat && types is List) {
                // A chat-compatible transport may also carry image output.
                transportHints[id] = kind;
                continue;
              }
              if (kind != EndpointModelKind.unknown) {
                out[id] = CatalogModel(kind, ModelEvidence.provider);
              }
            }
          }
        } on Exception {
          /* Normal for stations that only implement /models. */
        }
      }
      final missing = out.keys
          .where((id) => out[id]!.kind == EndpointModelKind.unknown)
          .toList();
      if (missing.isNotEmpty) {
        final directory =
            await (loadDirectory ?? ModelDirectoryCache.shared.load)(c);
        final vendor = switch (preset) {
          'OpenAI' => 'openai',
          'Gemini' => 'google',
          'Claude' => 'anthropic',
          'DeepSeek' => 'deepseek',
          _ => null,
        };
        for (final id in missing) {
          final row = rowsById[id] ?? {};
          final kind = directory.lookup(
            id,
            vendor: vendor ?? row['owned_by']?.toString(),
            canonical:
                (row['canonical_slug'] ??
                        row['canonical_id'] ??
                        row['upstream_model'])
                    ?.toString(),
          );
          if (kind != EndpointModelKind.unknown) {
            out[id] = CatalogModel(kind, ModelEvidence.directory);
          } else if (transportHints[id] case final hint?) {
            out[id] = CatalogModel(hint, ModelEvidence.provider);
          }
        }
      }
      return Map.fromEntries(
        out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      );
    } finally {
      if (own) c.close();
    }
  }

  Future<Map> _catalogPage(http.Client client, Uri uri) async {
    final http.Response resp;
    try {
      resp = await client
          .get(uri, headers: endpoint.withHeaders(authHeaders))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw AgentFailure(endpoint.redactSecrets('$e'));
    }
    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw AgentFailure.http(resp.statusCode, endpoint.redactSecrets(body));
    }
    final data = _tryJson(body);
    return data is Map ? data : const {};
  }

  /// 发一条最短的对话,确认地址、Key、模型、格式对得上。成功返回用时;
  /// 失败抛 [AgentFailure]。等两分钟为止。
  Future<Duration> ping({http.Client? client}) async {
    final own = client == null;
    final c = client ?? http.Client();
    final sw = Stopwatch()..start();
    try {
      final reply = await chat(
        const LlmRequest(
          system: 'Reply with the single word OK.',
          messages: [(role: 'user', content: 'ping', images: [])],
        ),
        client: c,
        stream: false,
        timeout: const Duration(seconds: 120),
      ).last;
      if (reply.text.trim().isEmpty) {
        throw AgentFailure(l10nNow.replyUnreadable);
      }
      return sw.elapsed;
    } finally {
      if (own) c.close();
    }
  }
}

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}
