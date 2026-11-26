import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/remote_image.dart';
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
  const seaImage = 'https://example.test/coastal-station.png';
  const forestImage = 'https://example.test/moonlit-waterfall.png';
  const forestOriginal = 'https://example.test/full/moonlit-waterfall.png';
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
    RemoteImageStore.bind(temp);
    for (final url in [seaImage, forestImage, forestOriginal]) {
      final file = File(
        'examples/inspiration-previews/${Uri.parse(url).pathSegments.last}',
      );
      await RemoteImageStore.write(url, await file.readAsBytes());
      RemoteImageStore.markChecked(url);
    }
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
        codexIndexProvider.overrideWithBuild((ref, _) async {
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
                      image: seaImage,
                      path: ['自然'],
                    ),
                    CodexEntry(
                      id: 'forest',
                      title: '森林',
                      tags: 'forest, soft light',
                      image: forestImage,
                      original: forestOriginal,
                      imageWidth: 1024,
                      imageHeight: 1536,
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
      final categoryRect = tester.getRect(key('codex-category-picker'));
      final searchRect = tester.getRect(key('desktop-codex-search'));
      final count = tester.getRect(key('embedded-codex-summary'));
      expect(find.text('全部词条'), findsOneWidget);
      expect(find.text('· 2 条'), findsOneWidget);
      final favorites = tester.getRect(key('desktop-codex-favorites'));
      final random = tester.getRect(key('desktop-codex-random'));
      expect(pickerRect.center.dy, closeTo(categoryRect.center.dy, 1));
      expect(pickerRect.right, lessThan(categoryRect.left));
      expect(searchRect.top, greaterThan(categoryRect.bottom));
      expect(searchRect.left, closeTo(pickerRect.left, 1));
      expect(searchRect.right, closeTo(categoryRect.right, 1));
      expect(count.top, greaterThan(searchRect.bottom));
      expect(count.right, lessThan(favorites.left));
      expect(count.center.dy, closeTo(favorites.center.dy, 1));
      expect(favorites.right, lessThan(random.left));
      expect(favorites.center.dy, closeTo(random.center.dy, 1));
      expect(find.text('随机灵感'), findsOneWidget);
      expect(find.text('法典图册'), findsNothing);
      final firstCard = key('desktop-codex-card-sea');
      final firstRect = tester.getRect(firstCard);
      final secondRect = tester.getRect(key('desktop-codex-card-forest'));
      expect(firstRect.top, greaterThan(random.bottom));
      expect(secondRect.top, firstRect.top);
      expect(secondRect.left, greaterThan(firstRect.right));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: firstRect.center);
      await tester.pump(const Duration(milliseconds: 150));
      Finder hoverAction(String label) =>
          find.descendant(of: firstCard, matching: key('codex-hover-$label'));
      final firstAction = tester.getRect(hoverAction('导入图片'));
      for (final label in ['导入图片', '复制提示词', '创建分区并导入', '导入主提示词']) {
        final action = hoverAction(label);
        expect(action.hitTestable(), findsOneWidget);
        final rect = tester.getRect(action);
        expect(rect.center.dy, closeTo(firstAction.center.dy, 1));
        expect(firstRect.contains(rect.topLeft), isTrue);
        expect(firstRect.contains(rect.bottomRight), isTrue);
        expect(rect.width, greaterThanOrEqualTo(26));
      }
      final loadedArt = find.descendant(
        of: firstCard,
        matching: find.byType(RawImage),
      );
      await pumpUntil(
        tester,
        () =>
            tester.widgetList<RawImage>(loadedArt).any((w) => w.image != null),
      );
      final artRect = tester.getRect(loadedArt);
      expect(artRect.width / artRect.height, closeTo(.88, .055));
      await captureDesktop(tester, capture, 'creation-codex-two-columns-$name');
      final forestCard = key('desktop-codex-card-forest');
      final forestCenter = tester.getCenter(
        find.descendant(of: forestCard, matching: find.byType(RemoteImage)),
      );
      await mouse.moveTo(forestCenter);
      await tester.pump(const Duration(milliseconds: 400));
      final largeImage = key('codex-hover-preview');
      await pumpUntil(tester, () => largeImage.evaluate().isNotEmpty);
      final large = tester.getRect(largeImage);
      final pane = tester.getRect(key('desktop-codex-grid'));
      expect(pane.inflate(.01).intersect(large), large);
      expect(large.width, greaterThan(secondRect.width * 1.3));
      expect(large.width / large.height, closeTo(2 / 3, .01));
      for (final label in ['导入图片', '复制提示词', '创建分区并导入', '导入主提示词']) {
        expect(
          find
              .descendant(of: forestCard, matching: key('codex-hover-$label'))
              .hitTestable(),
          findsOneWidget,
        );
      }
      await captureDesktop(tester, capture, 'creation-codex-large-image-$name');
      final favorite = find.descendant(
        of: forestCard,
        matching: find.byTooltip('收藏'),
      );
      await mouse.moveTo(tester.getCenter(favorite));
      await mouse.down(tester.getCenter(favorite));
      await mouse.up();
      await pumpUntil(
        tester,
        () => find
            .descendant(of: forestCard, matching: find.byTooltip('取消收藏'))
            .evaluate()
            .isNotEmpty,
      );
      expect(largeImage, findsNothing);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      if (size.width >= 1100) {
        expect(
          tester.getRect(key('desktop-ai-tab')).left,
          closeTo(tester.getRect(key('desktop-right-pane')).left + 46, 1),
        );
      }
      expect(
        tester.getRect(key('desktop-canvas-actions')).right,
        lessThanOrEqualTo(tester.getRect(key('desktop-left-collapse')).left),
      );
      await tester.enterText(key('desktop-codex-search'), 'sea');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(key('desktop-codex-card-sea'), findsOneWidget);
      expect(key('desktop-codex-card-forest'), findsNothing);
      expect(find.text('· 1 条'), findsOneWidget);
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
      // The entire collapsed rail, including blank space far below its arrow,
      // expands the pane in both the full and compact workspace layouts.
      final rightRail = tester.getRect(key('desktop-right-collapsed-rail'));
      await tester.tapAt(Offset(rightRail.center.dx, rightRail.bottom - 24));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创作参数').hitTestable());
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
        expect(tester.getRect(firstCard).width, greaterThan(firstRect.width));
        await mouse.addPointer(location: tester.getCenter(firstCard));
        await tester.pump(const Duration(milliseconds: 150));
        expect(
          tester.getRect(hoverAction('导入图片')).width,
          greaterThan(firstAction.width),
        );
        await mouse.removePointer();
        expect(
          tester.getRect(key('desktop-right-collapse')).left,
          closeTo(rightButton.left - 100, 1),
        );
        expect(
          tester.getRect(key('desktop-canvas-actions')).right,
          lessThanOrEqualTo(tester.getRect(key('desktop-left-collapse')).left),
        );
        await tester.tap(key('desktop-left-collapse'));
        await tester.pumpAndSettle();
        await resize('desktop-right-divider', -100);
        expect(
          tester.getRect(key('desktop-right-collapse')).left,
          closeTo(rightButton.left - 200, 1),
        );
        final leftRail = tester.getRect(key('desktop-left-collapsed-rail'));
        await tester.tapAt(leftRail.center);
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
      await tester.tap(find.text('创建分区并导入'));
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
