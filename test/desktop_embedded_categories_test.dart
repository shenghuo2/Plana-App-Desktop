import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  Finder tab(TagCategory category) =>
      find.byKey(ValueKey('desktop-inspiration-${category.name}'));
  Finder search(TagCategory category) =>
      find.byKey(ValueKey('tag-search-${category.name}'));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_embedded_categories_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        publicTagsProvider.overrideWith((ref, cat) async => []),
        tagAuthorNamesProvider.overrideWith((ref) async => {}),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    await c.read(tagLibraryProvider.future);
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    syncCustomTagCategories(const []);
    assert(
      temp.absolute.path.startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}plana_embedded_categories_',
      ),
    );
    temp.deleteSync(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 400,
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              platform: TargetPlatform.windows,
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: width,
                  child: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 850),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: const InspirationPage(embedded: true),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await pumpUntilComplete(
      tester,
      c.read(tagLibraryProvider.notifier).settled,
    );
    await pumpUntilComplete(tester, stores.flushForExit());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  Future<void> runSidebarTest(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } finally {
      await finish(tester);
    }
  }

  for (final (name, width, scale, dark) in [
    ('normal', 400.0, 1.0, false),
    ('narrow-dark', 310.0, 1.4, true),
  ]) {
    testWidgets(
      'new managed category is visible and clickable in sidebar: $name',
      (tester) => runSidebarTest(tester, () async {
        await mount(tester, width: width, scale: scale, dark: dark);
        await tester.tap(find.byTooltip('管理类别'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('新建类别'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '服装');
        await tester.pumpAndSettle();
        await tester.tap(find.text('无图'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('创建'));
        await pumpUntil(
          tester,
          () => c.read(tagLibraryProvider).value!.customDefs.isNotEmpty,
        );
        await tester.pumpAndSettle();
        final added = c.read(tagLibraryProvider).value!.customDefs.single;
        // Dismiss only the manager; the new category should reveal itself.
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(tab(added.key), findsOneWidget);
        expect(tab(added.key).hitTestable(), findsOneWidget);
        expect(search(TagCategory.character), findsOneWidget);
        await captureDesktop(tester, capture, 'embedded-category-added-$name');
        await tester.tap(tab(added.key));
        await tester.pumpAndSettle();
        expect(search(added.key), findsOneWidget);
      }),
    );
  }

  testWidgets(
    'mouse drag from a category scrolls without selecting; click still selects',
    (tester) => runSidebarTest(tester, () async {
      final added = <TagCategoryDef>[];
      await tester.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          added.add(
            await c
                .read(tagLibraryProvider.notifier)
                .addCategory(
                  label: '类别$i',
                  iconName: 'Tag',
                  layout: TagCardLayout.none,
                ),
          );
        }
      });
      await mount(tester);
      final scrollable = find
          .ancestor(
            of: tab(TagCategory.character),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, 0);
      final drag = await tester.startGesture(
        tester.getCenter(tab(TagCategory.scene)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 150));
      await drag.moveBy(const Offset(-20, 0));
      await tester.pump();
      await drag.moveBy(const Offset(-220, 0));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(100));
      expect(search(TagCategory.character), findsOneWidget);
      final visible = added.firstWhere(
        (d) => tab(d.key).hitTestable().evaluate().isNotEmpty,
      );
      final click = await tester.startGesture(
        tester.getCenter(tab(visible.key)),
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
      await tester.pumpAndSettle();
      expect(search(visible.key), findsOneWidget);
      await captureDesktop(tester, capture, 'embedded-category-mouse-drag');
    }),
  );

  testWidgets(
    'renaming, reordering and deleting selected category update the live strip',
    (tester) => runSidebarTest(tester, () async {
      final added = (await tester.runAsync(
        () => c
            .read(tagLibraryProvider.notifier)
            .addCategory(
              label: '测试类别',
              iconName: 'Tag',
              layout: TagCardLayout.none,
            ),
      ))!;
      await mount(tester);
      await tester.ensureVisible(tab(added.key));
      await tester.pumpAndSettle();
      await tester.tap(tab(added.key));
      await tester.pumpAndSettle();
      await tester.enterText(search(added.key), '测试');
      await pumpUntilComplete(
        tester,
        c
            .read(tagLibraryProvider.notifier)
            .updateCategory(
              TagCategoryDef.custom(
                id: added.webId,
                label: '改名类别',
                iconName: 'Tag',
                layout: TagCardLayout.none,
              ),
            ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: tab(added.key), matching: find.text('改名类别')),
        findsOneWidget,
      );
      final from = c
          .read(tagLibraryProvider)
          .value!
          .visibleTabKeys
          .indexOf(added.webId);
      await pumpUntilComplete(
        tester,
        c.read(tagLibraryProvider.notifier).moveTab(from, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(tab(added.key)).dx,
        lessThan(tester.getTopLeft(tab(TagCategory.character)).dx),
      );
      await pumpUntilComplete(
        tester,
        c.read(tagLibraryProvider.notifier).removeCategory(added.key),
      );
      await tester.pumpAndSettle();
      expect(tab(added.key), findsNothing);
      expect(search(TagCategory.character), findsOneWidget);
      expect(tab(TagCategory.character).hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<TextField>(search(TagCategory.character))
            .controller!
            .text,
        isEmpty,
      );
    }),
  );
}
