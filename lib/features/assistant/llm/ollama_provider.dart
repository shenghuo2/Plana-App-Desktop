import '../assistant_settings.dart' show ThinkLevel;
import 'http_provider.dart';
import 'llm_provider.dart';

class OllamaProvider extends HttpLlmProvider {
  OllamaProvider(super.endpoint);

  @override
  bool get newlineDelimited => true;

  @override
  Uri get modelsUri => endpoint.chatUri.resolve('tags');

  @override
  List<String> parseModels(Object? body) =>
      body is Map ? modelIdsOf(body['models']) : const [];

  @override
  Map<String, String> get authHeaders => {
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };

  @override
  Map<String, dynamic> requestBody(LlmRequest r, {required bool stream}) => {
    'model': endpoint.model,
    'messages': [
      {'role': 'system', 'content': r.system},
      for (final m in r.messages)
        {
          'role': m.role,
          'content': m.content,
          if (m.images.isNotEmpty) 'images': [for (final i in m.images) i.data],
        },
    ],
    'stream': stream,
    ...thinkFields(r.think),
  };

  @override
  Map<String, dynamic> thinkFields(ThinkLevel level) => {
    if (level != ThinkLevel.auto) 'think': level != ThinkLevel.off,
  };

  @override
  String? thinkNote(ThinkLevel level) => null;

  @override
  LlmText parseDelta(Object? frame) {
    final msg = frame is Map ? frame['message'] : null;
    return msg is Map
        ? (
            text: msg['content'] as String? ?? '',
            reasoning: msg['thinking'] as String? ?? '',
          )
        : (text: '', reasoning: '');
  }

  @override
  String parseResponse(Object? body) => parseDelta(body).text;
}
