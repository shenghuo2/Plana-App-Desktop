import '../assistant_settings.dart' show ThinkLevel;
import 'llm_provider.dart';
import 'openai_provider.dart';

class ResponsesProvider extends OpenAiProvider {
  ResponsesProvider(super.endpoint);

  @override
  Map<String, dynamic> requestBody(LlmRequest r, {required bool stream}) => {
    'model': endpoint.model,
    'instructions': r.system,
    'store': false,
    'input': [
      for (final m in r.messages)
        {
          'role': m.role,
          'content': m.images.isEmpty
              ? m.content
              : [
                  for (final i in m.images)
                    {
                      'type': 'input_image',
                      'image_url': 'data:${i.mime};base64,${i.data}',
                    },
                  if (m.content.isNotEmpty)
                    {'type': 'input_text', 'text': m.content},
                ],
        },
    ],
    'stream': stream,
    ...thinkFields(r.think),
  };

  @override
  Map<String, dynamic> thinkFields(ThinkLevel level) => level == ThinkLevel.auto
      ? {}
      : {
          'reasoning': {'effort': super.thinkFields(level)['reasoning_effort']},
        };

  @override
  LlmText parseDelta(Object? frame) {
    final delta = frame is Map ? frame['delta'] : null;
    if (frame is! Map || delta is! String) return (text: '', reasoning: '');
    return switch (frame['type']) {
      'response.output_text.delta' ||
      'response.refusal.delta' => (text: delta, reasoning: ''),
      'response.reasoning_summary_text.delta' => (text: '', reasoning: delta),
      _ => (text: '', reasoning: ''),
    };
  }

  @override
  String parseResponse(Object? body) {
    if (body is! Map || body['output'] is! List) return '';
    return [
      for (final item in body['output'] as List)
        if (item is Map && item['type'] == 'message' && item['content'] is List)
          for (final part in item['content'] as List)
            if (part is Map &&
                part['type'] == 'output_text' &&
                part['text'] is String)
              part['text']
            else if (part is Map && part['type'] == 'refusal')
              part['refusal'],
    ].join();
  }
}
