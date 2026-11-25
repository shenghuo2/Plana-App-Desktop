import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/auth/secure_storage.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'support/desktop_capture.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/endpoints_page.dart';
import 'package:plana_app/features/assistant/image_gen/image_gen_client.dart';
import 'package:plana_app/features/assistant/image_gen/image_models.dart';
import 'package:plana_app/features/assistant/llm/http_provider.dart';
import 'package:plana_app/features/assistant/llm/llm_provider.dart';
import 'package:plana_app/features/assistant/widgets/model_sheet.dart';

const ep = CustomEndpoint(
  id: 'one',
  name: 'First endpoint',
  format: AgentApiFormat.openai,
  baseUrl: 'https://relay.invalid/v1',
  apiKey: 'test-key',
  model: 'chat-id',
  models: ['chat-id'],
  imageModels: ['image-id'],
);
const request = LlmRequest(
  system: 'draw',
  messages: [
    (role: 'user', content: 'sky', images: [(mime: 'image/png', data: 'AA==')]),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesktopCaptureFonts);
  test(
    'request path selects wire, keeps custom aliases and joins versioned paths',
    () {
      for (final route in EndpointRoute.values) {
        expect(ep.copyWith(apiPath: route.path).route, route);
      }
      final alias = ep.copyWith(
        apiPath: '/relay/custom',
        wire: EndpointRoute.responses,
      );
      expect(
        CustomEndpoint.fromJson(alias.toJson())!.route,
        EndpointRoute.responses,
      );
      expect(
        ep.copyWith(apiPath: '/v1/responses').chatUri.path,
        '/v1/responses',
      );
      final gem = ep.copyWith(apiPath: '/v1/models/{model}:generateContent');
      expect(
        llmProviderFor(gem).chatUri(stream: true).toString(),
        'https://relay.invalid/v1/models/chat-id:streamGenerateContent?alt=sse',
      );
    },
  );

  test(
    'Responses and local Ollama send and decode their actual wire formats',
    () async {
      final responses = llmProviderFor(ep.copyWith(apiPath: '/responses'));
      final reply = await responses
          .chat(
            request,
            client: MockClient((req) async {
              final body = jsonDecode(req.body);
              expect(req.url.path, '/v1/responses');
              expect(body['instructions'], 'draw');
              expect(body['input'][0]['content'][0]['type'], 'input_image');
              return http.Response(
                'data: {"type":"response.output_text.delta","delta":"ok"}\n\ndata: [DONE]\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }),
          )
          .last;
      expect(reply.text, 'ok');
      expect(
        responses.parseResponse({
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'yes'},
              ],
            },
          ],
        }),
        'yes',
      );
      final local = ep.copyWith(
        baseUrl: 'http://localhost:11434',
        apiKey: '',
        apiPath: '/api/chat',
      );
      expect(local.usable, isTrue);
      final ollama = llmProviderFor(local);
      expect(ollama.modelsUri.path, '/api/tags');
      final chat = await ollama
          .chat(
            request,
            client: MockClient((req) async {
              expect(req.url.path, '/api/chat');
              expect(req.headers.containsKey('authorization'), isFalse);
              expect(jsonDecode(req.body)['messages'].last['images'], ['AA==']);
              return http.Response(
                '{"message":{"thinking":"plan"}}\n{"message":{"content":"ok"},"done":true}\n',
                200,
                headers: {'content-type': 'application/x-ndjson'},
              );
            }),
          )
          .last;
      expect(chat, (text: 'ok', reasoning: 'plan'));
    },
  );

  test(
    'legacy chat and image IDs migrate, including a selected image and disabled or image-only endpoints',
    () {
      final old = CustomEndpoint.fromJson({
        'id': 'one',
        'apiKey': 'key',
        'models': ['gpt-a', 'gpt-image-1'],
        'imageModels': ['claude-mid', 'image-private'],
      })!;
      expect(old.allModels, unorderedEquals(['gpt-a', 'claude-mid']));
      expect(
        old.imageModels,
        unorderedEquals(['gpt-image-1', 'image-private']),
      );
      expect(
        availableEndpointModel('custom:one/gpt-image-1', [old]),
        'image:custom:one/gpt-image-1',
      );
      final imageOnly = CustomEndpoint(
        id: 'img',
        name: '',
        format: AgentApiFormat.anthropic,
        baseUrl: 'https://relay.invalid',
        customService: true,
        apiKey: 'k',
        model: '',
        imageModels: const ['private'],
      );
      expect(
        availableEndpointModel('custom:one/gpt-a', [
          old.copyWith(enabled: false),
          imageOnly,
        ]),
        'image:custom:img/private',
      );
      expect(
        imageModelChoices(null, [
          old.copyWith(enabled: false),
          imageOnly,
        ]).map((m) => m.name),
        ['private'],
      );
      expect(
        CustomEndpoint.fromJson(old.copyWith(enabled: false).toJson())!.enabled,
        isFalse,
      );
    },
  );

  test(
    'catalog reads later pages and uses output modality even for vision input or an unfamiliar ID',
    () async {
      final p = llmProviderFor(ep);
      final result = await p.modelCatalog(
        client: MockClient((req) async {
          final later = req.url.queryParameters['pageToken'] == 'next';
          return http.Response(
            jsonEncode(
              later
                  ? {
                      'data': [
                        {
                          'id': 'paint-x',
                          'architecture': {
                            'output_modalities': ['text', 'image'],
                          },
                        },
                      ],
                    }
                  : {
                      'data': [
                        {
                          'id': 'vision',
                          'architecture': {
                            'input_modalities': ['text', 'image'],
                            'output_modalities': ['text'],
                          },
                        },
                      ],
                      'nextPageToken': 'next',
                    },
            ),
            200,
          );
        }),
      );
      expect(result, {
        'paint-x': EndpointModelKind.image,
        'vision': EndpointModelKind.chat,
      });
    },
  );

  test(
    'OpenRouter picks a single generation route before sending the prompt',
    () async {
      for (final dedicated in [true, false]) {
        final client = OpenRouterImageClient(
          ep.copyWith(baseUrl: 'https://openrouter.ai/api/v1'),
          'alias',
        );
        final urls = <String>[];
        final image = await client.generate(
          (prompt: 'sky', images: const [], size: '', aspect: ''),
          client: MockClient((req) async {
            urls.add(req.url.path);
            if (req.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'data': [
                    if (dedicated) {'id': 'alias'},
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode(
                dedicated
                    ? {
                        'data': [
                          {'b64_json': 'AQI='},
                        ],
                      }
                    : {
                        'choices': [
                          {
                            'message': {
                              'images': [
                                {
                                  'image_url': {
                                    'url': 'data:image/png;base64,AQI=',
                                  },
                                },
                              ],
                            },
                          },
                        ],
                      },
              ),
              200,
            );
          }),
        );
        expect(image, [1, 2]);
        expect(urls, [
          '/api/v1/images/models',
          dedicated ? '/api/v1/images' : '/api/v1/chat/completions',
        ]);
      }
    },
  );

  testWidgets(
    'both endpoints can be enabled, disabled choices leave the real menu, custom request paths survive blur',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'assistant_endpoints': jsonEncode([
          ep.toJson(),
          ep.copyWith(name: 'Second').toJson()..['id'] = 'two',
        ]),
      });
      final c = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          assistantBotAuthorizedProvider.overrideWithValue(false),
          planaImageChannelsProvider.overrideWith(
            (_) async => (channels: <PlanaImageChannel>[], authorized: false),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(customEndpointsProvider.future);
      await c
          .read(assistantModelPrefProvider.notifier)
          .set('custom:one/chat-id');
      tester.view.physicalSize = const Size(1300, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 280, child: AssistantModelDropdown()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('assistant-model-button'));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      Finder choice(String k) => find.byKey(ValueKey('assistant-model-$k'));
      expect(choice('custom:one/chat-id'), findsOneWidget);
      final pic = choice('image:custom:two/image-id');
      expect(
        find.descendant(of: pic, matching: find.text('出图模型')),
        findsOneWidget,
      );
      await tester.tap(choice('custom:one/chat-id'));
      await tester.pumpAndSettle();
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      final editorClosed = nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const EndpointsPage(editId: 'one'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        c.read(customEndpointsProvider).requireValue.first.enabled,
        isFalse,
      );
      expect(c.read(customEndpointsProvider).requireValue.last.enabled, isTrue);
      final field = find.byKey(const ValueKey('endpoint-request-path'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      for (final r in EndpointRoute.values) {
        expect(find.text(r.label), findsOneWidget);
      }
      expect(
        tester.getTopLeft(find.text('OpenAI Chat Completions')).dy,
        greaterThan(tester.getBottomLeft(field).dy),
      );
      await tester.tap(find.text('OpenAI Responses'));
      await tester.pumpAndSettle();
      await tester.enterText(field, '/private/chat-v2');
      await tester.pump();
      await tester.tap(find.text('接口名称'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = c.read(customEndpointsProvider).requireValue.first;
      expect(saved.apiPath, '/private/chat-v2');
      expect(saved.route, EndpointRoute.responses);
      expect(saved.enabled, isFalse);
      nav.pop();
      await tester.pumpAndSettle();
      await editorClosed;
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(choice('custom:one/chat-id'), findsNothing);
      expect(choice('image:custom:one/image-id'), findsNothing);
      expect(choice('custom:two/chat-id'), findsOneWidget);
    },
  );
  testWidgets(
    'official service capabilities, custom paths and saved drafts across desktop sizes',
    (tester) async {
      final open = ep.copyWith(
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-6.2-sol',
        models: ['gpt-6.2-sol'],
        imageModels: ['gpt-image-2.6-flare'],
      );
      final ds = ep.copyWith(
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-flash',
        models: ['deepseek-flash'],
        imageModels: [],
        enabled: false,
      );
      FlutterSecureStorage.setMockInitialValues({
        'assistant_endpoints': jsonEncode([
          open.toJson(),
          ds.toJson()..['id'] = 'two',
        ]),
      });
      final c = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          assistantBotAuthorizedProvider.overrideWithValue(false),
          planaImageChannelsProvider.overrideWith(
            (_) async => (channels: <PlanaImageChannel>[], authorized: false),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(customEndpointsProvider.future);
      tester.view.physicalSize = const Size(1360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light().copyWith(
                textTheme: AppTheme.light().textTheme.apply(
                  fontFamily: 'Microsoft YaHei',
                ),
              ),
              home: const EndpointsPage(editId: 'one'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('出图模型'), findsOneWidget);
      expect(find.byType(SegmentedButton<AgentApiFormat>), findsNothing);
      await captureDesktop(tester, capture, 'assistant-windows-endpoints');
      Future<void> choose(String title) async {
        final target = find.widgetWithText(ChoiceChip, title);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      for (final provider in ['DeepSeek', 'Claude']) {
        await choose(provider);
        final chat = find.text('对话模型'), image = find.text('出图模型');
        expect(
          tester.getTopLeft(image).dy,
          closeTo(tester.getTopLeft(chat).dy, 1),
        );
        expect(
          tester.getTopLeft(image).dx,
          greaterThan(tester.getTopRight(chat).dx),
        );
        final list = find.byTooltip('模型列表').last;
        await tester.ensureVisible(list);
        await tester.tap(list);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('暂无可用的出图模型'), findsOneWidget);
        expect(find.byType(CheckboxListTile), findsNothing);
        if (provider == 'DeepSeek') {
          await captureDesktop(
            tester,
            capture,
            'assistant-deepseek-empty-models',
          );
        }
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      }
      await choose('自定义');
      expect(find.text('出图模型'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('endpoint-request-path')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anthropic Messages'));
      await tester.pumpAndSettle();
      expect(find.text('出图模型'), findsOneWidget);
      await choose('OpenAI');
      expect(find.text('gpt-image-2.6-flare'), findsOneWidget);
      for (final width in [850.0, 610.0, 375.0]) {
        tester.view.physicalSize = Size(width, 840);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );
}
