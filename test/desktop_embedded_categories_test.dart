import 'dart:convert';
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
import 'package:plana_app/features/inspiration/widgets/inspiration_entry_card.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  final sidebarCapture = GlobalKey();
  final publicEntries = <TagEntry>[];
  Finder tab(TagCategory category) =>
      find.byKey(ValueKey('desktop-inspiration-${category.name}'));
  Finder search(TagCategory category) =>
      find.byKey(ValueKey('tag-search-${category.name}'));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    publicEntries.clear();
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
        publicTagsProvider.overrideWith(
          (ref, cat) async => [
            for (final entry in publicEntries)
              if (entry.category == cat) entry,
          ],
        ),
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
    FloatAccent? floatAccent,
  }) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = floatAccent != null
        ? AppTheme.float(dark ? Brightness.dark : Brightness.light, floatAccent)
        : dark
        ? AppTheme.dark()
        : AppTheme.light();
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
                    child: RepaintBoundary(
                      key: sidebarCapture,
                      child: const InspirationPage(embedded: true),
                    ),
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

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> waitForArt(WidgetTester tester, Finder region) async {
    if (Platform.environment['PLANA_SIDEBAR_TEST_ART'] == null) return;
    final images = find.descendant(of: region, matching: find.byType(RawImage));
    await pumpUntil(
      tester,
      () =>
          images.evaluate().isNotEmpty &&
          tester.widgetList<RawImage>(images).every((w) => w.image != null),
    );
    await tester.pumpAndSettle();
  }

  Future<void> seedSidebar(WidgetTester tester) async {
    final art = Platform.environment['PLANA_SIDEBAR_TEST_ART'];
    await tester.runAsync(() async {
      final library = c.read(tagLibraryProvider.notifier);
      for (final (i, fixture) in [
        ('洛丽塔凉夏', 'lolita', ['粉发', '洛丽塔裙', '蝴蝶结'], '1girl, pink hair, ribbon'),
        ('女仆凉', 'maid-blue', ['蓝发', '女仆装'], 'blue hair, maid'),
        ('凉', 'water-blue', ['水色', '白裙'], 'blue hair, white dress'),
        ('女仆凉夏', 'maid-pink', ['粉发', '女仆装'], 'pink hair, maid'),
        ('白裙猫耳', 'lilac', ['银发', '猫耳'], 'silver hair, cat ears'),
        ('凉夏', 'ribbon-pink', <String>[], 'ribbon, pink hair'),
      ].indexed) {
        await library.upsert(
          TagEntry(
            id: 'a$i',
            category: TagCategory.character,
            name: fixture.$1,
            tags: fixture.$3,
            positive: fixture.$4,
            previews: [if (art != null) '$art/${fixture.$2}.webp'],
            createdAt: 10 - i,
            favorite: i == 1,
          ),
        );
      }
    });
  }

  for (final (name, width, scale, dark) in [
    ('light', 400.0, 1.0, false),
    ('dark', 330.0, 1.0, true),
  ]) {
    testWidgets(
      'sidebar card controls, themed layout and paged prompts ($name)',
      (tester) => runSidebarTest(tester, () async {
        await seedSidebar(tester);
        await mount(
          tester,
          width: width,
          scale: scale,
          dark: dark,
          floatAccent: kFloatBlue,
        );
        for (final id in [
          'sidebar-scope-0',
          'sidebar-scope-1',
          'sidebar-favorites-filter',
        ]) {
          final control = key(id);
          expect(control.hitTestable(), findsOneWidget);
          expect(tester.getSize(control).height, greaterThanOrEqualTo(42));
          final label = tester
              .widget<ButtonStyleButton>(control)
              .style!
              .textStyle!
              .resolve({});
          expect(label!.fontSize, greaterThanOrEqualTo(15));
          expect(label.fontWeight, FontWeight.w700);
        }
        expect(
          tester.getCenter(key('sidebar-scope-0')).dy,
          tester.getCenter(key('sidebar-favorites-filter')).dy,
        );
        final scheme = Theme.of(
          tester.element(tab(TagCategory.character)),
        ).colorScheme;
        final active = tester
            .widget<TextButton>(tab(TagCategory.character))
            .style!;
        final inactive = tester
            .widget<TextButton>(tab(TagCategory.scene))
            .style!;
        expect(active.backgroundColor!.resolve({}), scheme.primary);
        expect(active.foregroundColor!.resolve({}), scheme.onPrimary);
        expect(inactive.backgroundColor!.resolve({}), isNot(scheme.surface));
        final rows = [
          tab(TagCategory.character),
          key('sidebar-inspiration-tools'),
          search(TagCategory.character),
          key('sidebar-scope-0'),
          key('inspiration-card-a0'),
        ].map(tester.getRect).toList();
        for (var i = 1; i < rows.length; i++) {
          expect(rows[i - 1].bottom, lessThanOrEqualTo(rows[i].top));
        }
        expect(
          tester.getTopLeft(key('inspiration-card-a0')).dy,
          tester.getTopLeft(key('inspiration-card-a1')).dy,
        );
        expect(
          tester.getCenter(key('inspiration-select-a0')).dx,
          lessThan(tester.getCenter(key('inspiration-star-a0')).dx),
        );
        expect(
          tester.getCenter(key('inspiration-menu-a0')).dy,
          greaterThan(tester.getCenter(key('inspiration-star-a0')).dy),
        );
        final labels = tester.widget<Text>(key('inspiration-tags-a0'));
        expect(labels.data, '粉发 · 洛丽塔裙 · …');
        expect(labels.overflow, TextOverflow.ellipsis);
        expect(key('inspiration-tags-a5'), findsNothing);
        expect(find.text('1girl, pink hair, ribbon'), findsNothing);
        expect(find.text('灵感图册'), findsNothing);
        await waitForArt(tester, find.byKey(sidebarCapture));
        await captureDesktop(
          tester,
          sidebarCapture,
          'sidebar-inspiration-$name',
        );

        await tester.tap(key('inspiration-menu-a0'));
        await tester.pumpAndSettle();
        final menu = find.byType(PopupMenuItem<InspirationEntryAction>);
        expect(menu, findsNWidgets(3));
        expect(
          find.descendant(of: menu, matching: find.text('删除')),
          findsNothing,
        );
        await captureDesktop(tester, capture, 'sidebar-inspiration-menu-$name');
        await tester.tap(
          find.widgetWithText(PopupMenuItem<InspirationEntryAction>, '查看提示词'),
        );
        await tester.pumpAndSettle();
        final dialog = key('inspiration-prompt-detail');
        final header = find
            .ancestor(
              of: find.descendant(
                of: dialog,
                matching: find.byType(CloseButton),
              ),
              matching: find.byType(Row),
            )
            .first;
        expect(
          find.descendant(of: header, matching: find.text('洛丽塔凉夏')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('1 / 6')),
          findsOneWidget,
        );
        await waitForArt(tester, dialog);
        await captureDesktop(
          tester,
          capture,
          'sidebar-inspiration-detail-$name',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: dialog, matching: find.text('1 / 6')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: dialog, matching: find.text('2 / 6')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一项'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: header, matching: find.text('女仆凉')),
          findsOneWidget,
        );
        await tester.tap(key('inspiration-detail-select'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(find.text('删除'), findsOneWidget);
        expect(tester.widget<InspirationEntryCard>(key('a1')).selected, isTrue);
        expect(
          tester.widget<InspirationEntryCard>(key('a0')).selected,
          isFalse,
        );
      }),
    );
  }

  testWidgets(
    'custom category follows the appearance accent and its tag manager is the rightmost tool',
    (tester) => runSidebarTest(tester, () async {
      final category = (await tester.runAsync(
        () => c
            .read(tagLibraryProvider.notifier)
            .addCategory(
              label: '服装',
              iconName: 'Tag',
              layout: TagCardLayout.none,
            ),
      ))!;
      final accent = floatAccents.firstWhere((a) => a.key == 'rose');
      await mount(tester, width: 310, scale: 1.4, floatAccent: accent);
      await tester.ensureVisible(tab(category.key));
      await tester.pumpAndSettle();
      await tester.tap(tab(category.key));
      await tester.pumpAndSettle();
      final style = tester.widget<TextButton>(tab(category.key)).style!;
      expect(style.backgroundColor!.resolve({}), accent.light);
      final row = key('sidebar-inspiration-tools');
      final positions =
          [
                Icons.dashboard_customize_outlined,
                Icons.sort,
                Icons.cloud_outlined,
                Icons.add,
                Icons.settings_outlined,
              ]
              .map(
                (icon) => tester
                    .getCenter(
                      find.descendant(of: row, matching: find.byIcon(icon)),
                    )
                    .dx,
              )
              .toList();
      expect(positions, orderedEquals([...positions]..sort()));
      expect(
        find.descendant(of: row, matching: find.text('管理标签')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('管理标签'));
      await tester.pumpAndSettle();
      expect(find.text('服装标签池'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }),
  );

  testWidgets(
    'editing private labels updates the card and preserves its star on disk',
    (tester) => runSidebarTest(tester, () async {
      await seedSidebar(tester);
      await mount(tester);
      await tester.tap(key('inspiration-star-a0'));
      await pumpUntil(
        tester,
        () => c
            .read(tagLibraryProvider)
            .requireValue
            .entries
            .any((entry) => entry.id == 'a0' && entry.isFavorite),
      );
      await tester.tap(key('sidebar-favorites-filter'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-a0'), findsOneWidget);
      expect(key('inspiration-card-a2'), findsNothing);
      await tester.tap(key('inspiration-menu-a0'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(PopupMenuItem<InspirationEntryAction>, '编辑'),
      );
      await tester.pumpAndSettle();
      final details = key('tag-editor-details');
      final createTag = find
          .descendant(of: details, matching: find.text('新建'))
          .last;
      await tester.ensureVisible(createTag);
      await tester.pumpAndSettle();
      expect(createTag.hitTestable(), findsOneWidget);
      await tester.tap(createTag);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '新建标签…'), 'A新标签');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: key('tag-editor-save-actions'),
              matching: find.text('保存修改'),
            )
            .first,
      );
      await pumpUntil(
        tester,
        () => key('tag-editor-dialog').evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(key('inspiration-tags-a0')).data,
        startsWith('A新标签'),
      );
      await pumpUntilComplete(
        tester,
        c.read(tagLibraryProvider.notifier).settled,
      );
      final saved =
          jsonDecode(
                File('${temp.path}/tag_library.json').readAsStringSync(),
              )['entries']
              as List;
      final restored = TagEntry.fromJson(
        saved.firstWhere((e) => e['id'] == 'a0'),
      )!;
      expect(restored.tags, contains('A新标签'));
      expect(restored.isFavorite, isTrue);
    }),
  );

  testWidgets(
    'style, scene and text cards copy their actual prompts from the anchored menu',
    (tester) => runSidebarTest(tester, () async {
      String? copied;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const categories = [
        TagCategory.artist,
        TagCategory.scene,
        TagCategory.other,
      ];
      await tester.runAsync(() async {
        for (final cat in categories) {
          await c
              .read(tagLibraryProvider.notifier)
              .upsert(
                TagEntry(
                  id: cat.name,
                  category: cat,
                  name: '条目',
                  positive: '1.2::soft light::, ${cat.name}',
                  tags: const ['柔光', '长标签长标签长标签长标签长标签长标签', '更多'],
                ),
              );
        }
      });
      await mount(tester, width: 330);
      for (final cat in categories) {
        await tester.tap(tab(cat));
        await tester.pumpAndSettle();
        final labels = tester.widget<Text>(key('inspiration-tags-${cat.name}'));
        expect(labels.data, startsWith('柔光'));
        expect(labels.overflow, TextOverflow.ellipsis);
        await tester.tap(key('inspiration-menu-${cat.name}'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(PopupMenuItem<InspirationEntryAction>, '复制提示词'),
        );
        await tester.pumpAndSettle();
        expect(copied, '1.2::soft light::, ${cat.name}');
        expect(
          find.byType(PopupMenuItem<InspirationEntryAction>),
          findsNothing,
        );
      }
    }),
  );

  test(
    'a legacy public copy keeps its star independently of a same-name original',
    () {
      const original = TagEntry(
        id: 'local',
        name: '同名',
        category: TagCategory.character,
      );
      final legacy = original.copyWith(id: 'old', origin: TagOrigin.favorited);
      final newer = original.copyWith(
        id: 'newer',
        publicId: '2',
        favorite: false,
      );
      final findCopy = TagLibraryState(
        entries: [original, legacy, newer],
      ).publicCopyLookup(TagCategory.character);
      expect(findCopy(original.copyWith(publicId: '1')), same(legacy));
      expect(findCopy(original.copyWith(publicId: '2')), same(newer));
      expect(legacy.isFavorite, isTrue);
      expect(original.isFavorite, isFalse);
    },
  );

  testWidgets(
    'public sidebar uses private labels and reversible favorites for the linked entry',
    (tester) => runSidebarTest(tester, () async {
      publicEntries.add(
        const TagEntry(
          id: 'pub_1',
          publicId: '1',
          category: TagCategory.character,
          name: '公共角色',
          positive: 'white hair',
          createdBy: 'someone',
        ),
      );
      await mount(tester);
      await tester.tap(key('sidebar-scope-1'));
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-star-pub_1'));
      await pumpUntil(
        tester,
        () => c
            .read(tagLibraryProvider)
            .requireValue
            .entries
            .any((entry) => entry.publicId == '1' && entry.isFavorite),
      );
      final library = c.read(tagLibraryProvider.notifier);
      final local = c.read(tagLibraryProvider).requireValue.entries.single;
      expect(local.origin, TagOrigin.favorited);
      await pumpUntilComplete(
        tester,
        library.upsert(local.copyWith(tags: ['自己的标签'])),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('inspiration-tags-pub_1')).data, '自己的标签');
      await tester.tap(key('sidebar-favorites-filter'));
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-star-pub_1'));
      await pumpUntil(
        tester,
        () =>
            !c.read(tagLibraryProvider).requireValue.entries.single.isFavorite,
      );
      expect(key('inspiration-card-pub_1'), findsNothing);
      await tester.tap(key('sidebar-scope-0'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-${local.id}'), findsNothing);
      await tester.tap(key('sidebar-favorites-filter'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(key('inspiration-tags-${local.id}')).data,
        '自己的标签',
      );
      final entry = c.read(tagLibraryProvider).requireValue.entries.single;
      expect(entry.isFavorite, isFalse);
      expect(
        library.isCollected(entry.category, publicId: '1', name: entry.name),
        isFalse,
      );
      expect(
        await pumpUntilComplete(tester, library.collect(publicEntries.single)),
        isTrue,
      );
      expect(c.read(tagLibraryProvider).requireValue.entries.single.tags, [
        '自己的标签',
      ]);
      expect(
        decodeBackupEntry(entry.category, encodeBackupEntry(entry))!.isFavorite,
        isFalse,
      );
      expect(
        TagEntry.fromJson({...entry.toJson()}..remove('favorite'))!.isFavorite,
        isTrue,
      );
    }),
  );

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
    'sidebar categories scroll with the thumb, wheel or a drag and remain clickable',
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
      final viewport = tester.getRect(scrollable);
      // Grab the unpainted part of the scrollbar gutter.
      final thumb = await tester.startGesture(
        Offset(viewport.left + 32, viewport.bottom - 14),
        kind: PointerDeviceKind.mouse,
      );
      await thumb.moveBy(const Offset(20, 0));
      await tester.pump();
      await thumb.moveBy(const Offset(70, 0));
      await thumb.up();
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(60));
      final beforeWheel = position.pixels;
      Future<void> wheel(double delta) async {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: viewport.center,
            kind: PointerDeviceKind.mouse,
            scrollDelta: Offset(0, delta),
          ),
        );
        await tester.pumpAndSettle();
      }

      await wheel(32);
      expect(position.pixels, closeTo(beforeWheel + 32, 1));
      await wheel(-position.maxScrollExtent);
      expect(position.pixels, 0);
      expect(search(TagCategory.character), findsOneWidget);
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
