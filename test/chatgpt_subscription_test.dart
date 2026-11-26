import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/external/oc_sources.dart';
import 'package:plana_app/features/inspiration/public_tag_blocks.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/assistant/tools/tool_settings.dart';
import 'package:plana_app/features/assistant/endpoints_page.dart';
import 'package:plana_app/features/assistant/assistant_mode.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/generate/canvas_models.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/assistant/domain/agent_event.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/image_gen/image_models.dart';
import 'package:plana_app/features/assistant/widgets/model_sheet.dart';
import 'package:plana_app/features/assistant/domain/turn_request.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/subscription/plan_accounts.dart';
import 'package:plana_app/features/assistant/subscription/plan_oauth.dart';
import 'package:plana_app/features/assistant/subscription/plan_runtime.dart';
import 'package:plana_app/features/assistant/widgets/plan_accounts_dialog.dart';
import 'package:plana_app/l10n/app_localizations.dart';
import 'support/desktop_capture.dart';

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

class _LoopbackBrowser extends HttpOverrides {}

class _BotLibrarySession extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'library-only');
}

class _LocalReferences extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState(
    entries: [
      TagEntry(
        id: 'cat',
        category: TagCategory.character,
        name: '猫娘',
        aliases: ['猫猫'],
        positive: '1.35::cat ears, silver hair::, {ribbon}',
      ),
    ],
  );
}

// Simulate the catalogue response and account writes inside the widget clock.
class _MenuPreference extends AssistantModelPrefNotifier {
  @override
  Future<String> build() async => '';
  @override
  Future<void> set(String key) async => state = AsyncData(key);
}

class _PickerStore extends PlanStore {
  _PickerStore(super.storage, super.oauth);
  static const recordKey = 'chatgpt_plan_profiles_v1';
  int fetches = 0;
  @override
  Future<void> activate(String id) async {
    final data = jsonDecode((await storage.read(key: recordKey))!);
    data['active'] = id;
    await storage.write(key: recordKey, value: jsonEncode(data));
  }

  @override
  Future<PlanProfile> refreshModels(String id) async {
    fetches++;
    return (await accounts()).find(id)!;
  }

  @override
  Future<PlanProfile> selectModels(String id, Set<String> selected) async {
    final data = jsonDecode((await storage.read(key: recordKey))!);
    data['profiles'][id]['selected'] = selected.toList();
    await storage.write(key: recordKey, value: jsonEncode(data));
    return (await accounts()).find(id)!;
  }
}

class _DrawingService extends GenerationNotifier {
  final received = Completer<GenerateState>();
  @override
  GenPool build() => const GenPool();
  @override
  Future<GenOutcome> generate({
    GallerySaveTarget? galleryTarget,
    GenerateState? using,
    bool stay = false,
    void Function(String)? onJob,
    CanvasOrigin? origin,
  }) async {
    received.complete(using!);
    return GenOutcome.ok;
  }
}

class _Issuer {
  // Public Mersenne primes give the local fixture repeatable RSA signatures.
  static final _p = (BigInt.one << 1279) - BigInt.one;
  static final _q = (BigInt.one << 2203) - BigInt.one;
  static final _e = BigInt.from(65537);
  final key = JsonWebKey.rsa(
    modulus: _p * _q,
    exponent: _e,
    privateExponent: _e.modInverse((_p - BigInt.one) * (_q - BigInt.one)),
    firstPrimeFactor: _p,
    secondPrimeFactor: _q,
  );
  late Uri authorization;
  String workspace = 'personal';
  String subject = 'same-user';
  String scope =
      'openid offline_access resource.invoke chatgpt.tokens.use.direct';
  bool expire = false, deny = false;
  int refreshes = 0, wrongStateStatus = 0, catalogs = 0;
  List<String> additionalModels = [];
  final logins = <Uri>[];
  String token(String client, {String? nonce, String? audience, int? exp}) {
    final header = b64(
      utf8.encode(jsonEncode({'alg': 'RS256', 'kid': 'fixture'})),
    );
    final payload = b64(
      utf8.encode(
        jsonEncode({
          'iss': 'https://auth.openai.com',
          'aud': audience ?? client,
          'sub': subject,
          'email': 'same@example.test',
          'nonce': nonce,
          'exp': exp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        }),
      ),
    );
    final signed = '$header.$payload';
    return '$signed.${b64(key.sign(ascii.encode(signed), algorithm: 'RS256'))}';
  }

  Future<bool> browser(Uri url) async {
    authorization = url;
    logins.add(url);
    expect(url.origin, 'https://auth.openai.com');
    expect(url.queryParameters['code_challenge_method'], 'S256');
    final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
    expect(redirect.host, '127.0.0.1');
    final client = _LoopbackBrowser().createHttpClient(null)
      ..findProxy = (_) => 'DIRECT';
    Future<int> visit(Map<String, String> q) async {
      final res = await (await client.getUrl(
        redirect.replace(queryParameters: q),
      )).close();
      await res.drain<void>();
      return res.statusCode;
    }

    try {
      wrongStateStatus = await visit({'state': 'incorrect', 'code': 'wrong'});
      expect(
        await visit({
          'state': url.queryParameters['state']!,
          if (deny) 'error': 'access_denied' else 'code': 'code',
          if (url.queryParameters['client_id'] == 'dynamic_agent_client')
            'client_id': workspace,
        }),
        200,
      );
    } finally {
      client.close();
    }
    return true;
  }

  Future<http.Response> request(http.Request r) async {
    if (r.url.path.contains('jwks')) {
      return http.Response(
        jsonEncode({
          'keys': [
            {'kty': 'RSA', 'kid': 'fixture', 'n': key['n'], 'e': key['e']},
          ],
        }),
        200,
      );
    }
    if (r.url.path.endsWith('/revoke')) return http.Response('', 200);
    if (r.url.path.endsWith('/models')) {
      catalogs++;
      expect(r.headers['Authorization'], startsWith('Bearer '));
      return http.Response(
        jsonEncode({
          'models': [
            {
              'slug': 'visible',
              'display_name': 'Visible',
              'visibility': 'list',
              'supported_reasoning_levels': [
                {'effort': 'medium'},
                {'effort': 'xhigh'},
              ],
            },
            {'slug': 'hidden', 'display_name': 'Hidden', 'visibility': 'hide'},
            for (final id in additionalModels)
              {
                'slug': id,
                'display_name': id.toUpperCase(),
                'visibility': 'list',
              },
          ],
        }),
        200,
      );
    }
    expect(
      r.url.toString(),
      'https://auth.openai.com/api/accounts/oauth/token',
    );
    final fields = r.bodyFields;
    expect(fields['resource'], planResource);
    final renew = fields['grant_type'] == 'refresh_token';
    if (renew) {
      refreshes++;
      expect(fields['refresh_token'], 'refresh-$workspace');
    } else {
      expect(
        b64(sha256.convert(ascii.encode(fields['code_verifier']!)).bytes),
        authorization.queryParameters['code_challenge'],
      );
      expect(
        fields['redirect_uri'],
        authorization.queryParameters['redirect_uri'],
      );
      expect(fields['client_id'], workspace);
    }
    return http.Response(
      jsonEncode({
        'token_type': 'Bearer',
        'access_token': renew ? 'renewed-$workspace' : 'access-$workspace',
        'refresh_token': renew ? 'rotated-$workspace' : 'refresh-$workspace',
        'scope': scope,
        'expires_in': expire && !renew ? 1 : 3600,
        if (!renew)
          'id_token': token(
            fields['client_id']!,
            nonce: authorization.queryParameters['nonce'],
          ),
      }),
      200,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesktopCaptureFonts);
  late _Issuer issuer;
  late PlanStore store;
  late Directory temp;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    issuer = _Issuer();
    temp = Directory.systemTemp.createTempSync('plana-plan-test-');
    store = PlanStore(
      const FlutterSecureStorage(),
      PlanOAuth(MockClient(issuer.request), openBrowser: issuer.browser),
      directory: () async => temp,
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));
  testWidgets('the model menu opens the consent gate before the browser', (
    tester,
  ) async {
    final app = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        planStoreProvider.overrideWithValue(store),
        agentModelsProvider.overrideWith((_) async => const AgentModelList()),
        assistantBotAuthorizedProvider.overrideWithValue(false),
        planaImageChannelsProvider.overrideWith(
          (_) async => (channels: <PlanaImageChannel>[], authorized: false),
        ),
      ],
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: app,
        child: const MaterialApp(
          home: Scaffold(body: AssistantModelDropdown()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-model-button')));
    await tester.pumpAndSettle();
    final launch = find.byKey(const ValueKey('assistant-chatgpt-accounts'));
    expect(find.text('添加接口'), findsNothing);
    expect(
      tester.getCenter(launch).dy,
      greaterThan(tester.getCenter(find.text('管理接口与订阅')).dy),
    );
    await tester.tap(launch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text('使用 ChatGPT 订阅须知'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('plan-consent')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.widgetWithText(TextButton, '取消').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(issuer.logins, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'hub, quick switch and assistant dropdown share a staged subscription catalog picker',
    (tester) async {
      final picker = _PickerStore(store.storage, store.oauth);
      FlutterSecureStorage.setMockInitialValues({
        _PickerStore.recordKey: jsonEncode({
          'active': 'personal',
          'profiles': {
            'personal': {
              'email': 'artist@example.test',
              'label': 'Studio',
              'grant': {},
              'reasoning': {},
              'models': {'one': 'GPT-6.2-Sol', 'two': 'GPT-6.2-Astra'},
              'selected': ['one'],
            },
            'Team02': {
              'email': 'team@example.test',
              'label': '创作工作区',
              'grant': {},
              'reasoning': {},
              'models': {'other': 'Other'},
              'selected': ['other'],
            },
          },
        }),
      });
      final app = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          planStoreProvider.overrideWithValue(picker),
          assistantModelPrefProvider.overrideWith(_MenuPreference.new),
          agentModelsProvider.overrideWith((_) async => const AgentModelList()),
          assistantBotAuthorizedProvider.overrideWithValue(false),
          planaImageChannelsProvider.overrideWith(
            (_) async => (channels: <PlanaImageChannel>[], authorized: false),
          ),
        ],
      );
      addTearDown(app.dispose);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final theme = AppTheme.light(const Color(0xff006b60));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: app,
          child: RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
              ),
              home: const EndpointsPage(editId: planHubId),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder selected(String id) => find.byKey(ValueKey('plan-selected-$id'));
      Future<void> openPicker() async {
        await tester.tap(
          find.byKey(const ValueKey('plan-refresh-models')).last,
        );
        await tester.pumpAndSettle();
      }

      expect(selected('one'), findsOneWidget);
      expect(selected('two'), findsNothing);
      await captureDesktop(tester, capture, 'plan-library-hub');
      await openPicker();
      await tester.enterText(find.byType(TextField).last, 'tw');
      await tester.pump();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'GPT-6.2-Astra'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(selected('two'), findsNothing);
      await openPicker();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'GPT-6.2-Sol'));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'GPT-6.2-Astra'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '完成 · 已选 1 个'));
      await tester.pumpAndSettle();
      expect(selected('one'), findsNothing);
      expect(selected('two'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('assistant-model-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey('assistant-model-${planModelKey('personal', 'one')}'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          ValueKey('assistant-model-${planModelKey('personal', 'two')}'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('快捷切换订阅账户'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(Dialog), matching: selected('two')),
        findsOneWidget,
      );
      await captureDesktop(tester, capture, 'plan-library-quick-switch');
      Future<void> switchTo(String id) async {
        await tester.tap(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byKey(ValueKey('plan-account-$id')),
          ),
        );
        await tester.pumpAndSettle();
      }

      await switchTo('Team02');
      expect(
        app.read(assistantModelPrefProvider).value,
        planModelKey('Team02', 'other'),
      );
      expect(
        find.descendant(of: find.byType(Dialog), matching: selected('other')),
        findsOneWidget,
      );
      await switchTo('personal');
      expect(
        find.descendant(of: find.byType(Dialog), matching: selected('two')),
        findsOneWidget,
      );
      await openPicker();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'GPT-6.2-Astra'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '完成 · 已选 0 个'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '关闭').last);
      await tester.pumpAndSettle();
      expect(selected('two'), findsNothing);
      expect(picker.fetches, 3);
    },
  );

  test(
    'official callback, signature, workspace isolation, refresh rotation and local sign-out',
    () async {
      issuer.expire = true;
      final first = await store.signIn();
      expect(first, 'personal');
      expect(issuer.wrongStateStatus, 400);
      expect(await store.hasSignedIn, true);
      expect(
        await Future.wait([store.access('personal'), store.access('personal')]),
        ['renewed-personal', 'renewed-personal'],
      );
      expect(issuer.refreshes, 1);
      expect((await store.refreshModels('personal')).models, {
        'visible': 'Visible',
      });
      await store.selectModels('personal', {'visible'});
      final host = issuer.logins.first.queryParameters['ext_agent_host_id'];
      issuer.workspace = 'team';
      issuer.expire = false;
      await store.signIn();
      expect(issuer.logins.last.queryParameters['ext_agent_host_id'], host);
      final saved = await store.accounts();
      expect(saved.profiles.length, 2);
      expect(saved.activeId, 'team');
      expect(saved.profiles.first.label, isNot(saved.profiles.last.label));
      await expectLater(
        store.access('personal'),
        throwsA(isA<PlanAuthException>()),
      );
      await store.activate('personal');
      expect(
        await store.access('personal', model: 'visible'),
        'renewed-personal',
      );
      issuer.workspace = 'personal';
      issuer.deny = true;
      expect(await store.signIn(id: 'personal'), null);
      expect(issuer.logins.last.queryParameters['client_id'], 'personal');
      expect(
        issuer.logins.last.queryParameters.containsKey('id_token_hint'),
        true,
      );
      expect(await store.access('personal'), 'renewed-personal');
      expect(await store.signOut('personal'), true);
      expect((await store.accounts()).find('personal')!.connected, false);
      await expectLater(
        store.access('personal'),
        throwsA(isA<PlanAuthException>()),
      );
    },
  );
  test(
    'declined scope, wrong identity, audience, signature, nonce and expiration fail closed',
    () async {
      await store.signIn();
      issuer.workspace = 'second';
      issuer.scope = 'openid profile';
      await expectLater(store.signIn(), throwsA(isA<PlanAuthException>()));
      expect((await store.accounts()).activeId, 'personal');
      issuer.workspace = 'personal';
      issuer.scope = 'chatgpt.tokens.use.direct';
      issuer.subject = 'other-user';
      await expectLater(
        store.signIn(id: 'personal'),
        throwsA(isA<PlanAuthException>()),
      );
      final good = issuer.token('personal', nonce: 'n');
      for (final bad in [
        issuer.token('wrong', nonce: 'n'),
        issuer.token('personal', nonce: 'other'),
        issuer.token('personal', nonce: 'n', exp: 1),
        '${good.substring(0, good.lastIndexOf('.') + 1)}AA',
      ]) {
        await expectLater(
          store.oauth.verifyIdentity(bad, 'personal', nonce: 'n'),
          throwsA(isA<PlanAuthException>()),
        );
      }
      expect(await store.access('personal'), 'access-personal');
    },
  );
  test(
    'subscription uses one official Responses request and preserves a refusal regardless of presets and retries',
    () async {
      int calls = 0;
      final runtime = PlanRuntime(
        PlanEndpoint(store, (client: 'personal', model: 'visible')),
      );
      final req = AgentTurnRequest(
        userText: 'hello',
        imageModel: 'nai',
        customRules: [
          PresetRule(name: 'role', content: 'IMPORTED_PRESET_MARKER'),
        ],
        retries: 4,
        rerolls: 4,
        refusalKeywords: const ['cannot'],
      );
      final mock = MockClient((r) async {
        calls++;
        expect(r.url.toString(), '$planResource/responses');
        expect(r.followRedirects, false);
        expect(r.headers['Authorization'], 'Bearer fake-token');
        final body = jsonDecode(r.body);
        expect(body['store'], false);
        expect(body['stream'], true);
        expect(body.containsKey('reasoning'), false);
        expect(body['input'].last['content'], 'hello');
        expect(r.body, isNot(contains('IMPORTED_PRESET_MARKER')));
        return http.Response(
          'data: {"type":"response.refusal.delta","delta":"I cannot help."}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
          200,
        );
      });
      final events = await runtime.respond(req, mock, 'fake-token').toList();
      expect(
        events.whereType<AgentDone>().single.result.replyText,
        'I cannot help.',
      );
      expect(calls, 1);
      final refusal =
          'I cannot help.\n```nai_draw\n{"positive":"example"}\n```';
      final finalOnly = MockClient(
        (_) async => http.Response(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'refusal', 'refusal': refusal},
                  ],
                },
              ],
            },
          })}\n\n',
          200,
        ),
      );
      final refused =
          (await runtime
                  .respond(req, finalOnly, 'fake-token')
                  .where((e) => e is AgentDone)
                  .single)
              as AgentDone;
      expect(refused.result.hasDraw, isFalse);
      expect(refused.result.replyText, refusal);
      final partial = MockClient(
        (_) async => http.Response(
          'data: {"type":"response.output_text.delta","delta":"partial"}\n\n',
          200,
        ),
      );
      await expectLater(
        runtime.respond(req, partial, 'fake-token').drain<void>(),
        throwsA(isA<AgentFailure>()),
      );
    },
  );
  test(
    'the signed-in assistant uses the active preset and supported effort, imports the proposal and sends it to the canvas drawing service',
    () async {
      await store.signIn();
      final profile = await store.refreshModels('personal');
      await store.selectModels('personal', {'visible'});
      expect(profile.reasoning['visible'], {'medium', 'xhigh'});
      final stores = AppStores.ephemeral();
      final app = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          planStoreProvider.overrideWithValue(store),
          generationProvider.overrideWith(_DrawingService.new),
          tagLibraryProvider.overrideWith(_LocalReferences.new),
          botSessionProvider.overrideWith(_BotLibrarySession.new),
          publicTagsProvider(TagCategory.artist).overrideWith(
            (_) async => const [
              TagEntry(
                id: 'pub_D33',
                category: TagCategory.artist,
                publicId: 'D33',
                name: '海边画风',
                positive: '1.2::artist:fixture::, layered colors,',
                negative: '1.5::grain, blur::, watermark',
              ),
            ],
          ),
          publicTagsProvider(
            TagCategory.character,
          ).overrideWith((_) async => const []),
        ],
      );
      addTearDown(() async {
        app.dispose();
        await stores.flushForExit();
      });
      await app
          .read(assistantModelPrefProvider.notifier)
          .set(planModelKey('personal', 'visible'));
      await app.read(assistantSettingsProvider.future);
      await app
          .read(assistantSettingsProvider.notifier)
          .patch(
            (s) => s.copyWith(
              autoImport: true,
              autoGenerate: true,
              inlineImage: false,
              allowEditNegative: true,
              libraryScope: LibraryScope.all,
              ocPlaceholders: true,
              thinkLevel: ThinkLevel.ultra,
            ),
          );
      final model = app.read(generateProvider).params.model;
      final family = rulesFamilyOf(agentImageModel(model));
      await app.read(rulesLibraryProvider.future);
      await app
          .read(rulesLibraryProvider.notifier)
          .add(
            name: 'Art',
            author: '',
            models: {family},
            enableFor: family,
            rules: const [
              PresetRule(name: 'role', content: 'private persona'),
              PresetRule(name: 'palette', content: 'paint in watercolor'),
              PresetRule(
                name: 'comic',
                when: 'mode:comic',
                content: 'use three panels',
              ),
              PresetRule(
                name: 'natural',
                when: 'mode:natural',
                content: 'inactive rule',
              ),
              PresetRule(name: 'semantic_blocks', content: 'label the blocks'),
              PresetRule(
                name: 'disabled',
                content: 'disabled rule',
                enabled: false,
              ),
            ],
          );
      await app
          .read(rulesLibraryProvider.notifier)
          .add(
            name: 'Local draft',
            author: '',
            models: {family},
            enableFor: family,
            localOnly: true,
            rules: const [
              PresetRule(name: 'draft', content: 'fixture-local-only-content'),
            ],
          );
      final assistant = app.read(assistantProvider.notifier)
        ..setMode(AssistantMode.comic);
      final gen = app.read(generationProvider.notifier) as _DrawingService;
      final requests = <http.Request>[];
      expect(
        app.read(rulesLibraryProvider).requireValue.supplementFor(family),
        isNotNull,
      );
      final drawing = {
        'section': '海边',
        'positive': '__ARTIST_D33__\nbeach\nmoonlight',
        'negative': '',
        'blocks': {
          'positive': ['画风·D33', '场景·海岸', '光影·月光'],
        },
        'characters': [
          {'name': '猫娘', 'description': '__OC_猫猫__', 'position': '0.25,0.5'},
        ],
      };
      await http.runWithClient(
        () async {
          await assistant.send('用 D33 画一幅猫猫在海边的漫画');
          final sent = await gen.received.future.timeout(
            const Duration(seconds: 6),
            onTimeout: () =>
                throw StateError(app.read(assistantProvider).msgs.last.text),
          );
          expect(sent.params.model, model);
          expect(
            sent.characters.single.positive,
            '1.35::cat ears, silver hair::, {ribbon}',
          );
          expect(
            sent.negativePrompt,
            contains('1.5::grain, blur::, watermark'),
          );
          expect(
            app
                .read(generateProvider)
                .sections
                .last
                .foldLinks
                .where((l) => l.paired)
                .single
                .negativeBody,
            '1.5::grain, blur::, watermark',
          );
          expect(
            app.read(generateProvider).characters.single.positive,
            contains('silver hair'),
          );
        },
        () => MockClient((r) async {
          requests.add(r);
          final responseText = '画好了。\n```json\n${jsonEncode(drawing)}\n```';
          return http.Response(
            'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': responseText})}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      expect(requests.single.url.toString(), '$planResource/responses');
      final body = jsonDecode(utf8.decode(requests.single.bodyBytes)) as Map;
      expect(body['reasoning'], {'effort': 'xhigh'});
      expect(body['instructions'], contains('英文提示词'));
      expect(body['instructions'], isNot(contains('paint in watercolor')));
      expect(body['input'].last['content'], contains('D33 → __ARTIST_D33__'));
      expect(body['input'].last['content'], contains('猫娘 → __OC_猫娘__'));
      expect(requests.single.body, isNot(contains('artist:fixture')));
      final preferences = body['input'].first;
      expect(preferences['role'], 'user');
      expect(preferences['content'], contains('paint in watercolor'));
      expect(preferences['content'], contains('use three panels'));
      for (final inactive in [
        'fixture-local-only-content',
        'inactive rule',
        'disabled rule',
        'private persona',
      ]) {
        expect(requests.single.body, isNot(contains(inactive)));
      }
      final reply = app.read(assistantProvider).msgs.last;
      expect(reply.text, '画好了。');
      expect(reply.draw!.section, '海边');
      expect(
        reply.draw!.positive,
        contains('1.2::artist:fixture::, layered colors'),
      );
      expect(reply.draw!.positive, isNot(contains('__ARTIST_')));
      expect(reply.resources['artist']?['D33'], contains('layered colors'));
      expect(reply.draw!.blocks, isNotEmpty);
      expect(reply.change, isNotNull);
      await app.read(publicTagBlocksProvider.notifier).save({
        TagCategory.artist: const PublicTagRule(items: {'D33'}),
      });
      final settled = Completer<void>();
      final listener = app.listen(assistantProvider, (prev, next) {
        if (prev?.running == true && !next.running && !settled.isCompleted) {
          settled.complete();
        }
      });
      await http.runWithClient(
        () async {
          await assistant.send('再查 D33 和猫猫');
          await settled.future.timeout(const Duration(seconds: 6));
        },
        () => MockClient((r) async {
          requests.add(r);
          return http.Response(
            'data: {"type":"response.output_text.delta","delta":"OK"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      listener.close();
      final nextBody = jsonDecode(utf8.decode(requests.last.bodyBytes)) as Map;
      final input = nextBody['input'].toString();
      expect(input, contains('猫娘 → __OC_猫娘__'));
      expect(input, isNot(contains('__ARTIST_D33__')));
      expect(input, isNot(contains('artist:fixture')));
      expect(
        app.read(assistantProvider).msgs.last.resources['artist'] ?? {},
        isEmpty,
      );
      final plan = app.read(assistantEndpointProvider) as PlanEndpoint;
      expect(plan.thinkLevels, [
        ThinkLevel.auto,
        ThinkLevel.medium,
        ThinkLevel.ultra,
      ]);
      expect(plan.effortFor(ThinkLevel.off), isNull);

      // The same model name via a personally configured key uses the other route.
      const api = CustomEndpoint(
        id: 'my-api',
        name: 'My API',
        format: AgentApiFormat.openai,
        baseUrl: 'https://fixture.example/v1',
        apiKey: 'fixture',
        model: 'visible',
        wire: EndpointRoute.chat,
      );
      await app.read(customEndpointsProvider.future);
      await app.read(customEndpointsProvider.notifier).put(api);
      await app
          .read(assistantModelPrefProvider.notifier)
          .set(customModelKey(api.id, api.model));
      await app.read(publicTagBlocksProvider.notifier).save({});
      await app
          .read(assistantSettingsProvider.notifier)
          .patch((s) => s.copyWith(stream: false, autoGenerate: false));
      final finished = Completer<void>();
      final end = app.listen(assistantProvider, (before, after) {
        if (before?.running == true &&
            !after.running &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      try {
        await http.runWithClient(
          () async {
            await assistant.send('再用 D33 和猫猫画海边。');
            await finished.future.timeout(const Duration(seconds: 6));
          },
          () => MockClient((req) async {
            requests.add(req);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content':
                          'Done.\n```nai_draw\n${jsonEncode({...drawing, 'negative': '1.5::grain, blur::, watermark'})}\n```',
                    },
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
      } finally {
        end.close();
      }
      expect(requests.last.url.host, 'fixture.example');
      final apiBody = jsonDecode(utf8.decode(requests.last.bodyBytes)) as Map;
      final messages = apiBody['messages'] as List;
      expect(messages.first['content'], contains('paint in watercolor'));
      expect(
        messages.first['content'],
        isNot(contains('fixture-local-only-content')),
      );
      expect(messages.last['role'], 'user');
      expect(messages.last['content'], contains('fixture-local-only-content'));
      final fromApi = app.read(assistantProvider).msgs.last;
      expect(fromApi.text, 'Done.');
      final apiRow = app.read(generateProvider).sections.last;
      expect(
        apiRow.foldLinks.where((l) => l.paired).single.negativeBody,
        '1.5::grain, blur::, watermark',
      );
    },
  );
  test(
    'a subscription turn resolves only enabled libraries in their current order',
    () async {
      await store.signIn();
      await store.refreshModels('personal');
      await store.selectModels('personal', {'visible'});
      final stores = AppStores.ephemeral();
      final app = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          planStoreProvider.overrideWithValue(store),
          tagLibraryProvider.overrideWith(_LocalReferences.new),
        ],
      );
      addTearDown(() async {
        app.dispose();
        await stores.flushForExit();
      });
      final file = File('${temp.path}/references.json');
      await file.writeAsString(
        jsonEncode({
          'characters': [
            {
              'name': '猫娘',
              'aliases': ['猫猫'],
              'prompt': 'external outfit',
            },
          ],
        }),
      );
      final source = await app.read(ocRepositoryProvider).connect(file.uri);
      await app
          .read(assistantModelPrefProvider.notifier)
          .set(planModelKey('personal', 'visible'));
      await app.read(assistantSettingsProvider.future);
      final choice = LibrarySelection(
        order: [source.id, LibrarySelection.local, LibrarySelection.public],
        enabled: {source.id, LibrarySelection.local},
      );
      final family = rulesFamilyOf(
        agentImageModel(app.read(generateProvider).params.model),
      );
      await app.read(rulesLibraryProvider.future);
      await app
          .read(rulesLibraryProvider.notifier)
          .use(family, defaultPresetOf(family).id);
      var historyAndRequest = '';
      Future<String> ask(
        LibrarySelection selection, {
        String question = '画猫猫',
        String? rolePrompt,
      }) async {
        await app
            .read(assistantSettingsProvider.notifier)
            .patch(
              (s) => s.copyWith(
                sourceSelection: selection,
                ocPlaceholders: false,
                autoImport: true,
                autoGenerate: false,
                allowEditNegative: false,
              ),
            );
        final done = Completer<void>();
        final listener = app.listen(assistantProvider, (before, after) {
          if (before?.running == true && !after.running && !done.isCompleted) {
            done.complete();
          }
        });
        var attached = '';
        try {
          await http.runWithClient(
            () async {
              await app.read(assistantProvider.notifier).send(question);
              await done.future.timeout(const Duration(seconds: 6));
            },
            () => MockClient((r) async {
              final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
              attached = body['input'].last['content'] as String;
              historyAndRequest = body['input'].toString();
              final reply = rolePrompt != null
                  ? '好。\n```nai_draw\n${jsonEncode({
                      'positive': 'garden',
                      'characters': [
                        {'name': '主角', 'positive': rolePrompt},
                      ],
                    })}\n```'
                  : 'OK';
              return http.Response(
                'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': reply})}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
            }),
          );
          return attached;
        } finally {
          listener.close();
        }
      }

      final first = await ask(choice);
      expect(first, contains('external outfit'));
      expect(first, isNot(contains('silver hair')));
      final localFirst = choice.withOrder([
        LibrarySelection.local,
        source.id,
        LibrarySelection.public,
      ]);
      final next = await ask(localFirst, rolePrompt: '__OC_猫娘__, waving');
      expect(next, contains('1.35::cat ears, silver hair::, {ribbon}'));
      expect(next, contains('__OC_'));
      expect(next, isNot(contains('external outfit')));
      final role = app.read(generateProvider).characters.single;
      expect(role.positive, '1.35::cat ears, silver hair::, {ribbon}, waving');
      expect(
        role.foldLinks.single.positiveBody,
        '1.35::cat ears, silver hair::, {ribbon}',
      );
      expect(role.positiveRaw, endsWith(', waving'));
      await ask(
        localFirst,
        question: '改成眨眼',
        rolePrompt: '1.35::cat ears, silver hair::, {ribbon}, winking',
      );
      final edited = app.read(generateProvider).characters.single;
      expect(
        edited.foldLinks.single.positiveBody,
        role.foldLinks.single.positiveBody,
      );
      expect(edited.positiveRaw, endsWith(', winking'));
      final paused = await ask(choice.withPause(true));
      expect(paused, isNot(contains('external outfit')));
      expect(paused, isNot(contains('silver hair')));
      expect(historyAndRequest, isNot(contains('silver hair')));
    },
  );

  test(
    'a reference to an older canvas resolves its D33 block in the current local library',
    () async {
      const prompt = '1.3::artist:fixture::\nsoft edges';
      const request = AgentTurnRequest(
        userText: '沿用这个画风',
        imageModel: 'nai',
        canvas: CanvasSnapshot(
          positive: '__ARTIST_D33__',
          negative: '',
          characters: [],
        ),
        artists: [
          {'id': 'D33', 'name': '示例画风', 'prompt': prompt},
        ],
        resources: {
          'artist': {'PUBLIC': 'previous public style'},
        },
        customRules: [
          PresetRule(name: 'semantic_blocks', content: 'use labelled lines'),
        ],
      );
      final runtime = PlanRuntime(
        PlanEndpoint(store, (client: 'personal', model: 'visible')),
      );
      final reply =
          '继续。\n```nai_draw\n${jsonEncode({
            'positive': '__ARTIST_D33__\nsky',
            'blocks': {
              'positive': ['画风·D33', '场景·天空'],
            },
          })}\n```';
      final done =
          await runtime
                  .respond(
                    request,
                    MockClient((req) async {
                      final input =
                          jsonDecode(req.body)['input'].last['content']
                              as String;
                      expect(input, contains('D33 → __ARTIST_D33__'));
                      expect(input, isNot(contains('PUBLIC')));
                      expect(input, isNot(contains('artist:fixture')));
                      return http.Response(
                        'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': reply})}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
                        200,
                        headers: {
                          'content-type': 'text/event-stream; charset=utf-8',
                        },
                      );
                    }),
                    'fixture',
                  )
                  .where((e) => e is AgentDone)
                  .single
              as AgentDone;
      expect(done.result.positive, '$prompt\nsky');
      expect(done.result.resources['artist'], {'D33': prompt});
      expect(done.result.blocks.map((b) => b.name), contains('D33'));
    },
  );

  test(
    'subscription library off drops invented placeholders and previous resources',
    () async {
      final request = AgentTurnRequest(
        userText: 'D33',
        imageModel: 'nai',
        tools: const ToolSettings(
          disabledTools: {'search_artist', 'search_oc'},
        ),
        artists: const [
          {'id': 'D33', 'name': 'D33', 'prompt': 'private style'},
        ],
        resources: const {
          'artist': {'D33': 'private style'},
        },
      );
      final response =
          'OK\n```nai_draw\n{"positive":"sky, __ARTIST_D33__, __OC_cat__"}\n```';
      final runtime = PlanRuntime(
        PlanEndpoint(store, (client: 'personal', model: 'visible')),
      );
      final result =
          await runtime
                  .respond(
                    request,
                    MockClient((req) async {
                      final input = jsonDecode(
                        req.body,
                      )['input'].last['content'];
                      expect(input, 'D33');
                      return http.Response(
                        'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': response})}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
                        200,
                      );
                    }),
                    'fixture',
                  )
                  .where((e) => e is AgentDone)
                  .single
              as AgentDone;
      expect(result.result.positive, 'sky');
      expect(result.result.resources, isEmpty);
    },
  );

  test(
    'model selection is isolated by account, survives refresh and can stay empty',
    () async {
      issuer.additionalModels = ['spare'];
      final personal = (await store.signIn())!;
      expect((await store.refreshModels(personal)).selectedModels, isEmpty);
      expect(
        (await store.selectModels(personal, {
          'spare',
          'hidden',
        })).selectedModels.keys,
        ['spare'],
      );
      issuer.workspace = 'team';
      final team = (await store.signIn())!;
      expect((await store.refreshModels(team)).selectedModels, isEmpty);
      await store.selectModels(team, {'visible'});
      await expectLater(
        store.selectModels(personal, {}),
        throwsA(isA<PlanAuthException>()),
      );
      await store.activate(personal);
      expect((await store.accounts()).active!.selectedModels.keys, ['spare']);
      issuer.additionalModels = [];
      expect((await store.refreshModels(personal)).selectedModels, isEmpty);
      issuer.additionalModels = ['spare'];
      expect((await store.refreshModels(personal)).selectedModels.keys, [
        'spare',
      ]);
      await store.selectModels(personal, {'visible'});
      await store.selectModels(personal, {});
      await expectLater(
        store.access(personal, model: 'visible'),
        throwsA(isA<PlanAuthException>()),
      );
      await store.setEnabled(false);
      expect((await store.accounts()).enabled, isFalse);
    },
  );

  test(
    'old saved model catalogs regain workspace-specific reasoning levels on first use',
    () async {
      final id = (await store.signIn())!;
      await store.refreshModels(id);
      const key = 'chatgpt_plan_profiles_v1';
      final data = jsonDecode((await store.storage.read(key: key))!);
      (data['profiles'][id] as Map).remove('reasoning');
      (data['profiles'][id] as Map).remove('selected');
      await store.storage.write(key: key, value: jsonEncode(data));
      final upgraded = PlanStore(
        store.storage,
        store.oauth,
        directory: () async => temp,
        savedModel: () async => planModelKey(id, 'visible'),
      );
      final migrated = (await upgraded.accounts()).active!;
      expect(migrated.reasoning, isEmpty);
      expect(migrated.selectedModels.keys, ['visible']);
      expect(
        (await store.accounts(
          refreshOldCatalog: true,
        )).active!.reasoning['visible'],
        {'medium', 'xhigh'},
      );
      await store.accounts(refreshOldCatalog: true);
      expect(issuer.catalogs, 2);
    },
  );

  test(
    'both bundled NAI drawing presets retain composition rules and applicable modes',
    () async {
      for (final family in RulesFamily.values) {
        final rules = planDrawingRules(await bundledRules(family));
        expect(
          rules.map((r) => r.name),
          containsAll(['prompt_construction', 'output_specification']),
        );
        expect(rules.map((r) => r.name), isNot(contains('role')));
        expect(supportedModes(rules), contains(AssistantMode.natural));
        expect(
          supportedModes(rules).contains(AssistantMode.comic),
          family == RulesFamily.nai5,
        );
      }
    },
  );

  testWidgets(
    'first notice requires ten full seconds and later notices allow immediate confirmation',
    (tester) async {
      Future<void> show(bool first) => tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlanNotice(key: ValueKey(first), first: first),
          ),
        ),
      );
      FilledButton button() =>
          tester.widget(find.byKey(const ValueKey('plan-consent')));
      await show(true);
      expect(button().onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 9999));
      expect(button().onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(button().onPressed, isNotNull);
      await show(false);
      expect(button().onPressed, isNotNull);
    },
  );

  test(
    'refreshModels throws PlanAuthException on non-JSON HTTP 200 payload',
    () async {
      final badClient = MockClient(
        (req) async => http.Response('<html>bad gateway</html>', 200),
      );
      final badStore = PlanStore(
        store.storage,
        PlanOAuth(badClient),
        directory: () async => temp,
      );
      final id = (await store.signIn())!;
      await expectLater(
        badStore.refreshModels(id),
        throwsA(isA<PlanAuthException>()),
      );
    },
  );

  test(
    'corrupted profile missing email or label loads safely without TypeError',
    () async {
      const key = 'chatgpt_plan_profiles_v1';
      await store.storage.write(
        key: key,
        value: jsonEncode({
          'active': 'p1',
          'profiles': {
            'p1': {
              'models': {'m1': 'Model 1'},
              'selected': ['m1'],
            },
          },
        }),
      );
      final snapshot = await store.accounts();
      expect(snapshot.active, isNotNull);
      expect(snapshot.active!.email, isEmpty);
      expect(snapshot.active!.displayLabel, isEmpty);
    },
  );

  test(
    'PlanRuntime skips malformed SSE JSON frames instead of crashing stream',
    () async {
      final runtime = PlanRuntime(
        PlanEndpoint(store, (client: 'personal', model: 'visible')),
      );
      final done =
          await runtime
                  .respond(
                    AgentTurnRequest(userText: 'hello', imageModel: 'nai'),
                    MockClient((_) async {
                      return http.Response(
                        'data: {truncated-json\n\n'
                        'data: {"type":"response.output_text.delta","delta":"普通回复。"}\n\n'
                        'data: {"type":"response.completed","response":{"status":"completed"}}\n\n',
                        200,
                        headers: {
                          'content-type': 'text/event-stream; charset=utf-8',
                        },
                      );
                    }),
                    'fixture',
                  )
                  .where((e) => e is AgentDone)
                  .single
              as AgentDone;
      expect(done.result.replyText, '普通回复。');
    },
  );
}
