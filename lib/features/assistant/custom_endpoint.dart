/// 自定义 AI 接口:用户自己填的大模型地址,助手可以不走 Plana 后端直连它。
///
/// **存在加密存储里**,因为条目带 API Key —— 与 NAI 令牌同一条规矩
/// (见 `secure_storage.dart`:读写点一律走共享的那份配置,别自建)。
///
/// 选了它,整轮在本机跑(见 `runtime/direct_runtime.dart`),报文格式见 `llm/`。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/secure_storage.dart';

const _key = 'assistant_endpoints';

/// 接口的报文格式。三家的鉴权头、请求体、模型列表路径都不一样。
enum AgentApiFormat {
  /// OpenAI 兼容(`/chat/completions`,`Authorization: Bearer`)。
  /// 绝大多数第三方中转、本地推理都是这个。
  openai,

  /// Google Gemini(`/models/{model}:generateContent`,`x-goog-api-key`)。
  google,

  /// Anthropic(`/messages`,`x-api-key` + `anthropic-version`)。
  anthropic,
}

/// 分段选择器上那三个字。用大家叫得出口的名字(Gemini / Claude),
/// 不用公司名 —— 三段并排放不下「Google Gemini」这种长度。
String agentApiFormatLabel(AgentApiFormat f) => switch (f) {
  AgentApiFormat.openai => 'OpenAI',
  AgentApiFormat.google => 'Gemini',
  AgentApiFormat.anthropic => 'Claude',
};

/// 各家默认基址。用户留空时用它,省得为官方地址还要查一遍文档。
String agentApiDefaultBase(AgentApiFormat f) => switch (f) {
  AgentApiFormat.openai => 'https://api.openai.com/v1',
  AgentApiFormat.google => 'https://generativelanguage.googleapis.com/v1beta',
  AgentApiFormat.anthropic => 'https://api.anthropic.com/v1',
};

/// 各家的对话接口路径。中转服务改路径是常事,所以它可填。
///
/// Gemini 那条**把模型名写在路径里**,所以用 `{model}` 占位,发请求时替换。
String agentApiDefaultPath(AgentApiFormat f) => switch (f) {
  AgentApiFormat.openai => '/chat/completions',
  AgentApiFormat.google => '/models/{model}:generateContent',
  AgentApiFormat.anthropic => '/messages',
};

/// A relay may expose one of these request formats at a custom path.
enum EndpointRoute {
  chat('OpenAI Chat Completions', '/chat/completions', AgentApiFormat.openai),
  responses('OpenAI Responses', '/responses', AgentApiFormat.openai),
  messages('Anthropic Messages', '/messages', AgentApiFormat.anthropic),
  gemini(
    'Gemini generateContent',
    '/models/{model}:generateContent',
    AgentApiFormat.google,
  ),
  ollama('Ollama Chat Completions', '/api/chat', AgentApiFormat.openai);

  const EndpointRoute(this.label, this.path, this.format);
  final String label;
  final String path;
  final AgentApiFormat format;

  static EndpointRoute defaultFor(AgentApiFormat format) => switch (format) {
    AgentApiFormat.openai => chat,
    AgentApiFormat.google => gemini,
    AgentApiFormat.anthropic => messages,
  };

  static EndpointRoute? match(String value) {
    final path = '/${value.trim().split('?').first.toLowerCase()}'
        .replaceAll(RegExp(r'/+'), '/')
        .replaceFirst(RegExp(r'/$'), '');
    for (final r in values) {
      if (path.endsWith(r.path.toLowerCase())) return r;
    }
    if (path.endsWith(':generatecontent') ||
        path.endsWith(':streamgeneratecontent')) {
      return gemini;
    }
    return null;
  }
}

enum EndpointModelKind { chat, image, other, unknown }

EndpointModelKind modelKind(String id, [Map? details]) {
  final arch = details?['architecture'];
  final output =
      details?['output_modalities'] ??
      details?['outputModalities'] ??
      (arch is Map ? arch['output_modalities'] : null);
  if (output is List && output.isNotEmpty) {
    final values = output.map((s) => '$s'.toLowerCase()).toSet();
    if (values.contains('image')) return EndpointModelKind.image;
    return values.contains('text')
        ? EndpointModelKind.chat
        : EndpointModelKind.other;
  }
  final name = id.toLowerCase().split('/').last;
  final methods = details?['supportedGenerationMethods'];
  if (methods is List &&
      methods.isNotEmpty &&
      !methods.contains('generateContent') &&
      !methods.contains('predict')) {
    return EndpointModelKind.other;
  }
  if (RegExp(
    r'^(gpt-image|chatgpt-image|dall-e|imagen[-0-9]|flux[-.0-9]|stable-(diffusion|image)|seedream|qwen-image|nano-banana)|^gemini-.*(?:-image(?:-|$)|-banana)',
  ).hasMatch(name)) {
    return EndpointModelKind.image;
  }
  if (RegExp(
    r'embed|rerank|^tts-|^whisper|transcrib|moderation|^sora|^veo-|speech|^lyria|audio-preview|realtime',
  ).hasMatch(name)) {
    return EndpointModelKind.other;
  }
  if (RegExp(
    r'^(gpt-|chatgpt-|o[1-9](?:-|$)|claude|deepseek|gemini|llama|qwen|glm|grok|mistral)',
  ).hasMatch(name)) {
    return EndpointModelKind.chat;
  }
  return EndpointModelKind.unknown;
}

/// 添加接口时可以直接选的服务:格式和地址都带好。不在表里的走「自定义」自己填。
class EndpointPreset {
  const EndpointPreset(this.label, this.format, this.base, this.keyUrl);

  final String label;
  final AgentApiFormat format;
  final String base;

  bool get offersImages =>
      label == 'OpenAI' || label == 'Gemini' || label == 'OpenRouter';

  /// 创建 API Key 的页面。
  final String keyUrl;

  /// 这个格式的官方服务;选择页分在「官方」一组。
  bool get official => base == agentApiDefaultBase(format);
}

const kEndpointPresets = [
  EndpointPreset(
    'OpenAI',
    AgentApiFormat.openai,
    'https://api.openai.com/v1',
    'https://platform.openai.com/api-keys',
  ),
  EndpointPreset(
    'Gemini',
    AgentApiFormat.google,
    'https://generativelanguage.googleapis.com/v1beta',
    'https://aistudio.google.com/apikey',
  ),
  EndpointPreset(
    'Claude',
    AgentApiFormat.anthropic,
    'https://api.anthropic.com/v1',
    'https://console.anthropic.com/settings/keys',
  ),
  EndpointPreset(
    'DeepSeek',
    AgentApiFormat.openai,
    'https://api.deepseek.com/v1',
    'https://platform.deepseek.com/api_keys',
  ),
  EndpointPreset(
    'OpenRouter',
    AgentApiFormat.openai,
    'https://openrouter.ai/api/v1',
    'https://openrouter.ai/keys',
  ),
];

/// 按格式 + 地址认出是哪一家;认不出(中转、自建)返回 null。地址留空的按该格式的官方地址算。
EndpointPreset? endpointPresetOf(AgentApiFormat format, String baseUrl) {
  String norm(String u) =>
      u.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
  final b = norm(baseUrl.isEmpty ? agentApiDefaultBase(format) : baseUrl);
  for (final p in kEndpointPresets) {
    if (p.format == format && norm(p.base) == b) return p;
  }
  return null;
}

/// 填进来的地址 → 基址:去掉末尾斜杠,连对话路径一起贴进来的把路径切掉
/// (`…/v1/chat/completions` → `…/v1`),不然发请求时路径会拼两遍。
String normalizeEndpointBase(String raw, AgentApiFormat format) {
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasAuthority) return text;
  final tail = RegExp(
    r'/(?:chat/completions|responses|messages|api/chat|models/[^/]+:(?:stream)?generateContent)$',
    caseSensitive: false,
  );
  final path = uri.path.replaceAll(RegExp(r'/+$'), '').replaceFirst(tail, '');
  return uri.replace(path: path).toString();
}

class CustomEndpoint {
  const CustomEndpoint({
    required this.id,
    required this.name,
    required this.format,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.models = const [],
    this.imageModels = const [],
    this.apiPath = '',
    this.enabled = true,
    this.customService = false,
    this.wire,
    this.headers = const {},
  });

  final String id;
  final bool enabled;
  final bool customService;
  final EndpointRoute? wire;

  EndpointRoute get route =>
      EndpointRoute.match(apiPath) ?? wire ?? EndpointRoute.defaultFor(format);
  EndpointPreset? get preset =>
      customService ? null : endpointPresetOf(format, baseUrl);
  bool get offersImages =>
      customService ||
      (preset?.offersImages ?? format != AgentApiFormat.anthropic);
  bool get hasCredentials {
    if (apiKey.trim().isNotEmpty) return true;
    final host = Uri.tryParse(effectiveBase)?.host.toLowerCase();
    return route == EndpointRoute.ollama &&
        (host == 'localhost' || host == '127.0.0.1' || host == '::1');
  }

  /// 界面上显示的名字。空的话按地址认出的服务名或主机名。
  final String name;

  final AgentApiFormat format;

  /// 末尾无斜杠。空 = 用 [agentApiDefaultBase]。
  final String baseUrl;

  final String apiKey;

  /// 这一次请求用的模型 id,如 `gpt-5.6-luna` / `gemini-3.7-flash` / `claude-sonnet-4-6`。
  /// 读存档时是 [models] 的第一个,选了别的用 [forModel] 换。
  final String model;

  /// 这个接口下存的全部模型。
  final List<String> models;

  /// Models explicitly assigned to image generation.
  final List<String> imageModels;

  /// 这个接口能不能出图:格式支持、填了 Key、有出图模型。
  bool get usesGoogleImages =>
      (preset?.format ?? route.format) == AgentApiFormat.google;

  bool get canDraw =>
      enabled && offersImages && hasCredentials && imageModels.isNotEmpty;

  /// [models] 为空时(只给了 [model] 的)按 [model] 一个算。
  List<String> get allModels =>
      models.isNotEmpty ? models : [if (model.isNotEmpty) model];

  /// 换成用 [m] 发请求。
  CustomEndpoint forModel(String m) => copyWith(model: m);

  /// 对话接口路径。空 = 用 [agentApiDefaultPath]。`{model}` 会被替换成模型名。
  final String apiPath;

  /// 自定义请求头,对话和拉模型列表都带。
  final Map<String, String> headers;

  /// [builtIn] 叠上 [headers]。头名不分大小写,同名的以 [headers] 为准。
  Map<String, String> withHeaders(Map<String, String> builtIn) {
    if (headers.isEmpty) return builtIn;
    final merged = Map<String, String>.of(builtIn);
    for (final entry in headers.entries) {
      merged.removeWhere(
        (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
      );
      merged[entry.key] = entry.value;
    }
    return merged;
  }

  /// 中转报错可能回显鉴权信息；显示及保存错误之前移除本次请求的密钥值。
  String redactSecrets(String message) {
    final secrets =
        {
            apiKey.trim(),
            ...headers.values.map((v) => v.trim()),
          }.where((v) => v.isNotEmpty).toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in secrets) {
      message = message.replaceAll(secret, '[已隐藏]');
    }
    return message;
  }

  String get displayName => name.trim().isNotEmpty
      ? name.trim()
      : allModels.length == 1
      ? allModels.single
      : providerLabel;

  /// 地址认得出是哪家就写那家,认不出写主机名。
  String get providerLabel =>
      preset?.label ?? Uri.tryParse(effectiveBase)?.host ?? effectiveBase;

  String get effectiveBase {
    final b = baseUrl.trim();
    return (b.isEmpty ? agentApiDefaultBase(format) : b).replaceAll(
      RegExp(r'/+$'),
      '',
    );
  }

  /// 拼在 [effectiveBase] 后面的那一段。开头补斜杠,`{model}` 就地替换。
  String get effectivePath {
    final raw = apiPath.trim().isEmpty ? route.path : apiPath.trim();
    final withSlash = raw.startsWith('/') ? raw : '/$raw';
    return withSlash.replaceAll('{model}', model.trim());
  }

  /// 完整的对话接口地址(非流式)。流式地址各家不同,见 `llm/` 下的实现。
  Uri get chatUri => uriForPath(effectivePath);

  Uri uriForPath(String relative) {
    final base = Uri.parse(effectiveBase);
    final route = Uri.parse(relative);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    var suffix = route.path.startsWith('/') ? route.path : '/${route.path}';
    final tail = base.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (tail != null &&
        RegExp(r'^(v[0-9]+(?:(?:alpha|beta)[0-9]*)?|api)$').hasMatch(tail) &&
        suffix.startsWith('/$tail/')) {
      suffix = suffix.substring(tail.length + 1);
    }
    final query = {...base.queryParameters, ...route.queryParameters};
    return base
        .replace(
          path: prefix.endsWith(suffix) ? prefix : '$prefix$suffix',
          queryParameters: query.isEmpty ? null : query,
        )
        .removeFragment();
  }

  Uri get catalogUri {
    final chat = chatUri;
    final tail = RegExp(
      r'/(?:chat/completions|responses|messages|models/[^/]+:(?:stream)?generateContent)$',
      caseSensitive: false,
    );
    return tail.hasMatch(chat.path)
        ? chat.replace(path: chat.path.replaceFirst(tail, '/models'))
        : uriForPath('/models');
  }

  Uri get chatStreamUri {
    if (route != EndpointRoute.gemini) return chatUri;
    final u = chatUri.replace(
      path: chatUri.path.replaceFirst(
        ':generateContent',
        ':streamGenerateContent',
      ),
    );
    return u.replace(queryParameters: {...u.queryParameters, 'alt': 'sse'});
  }

  /// 填全了才能用。缺一样就发不出去,列表里置灰。
  bool get usable => enabled && hasCredentials && model.trim().isNotEmpty;

  CustomEndpoint copyWith({
    bool? enabled,
    bool? customService,
    EndpointRoute? wire,
    String? name,
    AgentApiFormat? format,
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
    List<String>? imageModels,
    String? apiPath,
    Map<String, String>? headers,
  }) => CustomEndpoint(
    id: id,
    enabled: enabled ?? this.enabled,
    customService: customService ?? this.customService,
    wire: wire ?? this.wire,
    name: name ?? this.name,
    format: format ?? this.format,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    models: models ?? this.models,
    imageModels: imageModels ?? this.imageModels,
    apiPath: apiPath ?? this.apiPath,
    headers: headers ?? this.headers,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'typedModels': true,
    if (customService) 'customService': true,
    if (wire != null) 'wire': wire!.name,
    'name': name,
    'format': format.name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': allModels.firstOrNull ?? '',
    'models': allModels,
    if (imageModels.isNotEmpty) 'imageModels': imageModels,
    if (apiPath.isNotEmpty) 'apiPath': apiPath,
    if (headers.isNotEmpty) 'headers': headers,
  };

  static CustomEndpoint? fromJson(Object? e) {
    if (e is! Map) return null;
    final id = e['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final single = e['model']?.toString() ?? '';
    final models = switch (e['models']) {
      final List l when l.isNotEmpty => [
        for (final m in l)
          if ('$m'.trim().isNotEmpty) '$m'.trim(),
      ],
      _ => [if (single.isNotEmpty) single],
    };
    final savedImages = [
      if (e['imageModels'] case final List l)
        for (final m in l) '$m'.trim(),
    ];
    final images = <String>[], chats = <String>[];
    final assigned = <String>{};
    final typed = e['typedModels'] == true;
    void assign(String id, {required bool image}) {
      if (id.isEmpty || !assigned.add(id.toLowerCase())) return;
      final kind = typed ? EndpointModelKind.unknown : modelKind(id);
      if (kind == EndpointModelKind.other) return;
      if (kind == EndpointModelKind.image ||
          (kind == EndpointModelKind.unknown && image)) {
        images.add(id);
      } else {
        chats.add(id);
      }
    }

    for (final id in savedImages) {
      assign(id, image: true);
    }
    for (final id in models) {
      assign(id, image: false);
    }
    final format =
        AgentApiFormat.values.asNameMap()[e['format']] ?? AgentApiFormat.openai;
    final base = e['baseUrl']?.toString() ?? '';
    return CustomEndpoint(
      id: id,
      enabled: e['enabled'] != false,
      customService:
          e['customService'] == true || endpointPresetOf(format, base) == null,
      wire: EndpointRoute.values.asNameMap()[e['wire']],
      name: e['name']?.toString() ?? '',
      format: format,
      baseUrl: base,
      apiKey: e['apiKey']?.toString() ?? '',
      model: chats.firstOrNull ?? '',
      models: chats,
      imageModels: images.toList(),
      apiPath: e['apiPath']?.toString() ?? '',
      headers: switch (e['headers']) {
        final Map h => {
          for (final x in h.entries)
            if ('${x.key}'.isNotEmpty) '${x.key}': x.value?.toString() ?? '',
        },
        _ => const {},
      },
    );
  }
}

final _headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _headerValue = RegExp(r'^[\x20-\x7E\t]*$');

/// 「名称: 值」一行一条 → 请求头。空行跳过,同名(不分大小写)后写的为准。
/// [bad] 是第一条不合格的行号(从 1 起),全合格为 null。
({Map<String, String> headers, int? bad}) parseHeaderLines(String text) {
  final out = <String, String>{};
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final at = line.indexOf(':');
    final name = at < 0 ? '' : line.substring(0, at).trim();
    final value = at < 0 ? '' : line.substring(at + 1).trim();
    if (!_headerName.hasMatch(name) || !_headerValue.hasMatch(value)) {
      return (headers: out, bad: i + 1);
    }
    out.removeWhere((k, _) => k.toLowerCase() == name.toLowerCase());
    out[name] = value;
  }
  return (headers: out, bad: null);
}

/// [parseHeaderLines] 的反向。
String formatHeaderLines(Map<String, String> headers) =>
    [for (final h in headers.entries) '${h.key}: ${h.value}'].join('\n');

final customEndpointsProvider =
    AsyncNotifierProvider<CustomEndpointsNotifier, List<CustomEndpoint>>(
      CustomEndpointsNotifier.new,
    );

class CustomEndpointsNotifier extends AsyncNotifier<List<CustomEndpoint>> {
  // 必须用共享的 secureStorageProvider,不能自建一个:两者当前配置相同,
  // 但一旦给共享那个加上 AndroidOptions(resetOnError 等),自建的这份会是
  // **唯一没跟上的**,而且编译器和 lint 都不会提醒。
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  var _seq = 0;

  String newId() => 'ep${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  @override
  Future<List<CustomEndpoint>> build() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return const [];
    final j = jsonDecode(raw);
    if (j is! List) throw const FormatException('接口数据格式无效');
    return [for (final e in j) ?CustomEndpoint.fromJson(e)];
  }

  Future<void> _writes = Future.value();

  Future<void> _edit(
    List<CustomEndpoint> Function(List<CustomEndpoint>) change,
  ) {
    final write = _writes.then((_) async {
      if (!state.hasValue) throw StateError('无法读取已保存接口，请稍后重试');
      final next = change(state.value!);
      await _storage.write(
        key: _key,
        value: jsonEncode([for (final e in next) e.toJson()]),
      );
      if (ref.mounted) state = AsyncData(next);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  /// 新增或就地替换(按 id)。
  Future<void> put(CustomEndpoint e, {bool preserveEnabled = false}) =>
      _edit((current) {
        final next = [...current];
        final i = next.indexWhere((item) => item.id == e.id);
        if (i < 0) {
          next.add(e);
        } else {
          next[i] = preserveEnabled ? e.copyWith(enabled: next[i].enabled) : e;
        }
        return next;
      });

  Future<void> setEnabled(String id, bool enabled) => _edit(
    (current) => [
      for (final e in current) e.id == id ? e.copyWith(enabled: enabled) : e,
    ],
  );

  Future<void> remove(String id) => _edit(
    (current) => [
      for (final e in current)
        if (e.id != id) e,
    ],
  );
  Future<void> reorder(int from, int to) => _edit((current) {
    if (from < 0 || from >= current.length || to < 0 || to >= current.length) {
      return current;
    }
    final next = [...current];
    final entry = next.removeAt(from);
    next.insert(to, entry);
    return next;
  });
}
