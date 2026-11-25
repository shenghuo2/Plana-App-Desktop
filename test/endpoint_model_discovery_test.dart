import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/endpoints_page.dart';
import 'package:plana_app/features/assistant/llm/http_provider.dart';
import 'package:plana_app/features/assistant/model_catalog.dart';

const endpoint = CustomEndpoint(
  id: 'fixture',
  name: 'Relay',
  format: AgentApiFormat.openai,
  baseUrl: 'https://station.test/v1',
  apiKey: 'fixture-key',
  model: '',
  customService: true,
);
http.Response jsonResponse(Object v) => http.Response(jsonEncode(v), 200);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'specialized purposes use capability declarations and stay out of the chat and drawing pickers',
    () {
      final cases = <(Map, EndpointModelKind)>[
        (
          {
            'type': 'transcription',
            'output_modalities': ['text'],
          },
          EndpointModelKind.transcription,
        ),
        (
          {
            'supported_endpoint_types': ['audio/speech'],
          },
          EndpointModelKind.speechSynthesis,
        ),
        (
          {
            'architecture': {
              'output_modalities': ['embeddings'],
            },
          },
          EndpointModelKind.embedding,
        ),
        (
          {
            'supportedGenerationMethods': ['countTokens', 'batchEmbedContents'],
          },
          EndpointModelKind.embedding,
        ),
        ({'type': 'moderation'}, EndpointModelKind.other),
        (
          {
            'id': 'tts-private',
            'supportedGenerationMethods': ['countTokens'],
          },
          EndpointModelKind.unknown,
        ),
      ];
      for (final (row, expected) in cases) {
        final kind = declaredKind(row);
        expect(kind, expected);
        expect(kind.supports(false), false);
        expect(kind.supports(true), false);
      }
    },
  );
  test(
    'official providers use declared output or exact IDs; generic Gemini methods do not imply text',
    () async {
      for (final preset in kEndpointPresets) {
        final provider = llmProviderFor(
          CustomEndpoint(
            id: 'id',
            name: preset.label,
            format: preset.format,
            baseUrl: preset.base,
            apiKey: 'key',
            model: '',
          ),
        );
        final result = await provider.discoverModels(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/images/models')) {
              return jsonResponse({'data': []});
            }
            final body = switch (preset.label) {
              'Claude' => {
                'data': [
                  {
                    'id': 'opaque',
                    'type': 'model',
                    'capabilities': {
                      'image_input': {'supported': true},
                    },
                  },
                ],
              },
              'Gemini' => {
                'models': [
                  {
                    'name': 'models/opaque',
                    'supportedGenerationMethods': ['generateContent'],
                  },
                ],
              },
              'DeepSeek' => {
                'data': [
                  {
                    'id': 'opaque',
                    'input_modalities': ['image'],
                    'output_modalities': ['text'],
                  },
                ],
              },
              'OpenRouter' => {
                'data': [
                  {
                    'id': 'opaque',
                    'architecture': {
                      'output_modalities': ['text', 'image'],
                    },
                  },
                ],
              },
              _ => {
                'data': [
                  {'id': 'opaque', 'owned_by': 'openai'},
                ],
              },
            };
            return jsonResponse(body);
          }),
          loadDirectory: (_) async => ModelDirectory.fromKinds({
            'google/opaque': EndpointModelKind.image,
            'openai/opaque': EndpointModelKind.other,
          }),
        );
        expect(result['opaque']!.kind, switch (preset.label) {
          'Gemini' => EndpointModelKind.image,
          'OpenAI' => EndpointModelKind.other,
          'OpenRouter' => EndpointModelKind.chatAndImage,
          _ => EndpointModelKind.chat,
        });
      }
    },
  );
  test(
    'OpenRouter keeps the account filters across pages and excludes global-only image models',
    () async {
      final preset = kEndpointPresets.firstWhere(
        (p) => p.label == 'OpenRouter',
      );
      final provider = llmProviderFor(
        CustomEndpoint(
          id: 'router',
          name: preset.label,
          format: preset.format,
          baseUrl: preset.base,
          apiKey: 'account-key',
          model: '',
        ),
      );
      final result = await provider.discoverModels(
        client: MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer account-key');
          if (r.url.path == '/api/v1/images/models') {
            return jsonResponse({
              'data': [
                {'id': 'allowed-image'},
                {'id': 'filtered-out'},
              ],
            });
          }
          expect(r.url.path, '/api/v1/models/user');
          expect(r.url.queryParameters['output_modalities'], 'all');
          if (r.url.queryParameters.containsKey('offset')) {
            return jsonResponse({
              'data': [
                {'id': 'allowed-image'},
              ],
            });
          }
          return jsonResponse({
            'data': [
              {
                'id': 'chat',
                'output_modalities': ['text'],
              },
            ],
            'links': {'next': '?offset=1&output_modalities=all'},
          });
        }),
        loadDirectory: (_) async => ModelDirectory.fromKinds({}),
      );
      expect(result.map((id, row) => MapEntry(id, row.kind)), {
        'chat': EndpointModelKind.chat,
        'allowed-image': EndpointModelKind.image,
      });
    },
  );
  test(
    'New API, directory and unknown remain distinct and the public directory never receives user credentials or model IDs',
    () async {
      final dir = await Directory.systemTemp.createTemp('plana-public-models');
      addTearDown(() => dir.delete(recursive: true));
      final cache = ModelDirectoryCache(cacheDir: () async => dir);
      int fetches = 0;
      final client = MockClient((r) async {
        if (r.url.host == 'models.dev') {
          fetches++;
          expect(r.headers.containsKey('Authorization'), false);
          expect(r.headers.containsKey('x-relay'), false);
          expect(r.url.queryParameters, {'type': 'all'});
          return jsonResponse({
            'openai': {
              'models': {
                'real-image': {
                  'type': 'image',
                  'modalities': {
                    'output': ['image/png'],
                  },
                },
                'real-embedding': {
                  'type': 'embedding',
                  'modalities': {
                    'output': ['text'],
                  },
                },
              },
            },
          });
        }
        if (r.url.path == '/api/pricing') {
          expect(r.headers.containsKey('Authorization'), false);
          expect(r.url.hasQuery, false);
          return jsonResponse({
            'data': [
              {
                'model_name': 'paint',
                'supported_endpoint_types': ['image-generation'],
              },
              {
                'model_name': 'missing-from-key',
                'supported_endpoint_types': ['openai'],
              },
            ],
          });
        }
        expect(r.headers['Authorization'], 'Bearer fixture-key');
        return jsonResponse({
          'data': [
            {'id': 'paint'},
            {'id': 'real-embedding', 'owned_by': 'openai'},
            {'id': 'vip-remapped', 'upstream_model': 'openai/real-image'},
            {'id': 'gpt-private-unknown'},
            {
              'id': 'vision',
              'input_modalities': ['image'],
              'output_modalities': ['text'],
            },
          ],
        });
      });
      final result = await llmProviderFor(
        endpoint.copyWith(headers: {'x-relay': 'private'}),
      ).discoverModels(client: client, loadDirectory: cache.load);
      expect(result['paint']!.source, ModelEvidence.provider);
      expect(result['paint']!.kind, EndpointModelKind.image);
      expect(result['vip-remapped']!.source, ModelEvidence.directory);
      expect(result['vip-remapped']!.kind, EndpointModelKind.image);
      expect(result['real-embedding']!.kind, EndpointModelKind.embedding);
      expect(result['vision']!.kind, EndpointModelKind.chat);
      expect(result['gpt-private-unknown']!.kind, EndpointModelKind.unknown);
      expect(result.containsKey('missing-from-key'), false);
      await ModelDirectoryCache(cacheDir: () async => dir).load(client);
      expect(fetches, 1);
      final cacheText = await dir
          .list()
          .where((f) => f.path.endsWith('.json'))
          .single
          .then((f) => File(f.path).readAsString());
      expect(cacheText, isNot(contains('fixture-key')));
      expect(cacheText, isNot(contains('vip-remapped')));
    },
  );
  test(
    'local Ollama reads capabilities using show without generating or billing a request',
    () async {
      final ep = endpoint.copyWith(
        baseUrl: 'http://localhost:11434',
        wire: EndpointRoute.ollama,
        apiPath: '/api/chat',
      );
      final result = await llmProviderFor(ep).discoverModels(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/tags')) {
            return jsonResponse({
              'models': [
                {'name': 'text'},
                {'name': 'vectors'},
              ],
            });
          }
          expect(r.url.path, '/api/show');
          expect(r.method, 'POST');
          return jsonResponse({
            'capabilities': [
              jsonDecode(r.body)['model'] == 'text'
                  ? 'completion'
                  : 'embedding',
            ],
          });
        }),
      );
      expect(result['text']!.kind, EndpointModelKind.chat);
      expect(result['vectors']!.kind, EndpointModelKind.embedding);
    },
  );
  testWidgets(
    'an unknown relay model can be assigned to image generation and survives reopening and a catalog change',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'assistant_endpoints': jsonEncode([endpoint.toJson()]),
      });
      var later = false;
      final app = ProviderContainer(
        overrides: [
          assistantModelProvider.overrideWithValue(null),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          endpointDiscoveryProvider.overrideWithValue(
            (_) async => {
              'vip': later
                  ? const CatalogModel(
                      EndpointModelKind.chat,
                      ModelEvidence.provider,
                    )
                  : CatalogModel.unknown,
            },
          ),
        ],
      );
      addTearDown(app.dispose);
      await app.read(customEndpointsProvider.future);
      tester.view.physicalSize = const Size(1250, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> open() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: app,
            child: const MaterialApp(home: EndpointsPage(editId: 'fixture')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('重新拉取模型'), findsNothing);
        final list = find.byTooltip('模型列表').last;
        await tester.ensureVisible(list);
        await tester.tap(list);
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.textContaining('未分类'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'vip'));
      await tester.pump();
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final stored = app.read(customEndpointsProvider).value!.single;
      final loaded = CustomEndpoint.fromJson(stored.toJson())!;
      expect(loaded.imageModels, ['vip']);
      expect(loaded.modelOverrides['vip'], EndpointModelKind.image);
      expect(
        availableEndpointModel('image:custom:fixture/vip', [loaded]),
        'image:custom:fixture/vip',
      );
      await tester.pumpWidget(const SizedBox());
      later = true;
      await open();
      expect(find.textContaining('已手动指定'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'vip'),
            )
            .value,
        true,
      );
    },
  );
}
