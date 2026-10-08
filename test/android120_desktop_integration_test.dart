import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/auth/credential_store.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/generate/widgets/desktop_canvas_tabs.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async => const BotSession(sessionId: 'test');
}

class _Settings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async => const AssistantSettings(
    introVersion: kAssistantIntroVersion,
    libraryScope: LibraryScope.none,
    autoImport: true,
    stream: false,
  );
}

class _Rules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

class _Backend extends BackendBaseNotifier {
  _Backend(this.base);
  final String base;
  @override
  Future<String> build() async => base;
}

class _LocalHttp extends HttpOverrides {}

class _Presets extends PromptPresetsNotifier {
  @override
  Future<PromptPresetsState> build() async =>
      const PromptPresetsState(presets: kDefaultPromptPresets);
}

const _pair = PromptFoldLink(
  id: 'pair',
  positiveName: 'style',
  positiveBody: 'rain, ~unused~',
  negativeName: 'style',
  negativeBody: 'blurry',
);

GenerateState _draft() => GenerateState.initial().copyWith(
  prompt: 'rain',
  negativePrompt: 'blurry',
  promptRaw: '<#style: rain, ~unused~>',
  negativePromptRaw: '<#style: blurry>',
  promptFoldLinks: [_pair],
  characters: const [
    CharacterPrompt(
      id: 'id201',
      name: 'OC',
      positive: '1girl',
      negative: '',
      position: 'B2',
      enabled: false,
      avatar: 'https://example.test/avatar.png',
    ),
  ],
  sections: const [
    PromptSection.main(),
    PromptSection(id: 'id202', name: '场景', positive: 'forest', negative: 'fog'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late Directory root;
  ProviderContainer? container;
  var flushedInWidget = false;
  setUp(() async {
    flushedInWidget = false;
    stores = AppStores.ephemeral();
    root = stores.desktopOutput.root.parent;
    FlutterSecureStorage.setMockInitialValues({});
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
  });
  tearDown(() async {
    container?.dispose();
    container = null;
    // Futures created in a widget's fake-async zone must finish while that
    // zone is still being pumped; awaiting them again here can never settle.
    if (!flushedInWidget) await stores.flushForExit();
    root.deleteSync(recursive: true);
  });

  ProviderContainer boot() => container = ProviderContainer(
    overrides: [
      appStoresProvider.overrideWithValue(stores),
      desktopModeProvider.overrideWithValue(true),
      promptPresetsProvider.overrideWith(_Presets.new),
    ],
  );

  test(
    'desktop never adopts plaintext credentials after Android recovery markers',
    () async {
      await stores.prefs.write(key: CredentialStore.backendKey, value: 'file');
      await stores.prefs.write(key: CredentialStore.canaryKey, value: 'lost');
      final credentials = await CredentialStore.open(stores.prefs, root: root);
      expect(credentials.usesFile, isFalse);
      await credentials.write(
        key: 'nai_access_keys',
        value: 'encrypted-fixture',
      );
      expect(
        await const FlutterSecureStorage().read(key: 'nai_access_keys'),
        'encrypted-fixture',
      );
      expect(
        File('${root.path}/${CredentialStore.fileName}').existsSync(),
        isFalse,
      );
      expect(credentials.takeLostNotice(), isFalse);
    },
  );

  test(
    'v1 migration backs up bytes and retains backup blobs through GC and rollback',
    () async {
      final image = Uint8List.fromList([1, 3, 5, 7]);
      final legacy = _draft().copyWith(img2img: Img2ImgConfig(image: image));
      final encoded = await encodeGenerateState(legacy, stores.blobs);
      final file = File('${root.path}/workspace/state.json')
        ..createSync(recursive: true);
      final original = jsonEncode({
        'v': 1,
        'idSeq': 101,
        'refs': encoded.refs.toList(),
        'state': encoded.json,
      });
      file.writeAsStringSync(original);
      await stores.workspace.load();
      expect(stores.workspace.initial!.promptFoldLinks, [_pair]);
      expect(stores.workspace.idSeq, greaterThan(202));
      final backup = File('${file.path}.pre-v3.bak');
      expect(backup.readAsStringSync(), original);
      final c = boot();
      final gen = c.read(generateProvider.notifier);
      c.read(canvasWorkspaceProvider.notifier).create();
      gen.disableImg2Img();
      await stores.flushForExit();
      expect((jsonDecode(file.readAsStringSync()) as Map)['v'], 3);
      await stores.blobs.gc(
        await stores.workspace.liveRefs(strict: true),
        minAge: Duration.zero,
      );
      for (final hash in encoded.refs) {
        expect(await stores.blobs.get(hash), isNotNull);
      }
      // Rollback is an explicit restoration of the original file, not a v3 rewrite.
      await backup.copy(file.path);
      await stores.workspace.load();
      expect(stores.workspace.initial!.img2img!.image, image);
      expect(
        stores.workspace.initial!.characters.single.avatar,
        legacy.characters.single.avatar,
      );
      expect(backup.readAsStringSync(), original);
    },
  );

  test(
    'corrupt migrated workspace recovers legacy backup and preserves corrupt evidence',
    () async {
      final encoded = await encodeGenerateState(_draft(), stores.blobs);
      final file = File('${root.path}/workspace/state.json')
        ..createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({'v': 1, 'state': encoded.json}));
      await stores.workspace.load();
      file.writeAsStringSync('{truncated');
      await stores.workspace.load();
      expect(stores.workspace.initial!.prompt, 'rain');
      expect(File('${file.path}.corrupt.bak').readAsStringSync(), '{truncated');
      await expectLater(
        stores.workspace.liveRefs(strict: true),
        throwsFormatException,
      );
    },
  );

  test(
    'section snapshots keep disabled drafts and unique paired folds through JSON',
    () async {
      final source = _draft().copyWith(
        sections: [
          const PromptSection.main(),
          PromptSection(
            id: 'id202',
            name: '场景',
            positive: 'forest',
            negative: 'fog',
            positiveRaw: '<#style: forest>',
            negativeRaw: '<#style: fog>',
            foldLinks: [
              const PromptFoldLink(
                id: 'pair',
                positiveName: 'style',
                positiveBody: 'forest',
                negativeName: 'style',
                negativeBody: 'fog',
              ),
            ],
          ),
          const PromptSection(
            id: 'id203',
            name: '关闭',
            positive: 'hidden',
            enabled: false,
          ),
        ],
      );
      final snapshot = composeSections(source);
      expect(snapshot.prompt, 'rain, forest');
      expect(snapshot.promptRaw, contains('~unused~'));
      expect(snapshot.promptRaw, isNot(contains('hidden')));
      expect(snapshot.promptFoldLinks, hasLength(2));
      expect(snapshot.promptFoldLinks.map((l) => l.id).toSet(), hasLength(2));
      expect(
        snapshot.promptFoldLinks.map((l) => l.positiveName).toSet(),
        hasLength(2),
      );
      final encoded = await encodeGenerateState(snapshot, stores.blobs);
      final restored = await decodeGenerateState(encoded.json, stores.blobs);
      expect(restored.promptFoldLinks, snapshot.promptFoldLinks);
      expect(restored.promptRaw, snapshot.promptRaw);
      expect(composeSections(restored).prompt, 'rain, forest');
      expect(
        PromptSnapshot.fromJson(
          PromptSnapshot.of(source).toJson(),
        ).sameAs(PromptSnapshot.of(source)),
        isTrue,
      );
    },
  );

  test(
    'corrupt workspace backup failure still allows legacy recovery',
    () async {
      final encoded = await encodeGenerateState(_draft(), stores.blobs);
      final file = File('${root.path}/workspace/state.json')
        ..createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({'v': 1, 'state': encoded.json}));
      await stores.workspace.load();
      file.writeAsStringSync('{truncated');
      Directory('${file.path}.corrupt.bak').createSync();
      await stores.workspace.load();
      expect(stores.workspace.initial!.prompt, 'rain');
      expect(stores.workspace.initial!.promptFoldLinks, [_pair]);
      expect(file.readAsStringSync(), '{truncated');
    },
  );

  test(
    'deduplication keeps disabled tokens and fold links instead of discarding all drafts',
    () {
      final s = _draft().copyWith(
        sections: [
          const PromptSection.main(),
          const PromptSection(
            id: 'id202',
            name: '同词',
            positive: 'rain, forest',
            positiveRaw: '<#scene: rain, forest>, ~archived~',
          ),
        ],
      );
      final composed = composeSections(s);
      expect(composed.prompt, 'rain, forest');
      expect(composed.promptRaw, contains('~unused~'));
      expect(composed.promptRaw, contains('~archived~'));
      expect(composed.promptFoldLinks, [_pair]);
    },
  );

  test(
    'delayed base image applies shared bytes and source canvas dimensions',
    () {
      final c = boot();
      final gen = c.read(generateProvider.notifier);
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final a = canvases.create();
      final b = canvases.create();
      final before = c.read(generateProvider).params;
      final image = Uint8List.fromList([1, 2, 3]);
      gen.setImg2ImgImage(image: image, width: 1024, height: 1024, canvasId: a);
      expect(c.read(canvasWorkspaceProvider).activeId, b);
      expect(c.read(generateProvider).params, same(before));
      expect(c.read(generateProvider).img2img!.image, image);
      canvases.select(a);
      expect(c.read(generateProvider).params.width, 1024);
      expect(c.read(generateProvider).params.height, 1024);
      canvases.select(b);
      expect(c.read(generateProvider).params.width, before.width);
      expect(c.read(generateProvider).params.height, before.height);
      canvases.remove(a);
      gen.setImg2ImgImage(
        image: Uint8List.fromList([9]),
        width: 512,
        height: 512,
        canvasId: a,
      );
      expect(c.read(generateProvider).img2img!.image, image);
      expect(c.read(generateProvider).params.width, before.width);
    },
  );

  for (final target in ['main', 'role', 'section']) {
    test(
      '$target editor writes and undoes the original canvas after switching',
      () async {
        final c = boot();
        final gen = c.read(generateProvider.notifier);
        gen.applyCanvas(CanvasPrompts.of(_draft()));
        final canvases = c.read(canvasWorkspaceProvider.notifier);
        final a = c.read(canvasWorkspaceProvider).activeId;
        final child = ProviderContainer(
          parent: c,
          overrides: [
            editorProvider.overrideWith(
              () => EditorNotifier(immediateWriteBack: true),
            ),
          ],
        );
        final editor = child.read(editorProvider.notifier);
        editor.load(
          positive: target == 'role'
              ? '1girl'
              : target == 'section'
              ? 'forest'
              : '<#style: rain, ~unused~>',
          negative: target == 'role'
              ? ''
              : target == 'section'
              ? 'fog'
              : '<#style: blurry>',
          startPositive: true,
          charId: target == 'role' ? 'id201' : null,
          sectionId: target == 'section' ? 'id202' : null,
        );
        editor.editActive('original canvas changed');
        final b = canvases.create();
        editor.editActive('late write');
        expect(c.read(generateProvider).prompt, isEmpty);
        expect(c.read(canvasWorkspaceProvider).activeId, b);
        editor.undo();
        editor.flushWriteBack();
        final prompts = c.read(canvasWorkspaceProvider).find(a)!.prompts;
        final actual = target == 'role'
            ? prompts.characters.single.positive
            : target == 'section'
            ? prompts.sections.last.positive
            : prompts.prompt;
        expect(
          actual,
          target == 'role'
              ? '1girl'
              : target == 'section'
              ? 'forest'
              : 'rain',
        );
        child.dispose();
        canvases.select(a);
        final remounted = ProviderContainer(
          parent: c,
          overrides: [
            editorProvider.overrideWith(
              () => EditorNotifier(immediateWriteBack: true),
            ),
          ],
        );
        remounted
            .read(editorProvider.notifier)
            .load(
              positive: target == 'role'
                  ? '1girl'
                  : target == 'section'
                  ? 'forest'
                  : '<#style: rain, ~unused~>',
              negative: target == 'role'
                  ? ''
                  : target == 'section'
                  ? 'fog'
                  : '<#style: blurry>',
              startPositive: true,
              charId: target == 'role' ? 'id201' : null,
              sectionId: target == 'section' ? 'id202' : null,
            );
        expect(
          remounted.read(editorProvider).positiveText,
          isNot(contains('late write')),
        );
        remounted.dispose();
      },
    );
  }

  for (final deleted in [false, true]) {
    test(
      'delayed assistant completion targets source canvas (deleted=$deleted)',
      () async {
        final received = Completer<void>(),
            release = Completer<void>(),
            finished = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await utf8.decoder.bind(request).join();
          received.complete();
          await release.future;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: final\ndata: {"positive":"AI result","negative":"new negative"}\n\n',
          );
          await request.response.close();
        });
        final c = container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            desktopModeProvider.overrideWithValue(true),
            botSessionProvider.overrideWith(_Session.new),
            assistantEndpointProvider.overrideWithValue(null),
            backendBaseProvider.overrideWith(
              () => _Backend('http://127.0.0.1:${server.port}'),
            ),
            assistantSettingsProvider.overrideWith(_Settings.new),
            rulesLibraryProvider.overrideWith(_Rules.new),
          ],
        );
        await c.read(backendBaseProvider.future);
        await c.read(assistantSettingsProvider.future);
        final gen = c.read(generateProvider.notifier),
            canvases = c.read(canvasWorkspaceProvider.notifier);
        canvases.create();
        gen.applyCanvas(CanvasPrompts.of(_draft()));
        final a = c.read(canvasWorkspaceProvider).activeId;
        final before = PromptSnapshot.of(c.read(generateProvider));
        final subscription = c.listen(assistantProvider, (p, n) {
          if (p?.running == true && !n.running && !finished.isCompleted) {
            finished.complete();
          }
        });
        await HttpOverrides.runZoned(() async {
          await c.read(assistantProvider.notifier).send('change A');
          await received.future.timeout(const Duration(seconds: 10));
          final b = canvases.create();
          gen.setPrompts(positive: 'B untouched');
          if (deleted) canvases.remove(a);
          release.complete();
          await finished.future.timeout(const Duration(seconds: 10));
          expect(c.read(canvasWorkspaceProvider).activeId, b);
          expect(c.read(generateProvider).prompt, 'B untouched');
          final msg = c.read(assistantProvider).msgs.last;
          expect(msg.draw!.positive, 'AI result');
          if (deleted) {
            expect(msg.change, isNull);
          } else {
            expect(
              c.read(canvasWorkspaceProvider).find(a)!.prompts.prompt,
              'AI result',
            );
            expect(msg.change!.canvasId, a);
            expect(c.read(assistantProvider.notifier).undo(msg.id), isTrue);
            expect(
              PromptSnapshot.of(
                c
                    .read(canvasWorkspaceProvider)
                    .find(a)!
                    .prompts
                    .applyTo(c.read(generateProvider)),
              ).sameAs(before),
              isTrue,
            );
            expect(c.read(generateProvider).prompt, 'B untouched');
          }
        }, createHttpClient: _LocalHttp().createHttpClient);
        subscription.close();
      },
    );
  }

  testWidgets(
    'identical canvas drafts reload and pending chip input commits at switch',
    (tester) async {
      final c = boot();
      final gen = c.read(generateProvider.notifier),
          canvases = c.read(canvasWorkspaceProvider.notifier);
      gen.setPrompts(positive: 'same');
      final a = c.read(canvasWorkspaceProvider).activeId;
      final b = canvases.create(duplicate: true);
      canvases.select(a);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: DesktopPromptCard()),
          ),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'pending');
      canvases.select(b);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
      expect(c.read(generateProvider).prompt, 'same');
      expect(
        c.read(canvasWorkspaceProvider).find(a)!.prompts.prompt,
        contains('pending'),
      );
      await tester.pumpWidget(const SizedBox());
      stores.flushNow();
      await tester.pump(const Duration(seconds: 1));
      await flushStores(tester, stores);
      flushedInWidget = true;
      c.dispose();
      container = null;
    },
  );

  testWidgets(
    'desktop canvas tabs fit narrow/wide windows at 80/100/140 percent text',
    (tester) async {
      final c = boot();
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      for (var i = 0; i < 5; i++) {
        final id = canvases.create();
        canvases.rename(id, 'long canvas name $i');
      }
      for (final width in [310.0, 680.0]) {
        for (final scale in [.8, 1.0, 1.4]) {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                theme: AppTheme.light(),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      child: MediaQuery(
                        data: MediaQueryData(
                          textScaler: TextScaler.linear(scale),
                        ),
                        child: const DesktopCanvasTabs(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 3),
          );
          expect(
            find.byKey(const ValueKey('desktop-canvas-actions')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
      stores.flushNow();
      await tester.pump(const Duration(seconds: 1));
      await flushStores(tester, stores);
      flushedInWidget = true;
      c.dispose();
      container = null;
    },
  );
}

Future<void> flushStores(WidgetTester tester, AppStores stores) async {
  var done = false;
  final future = stores.flushForExit().then((_) => done = true);
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    done,
    isTrue,
    reason: 'Storage queues must complete before widget teardown',
  );
  await future;
}
