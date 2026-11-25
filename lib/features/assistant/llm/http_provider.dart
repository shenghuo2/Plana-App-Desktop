/// 用户自填接口的三家格式共用的传输:发请求、收流、非流式回落、拉模型列表、连通测试。
/// 各家只管地址、鉴权头、请求体和响应字段(见 openai / gemini / anthropic 三个实现)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../l10n/l10n.dart';
import '../assistant_settings.dart' show ThinkLevel;
import '../custom_endpoint.dart';
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
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final out = <String, EndpointModelKind>{};
      final seen = <Uri>{};
      Uri? next = modelsUri;
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
          out[id] = modelKind(id, details[id]);
        }
        final token = page['nextPageToken'];
        final last = page['last_id'];
        next = token is String && token.isNotEmpty
            ? modelsUri.replace(
                queryParameters: {
                  ...modelsUri.queryParameters,
                  'pageToken': token,
                },
              )
            : page['has_more'] == true && last is String && last.isNotEmpty
            ? modelsUri.replace(
                queryParameters: {
                  ...modelsUri.queryParameters,
                  'after_id': last,
                },
              )
            : null;
      }
      if (endpoint.preset?.label == 'OpenRouter') {
        try {
          final imagePage = await _catalogPage(
            c,
            endpoint.uriForPath('/images/models'),
          );
          for (final id in modelIdsOf(imagePage['data'])) {
            out[id] = EndpointModelKind.image;
          }
        } on AgentFailure catch (error) {
          if (out.isEmpty || (error.status != 404 && error.status != 405)) {
            rethrow;
          }
        }
      }
      if (out.isEmpty) throw AgentFailure(l10nNow.epNoModels);
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
