import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/desktop/desktop_workspace.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/codex/codex_favorites.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_providers.dart';
import 'package:plana_app/features/inspiration/codex/codex_view.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/l10n/app_localizations.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

class _Acknowledged extends CodexIntro {
  @override
  bool? build() => true;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const styles = CodexMeta(
    id: 'styles',
    type: CodexType.string,
    title: '画风词典',
    entryCount: 2,
  );
  const scenes = CodexMeta(
    id: 'scenes',
    type: CodexType.composition,
    title: '场景法典',
    entryCount: 1,
  );
  late Directory temp;
  late AppStores stores;
  late ProviderContainer c;
  late int indexLoads;
  var disposed = false;
  final capture = GlobalKey();
  Finder key(String id) => find.byKey(ValueKey(id));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_creation_codex_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: '{"enableCompletion":false,"showTranslation":false}',
    );
    await stores.prefs.write(
      key: 'assistant_settings',
      value: '{"introVersion":$kAssistantIntroVersion}',
    );
    indexLoads = 0;
    disposed = false;
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
        publicTagsProvider.overrideWith((ref, cat) async => []),
        tagAuthorNamesProvider.overrideWith((ref) async => {}),
        codexIntroProvider.overrideWith(_Acknowledged.new),
        codexIndexProvider.overrideWith((ref) async {
          indexLoads++;
          return [styles, scenes];
        }),
        codexMediaProvider.overrideWith((ref) async => CodexMedia.fallback),
        codexTagZhProvider.overrideWith((ref, id) async => null),
        codexDataProvider.overrideWith(
          (ref, id) async => id == styles.id
              ? const CodexData(
                  meta: styles,
                  entries: [
                    CodexEntry(
                      id: 'sea',
                      title: '水彩海岸',
                      tags: 'watercolor, sea',
                      path: ['自然'],
                    ),
                    CodexEntry(
                      id: 'forest',
                      title: '森林',
                      tags: 'forest, soft light',
                      path: ['自然'],
                    ),
                  ],
                  tree: [CodexNode('自然', 2, [])],
                )
              : const CodexData(
                  meta: scenes,
                  entries: [
                    CodexEntry(id: 'sky', title: '夜空', tags: 'night sky'),
                  ],
                ),
        ),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    await c.read(tagLibraryProvider.future);
    await c.read(codexFavoritesProvider.future);
  });
  tearDown(() {
    if (!disposed) c.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    assert(
      temp.absolute.path.startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}plana_creation_codex_',
      ),
    );
    temp.deleteSync(recursive: true);
  });

  for (final (name, size, scale, dark) in [
    ('wide', const Size(1440, 900), 1.0, false),
    ('narrow-dark', const Size(1100, 850), 1.4, true),
    ('compact', const Size(880, 800), 1.0, false),
  ]) {
    testWidgets('creation codex entry, browsing and import: $name', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      c.read(generateProvider.notifier).setPrompts(positive: 'original prompt');
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh'),
              theme: theme.copyWith(
                platform: TargetPlatform.windows,
                textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const Scaffold(body: DesktopWorkspace()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        indexLoads,
        0,
        reason: 'Do not fetch codex before its tab is opened',
      );
      expect(find.byType(CodexView, skipOffstage: false), findsNothing);
      expect(
        tester.getRect(key('desktop-codex-tab')).left,
        greaterThan(tester.getRect(key('desktop-inspiration-tab')).right),
      );
      await tester.tap(key('desktop-codex-tab'));
      await tester.pumpAndSettle();
      expect(indexLoads, 1);
      expect(key('desktop-codex-pane'), findsOneWidget);
      expect(key('codex-picker-button').hitTestable(), findsOneWidget);
      expect(key('codex-category-picker').hitTestable(), findsOneWidget);
      final pickerRect = tester.getRect(key('codex-picker-button'));
      final searchRect = tester.getRect(key('desktop-codex-search'));
      expect(pickerRect.center.dy, closeTo(searchRect.center.dy, 1));
      expect(pickerRect.right, lessThan(searchRect.left));
      expect(
        tester.getRect(key('codex-category-picker')).top,
        greaterThan(searchRect.bottom),
      );
      if (size.width >= 1100) {
        expect(
          tester.getRect(key('desktop-ai-tab')).left,
          closeTo(tester.getRect(key('desktop-right-pane')).left + 46, 1),
        );
      }
      expect(
        tester.getRect(key('desktop-canvas-new')).right,
        lessThanOrEqualTo(tester.getRect(key('desktop-left-collapse')).left),
      );
      await tester.enterText(key('desktop-codex-search'), 'sea');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(key('desktop-codex-card-sea'), findsOneWidget);
      expect(key('desktop-codex-card-forest'), findsNothing);
      final searchController = tester
          .widget<TextField>(key('desktop-codex-search'))
          .controller;
      final leftWidth = tester.getSize(key('desktop-controls')).width;
      final rightWidth = size.width >= 1100
          ? tester.getSize(key('desktop-right-pane')).width
          : null;
      await tester.tap(key('desktop-left-collapse'));
      await tester.pumpAndSettle();
      expect(key('desktop-left-divider'), findsNothing);
      expect(tester.getSize(key('desktop-controls')).width, 36);
      await tester.tap(key('desktop-right-collapse'));
      await tester.pumpAndSettle();
      expect(key('desktop-right-divider'), findsNothing);
      expect(key('desktop-codex-pane'), findsNothing);
      expect(key('desktop-canvas'), findsOneWidget);
      expect(key('desktop-left-expand').hitTestable(), findsOneWidget);
      expect(key('desktop-right-expand').hitTestable(), findsOneWidget);
      await captureDesktop(tester, capture, 'sidebars-collapsed-$name');
      tester.view.physicalSize = const Size(780, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-right-expand'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-left-expand'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(key('desktop-controls')).width,
        closeTo(leftWidth, .01),
      );
      if (rightWidth != null) {
        expect(
          tester.getSize(key('desktop-right-pane')).width,
          closeTo(rightWidth, .01),
        );
      }
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller,
        same(searchController),
      );
      expect(searchController!.text, 'sea');
      expect(c.read(generateProvider).prompt, 'original prompt');
      if (size.width > 1100) {
        Future<void> resize(String id, double delta) async {
          final start = tester.getCenter(key(id));
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.down(start);
          await mouse.moveTo(start + Offset(delta / 2, 0));
          await tester.pump();
          await mouse.moveTo(start + Offset(delta, 0));
          await mouse.up();
          await mouse.removePointer();
          await tester.pumpAndSettle();
        }

        final leftButton = tester.getRect(key('desktop-left-collapse'));
        await resize('desktop-left-divider', 80);
        expect(
          tester.getRect(key('desktop-left-collapse')).left,
          closeTo(leftButton.left + 80, 1),
        );
        final rightButton = tester.getRect(key('desktop-right-collapse'));
        await resize('desktop-right-divider', -100);
        expect(
          tester.getRect(key('desktop-right-collapse')).left,
          closeTo(rightButton.left - 100, 1),
        );
        expect(
          tester.getRect(key('desktop-canvas-new')).right,
          lessThanOrEqualTo(tester.getRect(key('desktop-left-collapse')).left),
        );
        await tester.tap(key('desktop-left-collapse'));
        await tester.pumpAndSettle();
        await resize('desktop-right-divider', -100);
        expect(
          tester.getRect(key('desktop-right-collapse')).left,
          closeTo(rightButton.left - 200, 1),
        );
        await tester.tap(key('desktop-left-expand'));
        await tester.pumpAndSettle();
        await captureDesktop(tester, capture, 'sidebars-resized');
      }
      await tester.tap(key('desktop-inspiration-tab'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-inspiration-scene'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-codex-tab'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        'sea',
      );
      await tester.tap(key('codex-picker-button'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('场景法典'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-card-sky'), findsOneWidget);
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        isEmpty,
      );
      await captureDesktop(tester, capture, 'creation-codex-$name');
      await tester.tap(key('desktop-codex-card-sky'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入提示词'));
      await tester.pumpAndSettle();
      final generated = c.read(generateProvider);
      expect(generated.prompt, 'original prompt');
      expect(generated.sections, hasLength(2));
      expect(generated.sections.first.isMain, isTrue);
      expect(generated.sections.last.name, '夜空');
      expect(generated.sections.last.positive, 'night sky');
      expect(key('desktop-codex-pane'), findsOneWidget);
      c.read(shellIndexProvider.notifier).select(kTabGallery);
      await tester.tap(find.text('去创作'));
      await tester.pumpAndSettle();
      expect(c.read(shellIndexProvider), kTabCreate);
      expect(tester.takeException(), isNull);
      await tester.tap(key('desktop-inspiration-tab'));
      await tester.pumpAndSettle();
      expect(key('tag-search-scene'), findsOneWidget);
      if (size.width < 1100) {
        await tester.tap(key('desktop-canvas-tab'));
        await tester.pumpAndSettle();
        expect(key('desktop-canvas'), findsOneWidget);
        await tester.tap(key('desktop-codex-tab'));
        await tester.pumpAndSettle();
        expect(key('desktop-codex-card-sky'), findsOneWidget);
      }
      expect(indexLoads, 1);
      expect(tester.takeException(), isNull);
      await pumpUntilComplete(tester, stores.flushForExit());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      c.dispose();
      disposed = true;
    });
  }
}
