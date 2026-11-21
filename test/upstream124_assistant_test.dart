import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/domain/agent_event.dart';
import 'package:plana_app/features/assistant/domain/turn_request.dart';
import 'package:plana_app/features/assistant/llm/llm_provider.dart';
import 'package:plana_app/features/assistant/llm/plana_channel_provider.dart';
import 'package:plana_app/features/assistant/presets/rules_file.dart';
import 'package:plana_app/features/assistant/runtime/local_runtime.dart';

class _Replies implements LlmProvider {
  _Replies(this.next);
  final List<Object> next;
  final calls = <List<LlmMessage>>[];

  @override
  LlmCapabilities get capabilities => kChannelCapabilities;
  @override
  String? thinkNote(ThinkLevel level) => null;
  @override
  Stream<LlmText> chat(
    LlmRequest request, {
    required http.Client client,
    bool stream = true,
    Duration? timeout,
  }) async* {
    calls.add(List.of(request.messages));
    final reply = next.removeAt(0);
    if (reply is AgentFailure) throw reply;
    yield (text: reply as String, reasoning: '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'channel keeps separate image payloads and sends incremental turns',
    () async {
      final channel = PlanaChannelProvider(
        baseUrl: 'https://example.test',
        sessionId: '',
        model: 'free',
        imageModel: 'nai_v45_full',
      );
      final client = MockClient((req) async {
        expect(req.url.path, '/api/agent/channel');
        expect(req.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(req.body) as Map;
        expect((body['history'] as List).single['content'], 'previous turn');
        final ask = (body['messages'] as List).single;
        expect(ask['images'], [
          {'mime': 'image/png', 'data': 'first'},
          {'mime': 'image/webp', 'data': 'second'},
        ]);
        expect(ask['image'], (ask['images'] as List).first);
        return http.Response('event: final\ndata: {"text":"done"}\n\n', 200);
      });
      addTearDown(client.close);
      final out = await channel
          .chat(
            const LlmRequest(
              system: 'rules',
              messages: [
                (role: 'assistant', content: 'previous turn', images: []),
                (
                  role: 'user',
                  content: 'compare both',
                  images: [
                    (mime: 'image/png', data: 'first'),
                    (mime: 'image/webp', data: 'second'),
                  ],
                ),
              ],
              turnStart: 1,
            ),
            client: client,
          )
          .single;
      expect(out.text, 'done');
    },
  );

  test(
    'local agent retries transient failures and applies custom response keywords',
    () async {
      final model = _Replies([
        AgentFailure.http(503, 'temporarily offline'),
        'busy right now',
        'ready',
      ]);
      final runtime = LocalAgentRuntime(provider: model, tools: const []);
      final events = await runtime
          .run(
            const AgentTurnRequest(
              userText: 'describe this scene',
              imageModel: 'nai_v45_full',
              customRules: [],
              retries: 1,
              rerolls: 1,
              refusalKeywords: ['busy right now'],
            ),
          )
          .toList();
      expect(events.whereType<AgentDone>(), hasLength(1));
      expect(model.calls, hasLength(3));
      expect(model.calls[1].last.content, model.calls[2].last.content);
    },
  );

  test(
    'local agent requests a corrected drawing block, preserves the question',
    () async {
      const fence = '\u0060\u0060\u0060';
      final model = _Replies([
        '${fence}nai_draw\n{not json}\n$fence',
        'recovered',
      ]);
      final result = await LocalAgentRuntime(provider: model, tools: const [])
          .run(
            const AgentTurnRequest(
              userText: 'draw a sunset',
              imageModel: 'nai_v45_full',
              customRules: [],
              retries: 0,
              rerolls: 0,
            ),
          )
          .toList();
      expect(result.whereType<AgentDone>(), hasLength(1));
      expect(model.calls, hasLength(2));
      expect(model.calls.last.first.content, contains('draw a sunset'));
      expect(model.calls.last.length, greaterThan(model.calls.first.length));
    },
  );

  test('SillyTavern imports ordered enabled and disabled real sections', () {
    final imported = decodeRulesFile(
      jsonEncode({
        'prompts': [
          {'identifier': 'a', 'name': 'First', 'content': 'first scene'},
          {'identifier': 'b', 'name': 'Second', 'content': 'second scene'},
          {'identifier': 'marker', 'marker': true, 'content': 'placeholder'},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'b', 'enabled': false},
              {'identifier': 'marker'},
              {'identifier': 'a', 'enabled': true},
            ],
          },
        ],
      }),
    );
    expect(imported.rules.map((r) => r.name), ['Second', 'First']);
    expect(imported.rules.map((r) => r.enabled), [false, true]);
  });
}
