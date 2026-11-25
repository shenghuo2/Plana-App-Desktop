import '../../../l10n/l10n.dart';
import '../assistant_settings.dart' show ThinkLevel;
import 'http_provider.dart';
import 'llm_provider.dart';

/// Gemini 的思考旋钮按代分两种:2.x 及更早给 token 预算(`thinkingBudget`),
/// 3 及以后给档位(`thinkingLevel`)。发错一种会被 400 拒掉,两种一起发也拒。
enum GeminiThinking { budget, level }

/// 按模型名认是哪一种。不带 gemini 字样的(中转挂的别家模型)按预算发。
GeminiThinking geminiThinkingOf(String model) {
  final m = model.trim().toLowerCase();
  if (RegExp(r'gemini-[12](?:[.\-]|$)').hasMatch(m)) {
    return GeminiThinking.budget;
  }
  if (RegExp(r'gemini|argon|carbon|hydrogen').hasMatch(m)) {
    return GeminiThinking.level;
  }
  return GeminiThinking.budget;
}

/// 只有 Gemini 4 Hydrogen 有 XHIGH。
bool _hasXHigh(String model) => model.toLowerCase().contains('hydrogen');

/// Google Gemini(`/models/{model}:generateContent`,`x-goog-api-key`)。
class GeminiProvider extends HttpLlmProvider {
  GeminiProvider(super.endpoint);

  /// 开流要换方法名、还得带 `alt=sse`(不带回的是一个要收完才能解析的大 JSON 数组)。
  /// 只在认得出 `:generateContent` 时替换;中转改过路径的原样用,按非流式回落。
  @override
  Uri chatUri({required bool stream}) =>
      stream ? endpoint.chatStreamUri : endpoint.chatUri;

  @override
  Map<String, String> get authHeaders => {'x-goog-api-key': apiKey};

  /// 放宽四项可配置安全阈值，避免二次元/绘画提示词被默认阈值误杀；
  /// 不发已废弃的 `HARM_CATEGORY_CIVIC_INTEGRITY`，防止新模型报 400。
  static const _safetySettings = [
    {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
    {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
  ];

  @override
  Map<String, dynamic> requestBody(LlmRequest r, {required bool stream}) => {
    'systemInstruction': {
      'parts': [
        {'text': r.system},
      ],
    },
    'contents': [
      for (final m in r.messages)
        {
          // 只认 user / model 两种
          'role': m.role == 'assistant' ? 'model' : 'user',
          'parts': [
            for (final i in m.images)
              {
                'inlineData': {'mimeType': i.mime, 'data': i.data},
              },
            if (m.images.isEmpty || m.content.isNotEmpty) {'text': m.content},
          ],
        },
    ],
    'safetySettings': _safetySettings,
    ...thinkFields(r.think),
  };

  /// 3 及以后给档位,并且始终带 `includeThoughts` 让流里有思考摘要可显示;没有「关」,
  /// 落到 LOW;XHIGH 只有 Hydrogen 有。2.x 给预算,「关」是预算 0。
  @override
  Map<String, dynamic> thinkFields(ThinkLevel level) {
    if (geminiThinkingOf(endpoint.model) == GeminiThinking.level) {
      return {
        'generationConfig': {
          'thinkingConfig': {
            'includeThoughts': true,
            if (level != ThinkLevel.auto)
              'thinkingLevel': switch (level) {
                ThinkLevel.medium => 'MEDIUM',
                ThinkLevel.high => 'HIGH',
                ThinkLevel.ultra =>
                  _hasXHigh(endpoint.model) ? 'XHIGH' : 'HIGH',
                _ => 'LOW',
              },
          },
        },
      };
    }
    if (level == ThinkLevel.auto) return const {};
    return {
      'generationConfig': {
        'thinkingConfig': {
          'thinkingBudget': switch (level) {
            ThinkLevel.off => 0,
            ThinkLevel.low => 1024,
            ThinkLevel.high => 16384,
            ThinkLevel.ultra => 24576,
            _ => 8192,
          },
          if (level != ThinkLevel.off) 'includeThoughts': true,
        },
      },
    };
  }

  @override
  String? thinkNote(ThinkLevel level) {
    if (geminiThinkingOf(endpoint.model) != GeminiThinking.level) return null;
    return switch (level) {
      ThinkLevel.off => l10nNow.thinkNoOffModel,
      ThinkLevel.ultra when !_hasXHigh(endpoint.model) =>
        l10nNow.thinkNoUltraModel,
      _ => null,
    };
  }

  /// `parts[]` 里 `thought` 为真的那几段算思考。
  @override
  LlmText parseDelta(Object? frame) {
    const none = (text: '', reasoning: '');
    final parts = _parts(frame);
    if (parts == null) return none;
    final text = StringBuffer();
    final think = StringBuffer();
    for (final p in parts) {
      if (p is! Map || p['text'] is! String) continue;
      (p['thought'] == true ? think : text).write(p['text']);
    }
    return (text: text.toString(), reasoning: think.toString());
  }

  /// `candidates[0].content.parts[].text` 拼起来,思考摘要不算。
  @override
  String parseResponse(Object? body) {
    final parts = _parts(body);
    if (parts == null) return '';
    return [
      for (final p in parts)
        if (p is Map && p['text'] != null && p['thought'] != true)
          p['text'].toString(),
    ].join();
  }

  List<dynamic>? _parts(Object? body) {
    if (body is! Map) return null;
    final cands = body['candidates'];
    if (cands is! List || cands.isEmpty) return null;
    final first = cands.first;
    if (first is! Map) return null;
    final parts = (first['content'] as Map?)?['parts'];
    return parts is List ? parts : null;
  }

  /// `{"models":[{"name":"models/gemini-3.7-flash"}]}`
  @override
  List<String> parseModels(Object? body) =>
      body is Map ? modelIdsOf(body['models']) : const [];
}
