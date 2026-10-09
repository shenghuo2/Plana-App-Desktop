import 'dart:convert';
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
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_providers.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

import 'support/desktop_capture.dart';

class _Acknowledged extends CodexIntro {
  @override
  bool? build() => true;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  final capture = GlobalKey();
  final entries = [
    for (var i = 0; i < 8; i++)
      TagEntry(
        id: 'char$i',
        category: TagCategory.character,
        name: [
          '白发少女',
          '森林旅人',
          '暮色精灵',
          '午后访客',
          '海风与少年',
          '花园来信',
          '雪中旅人',
          '星夜猫娘',
        ][i],
        positive: [
          'white hair, blue eyes, 1girl',
          'traveler, green eyes, forest',
          'elf, purple hair, sunset',
          '1girl, brown hair, cafe',
          '1boy, ocean, white shirt',
          '1girl, garden, flowers',
          'snow, traveler, white hair',
          'cat girl, night, stars',
        ][i],
        aliases: ['别名$i'],
        tags: [if (i == 0) '白发'],
        createdAt: 10 - i,
      ),
    const TagEntry(
      id: 'scene0',
      category: TagCategory.scene,
      name: '樱花树下',
      positive: 'cherry blossoms',
    ),
  ];
  const publicEntry = TagEntry(
    id: 'pub_cat',
    category: TagCategory.character,
    name: '公共猫娘',
    positive: 'cat girl, white hair',
    publicId: 'cat',
    createdBy: '10001',
  );

  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_inspiration_layout_');
    File('${temp.path}/tag_library.json').writeAsStringSync(
      jsonEncode({'entries': entries.map((e) => e.toJson()).toList()}),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        codexIntroProvider.overrideWith(_Acknowledged.new),
        codexIndexProvider.overrideWith(
          (ref) async => const [
            CodexMeta(id: 'styles', type: CodexType.string, title: '画风词典'),
          ],
        ),
        codexMediaProvider.overrideWith((ref) async => CodexMedia.fallback),
        codexDataProvider.overrideWith(
          (ref, id) async => const CodexData(
            meta: CodexMeta(
              id: 'styles',
              type: CodexType.string,
              title: '画风词典',
            ),
            entries: [],
          ),
        ),
        codexTagZhProvider.overrideWith((ref, id) async => null),
        publicTagsProvider.overrideWith(
          (ref, cat) async => cat == TagCategory.character ? [publicEntry] : [],
        ),
        tagAuthorNamesProvider.overrideWith((ref) async => {'10001': '示例作者'}),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    temp.deleteSync(recursive: true);
  });
  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> mount(WidgetTester tester, {bool embedded = false}) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              platform: TargetPlatform.windows,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: embedded
                ? const Scaffold(
                    body: Align(
                      alignment: Alignment.topRight,
                      child: SizedBox(
                        width: 330,
                        child: MediaQuery(
                          data: MediaQueryData(size: Size(330, 900)),
                          child: InspirationPage(embedded: true),
                        ),
                      ),
                    ),
                  )
                : const InspirationPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  void seedTagPools() {
    File('${temp.path}/tag_library.json').writeAsStringSync(
      jsonEncode({
        'entries': [
          ...entries.map((entry) => entry.toJson()),
          for (final category in TagCategory.values)
            TagEntry(
              id: 'tail-${category.name}',
              category: category,
              name: '末尾标签测试',
              positive: 'forest',
              tags: const ['tag-39'],
            ).toJson(),
        ],
        'pools': {
          for (final category in TagCategory.values)
            tagCategoryDef(category).webId: [
              for (var i = 0; i < 40; i++)
                'tag-${i.toString().padLeft(2, '0')}',
              '非常长的标签名称，用于验证窄侧栏里完整标签仍然可以选择和取消',
            ],
        },
      }),
    );
  }

  testWidgets(
    'all four tag pools scroll to their last tag and keep the selection visible',
    (tester) async {
      seedTagPools();
      await mount(tester);
      for (final category in TagCategory.values) {
        await tester.tap(key('inspiration-category-${category.name}'));
        await tester.pumpAndSettle();
        final scope = tagCategoryDef(category).hasPublic
            ? findsOneWidget
            : findsNothing;
        expect(key('inspiration-scope-mine'), scope);
        expect(key('inspiration-scope-public'), scope);
        final filters = tester.getRect(
          key('inspiration-tag-filters-${category.name}'),
        );
        final manage = tester.getRect(key('inspiration-manage-tags'));
        expect(manage.right, closeTo(filters.right, 0.01));
        expect(
          manage.center.dy,
          closeTo(tester.getCenter(key('inspiration-all-tags')).dy, 0.01),
        );
        final count = find.text(
          '${container.read(tagLibraryProvider).value!.of(category).length} 个条目',
        );
        expect(tester.getTopLeft(count).dx - manage.right, closeTo(12, 0.01));
        if (!tagCategoryDef(category).hasPublic) {
          expect(filters.left, 24);
        }
        final strip = key('inspiration-tag-strip');
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(strip),
            scrollDelta: const Offset(0, 5000),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(ChoiceChip, 'tag-39').hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(ChoiceChip, 'tag-39'));
        await tester.pumpAndSettle();
        expect(key('inspiration-tag-picker'), findsNothing);
        expect(
          find.widgetWithText(ChoiceChip, 'tag-39').hitTestable(),
          findsOneWidget,
        );
        expect(key('inspiration-card-tail-${category.name}'), findsOneWidget);
        if (category == TagCategory.character) {
          expect(key('inspiration-card-char0'), findsNothing);
        }
        await tester.tap(find.widgetWithText(ChoiceChip, 'tag-39'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
              .selected,
          isTrue,
        );
      }
      await captureDesktop(tester, capture, 'desktop-inspiration-tag-filters');
      await finish(tester);
    },
  );

  testWidgets(
    'mouse drag, horizontal wheel and arrows browse tags without selecting them',
    (tester) async {
      seedTagPools();
      await mount(tester);
      final strip = key('inspiration-tag-strip');
      final scroll = tester.widget<SingleChildScrollView>(strip).controller!;
      await tester.drag(
        strip,
        const Offset(-280, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(key('inspiration-card-char0'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
            .selected,
        isTrue,
      );

      final afterDrag = scroll.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(strip),
          scrollDelta: const Offset(-120, 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(afterDrag));

      final tail = find.widgetWithText(ChoiceChip, 'tag-39');
      for (var i = 0; i < 20 && tail.hitTestable().evaluate().isEmpty; i++) {
        await tester.tap(key('inspiration-tags-right'));
        await tester.pumpAndSettle();
      }
      expect(tail.hitTestable(), findsOneWidget);
      await tester.tap(tail);
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsNothing);
      expect(key('inspiration-card-tail-character'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsOneWidget);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(strip),
          scrollDelta: const Offset(-5000, 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(
        tester.widget<IconButton>(key('inspiration-tags-left')).onPressed,
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'tag search, Enter, dismissal and deleted filters preserve the right results',
    (tester) async {
      seedTagPools();
      await mount(tester);
      await tester.tap(key('inspiration-all-tags'));
      await tester.pumpAndSettle();
      await tester.enterText(key('inspiration-tag-search'), 'TAG-39');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'tag-39'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'tag-00'), findsNothing);
      await captureDesktop(tester, capture, 'desktop-inspiration-tag-search');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsNothing);
      expect(key('inspiration-card-tail-character'), findsOneWidget);

      await tester.tap(key('inspiration-all-tags'));
      await tester.pumpAndSettle();
      await tester.enterText(key('inspiration-tag-search'), 'missing-tag');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的标签'), findsOneWidget);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(key('inspiration-tag-list'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsNothing);

      await tester.tap(key('inspiration-all-tags'));
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-tag-clear'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-all-tags'));
      await tester.pumpAndSettle();
      await tester.enterText(key('inspiration-tag-search'), 'tag-39');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(key('inspiration-card-tail-character'), findsOneWidget);
      await tester.runAsync(
        () => container
            .read(tagLibraryProvider.notifier)
            .removePoolTag(TagCategory.character, 'tag-39'),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'tag-39'), findsNothing);
      expect(key('inspiration-card-char0'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
            .selected,
        isTrue,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'narrow embedded tag pools support long labels and anchored selection',
    (tester) async {
      seedTagPools();
      await mount(tester, embedded: true);
      final filters = tester.getRect(key('inspiration-tag-filters-character'));
      expect(
        tester.getRect(key('inspiration-manage-tags')).right,
        closeTo(filters.right, 0.01),
      );
      expect(
        tester.getTopLeft(key('inspiration-all-tags')).dy,
        greaterThan(
          tester.getBottomLeft(find.widgetWithText(ChoiceChip, '全部')).dy,
        ),
      );
      await tester.tap(key('inspiration-all-tags'));
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('inspiration-tag-picker'));
      expect(panel.right, lessThanOrEqualTo(1500));
      expect(panel.width, 360);
      await tester.enterText(key('inspiration-tag-search'), '非常长的标签名称');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final longChip = find.widgetWithText(
        ChoiceChip,
        '非常长的标签名称，用于验证窄侧栏里完整标签仍然可以选择和取消',
      );
      expect(longChip.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesktop(
        tester,
        capture,
        'desktop-inspiration-embedded-tags',
      );
      await tester.tap(longChip);
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-manage-tags'));
      await tester.pumpAndSettle();
      expect(find.text('角色标签池'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'desktop toolbar, responsive cards, filters and details preserve browsing state',
    (tester) async {
      await mount(tester);
      final search = key('tag-search-character');
      expect(tester.getSize(search).width, 300);
      expect(
        tester.getCenter(search).dy,
        closeTo(
          tester.getCenter(key('inspiration-category-character')).dy,
          0.01,
        ),
      );
      expect(
        tester.getTopLeft(key('inspiration-card-char0')).dy,
        tester.getTopLeft(key('inspiration-card-char5')).dy,
      );
      expect(
        tester.getTopLeft(key('inspiration-card-char6')).dy,
        greaterThan(tester.getTopLeft(key('inspiration-card-char0')).dy),
      );
      await captureDesktop(tester, capture, 'windows16-inspiration-wide');

      await tester.tap(key('inspiration-detail-char0'));
      await tester.pumpAndSettle();
      expect(key('inspiration-detail-dialog'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getSize(key('inspiration-detail-dialog')).width,
        lessThanOrEqualTo(1500),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isFalse,
      );

      await tester.enterText(search, '别名0');
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsOneWidget);
      expect(key('inspiration-card-char1'), findsNothing);
      tester.view.physicalSize = const Size(740, 700);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, '别名0');
      expect(tester.takeException(), isNull);
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'windows16-inspiration-compact');
      await tester.tap(find.widgetWithText(ChoiceChip, '白发'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char1'), findsNothing);
      await tester.tap(key('inspiration-category-scene'));
      await tester.pumpAndSettle();
      expect(key('inspiration-scope-mine'), findsNothing);
      expect(key('inspiration-scope-public'), findsNothing);
      expect(key('inspiration-card-scene0'), findsOneWidget);
      await tester.tap(key('inspiration-category-other'));
      await tester.pumpAndSettle();
      expect(key('inspiration-scope-mine'), findsNothing);
      expect(key('inspiration-scope-public'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('compact codex toolbar preserves tag search and filtering', (
    tester,
  ) async {
    await mount(tester);
    final search = key('tag-search-character');
    await tester.enterText(search, '别名0');
    await tester.tap(find.widgetWithText(ChoiceChip, '白发'));
    await tester.pumpAndSettle();
    await tester.tap(key('inspiration-category-codex'));
    await tester.pumpAndSettle();
    final button = key('codex-picker-button');
    expect(tester.getSize(button).width, lessThan(200));
    final anchor = tester.getRect(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(key('desktop-popover')).top,
      closeTo(anchor.bottom + 8, 1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(740, 700);
    await tester.pumpAndSettle();
    expect(tester.getSize(button).width, lessThan(200));
    await tester.tap(key('inspiration-category-character'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, '别名0');
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '白发')).selected,
      isTrue,
    );
    expect(key('inspiration-card-char0'), findsOneWidget);
    expect(key('inspiration-card-char1'), findsNothing);
    await finish(tester);
  });

  testWidgets(
    'new and edit actions open one dismissible editor; selection still imports to creation',
    (tester) async {
      await mount(tester);
      final create = tester
          .widget<FilledButton>(key('inspiration-new'))
          .onPressed!;
      create();
      create();
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭编辑器'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsNothing);
      await tester.tap(
        find.descendant(
          of: key('inspiration-card-char0'),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      expect(find.widgetWithText(TextField, '白发少女'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-select-char0'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isTrue,
      );
      await tester.tap(find.text('主提示词'));
      // Selection clears after the usage record is saved. Wait for that
      // observable completion, rather than assuming disk I/O takes <150 ms.
      for (
        var i = 0;
        i < 100 && key('desktop-inspiration-selection').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).prompt, contains('white hair'));
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isFalse,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'desktop right-click actions retain the selected group and cancellation preserves data',
    (tester) async {
      await mount(tester);
      await tester.tap(key('inspiration-select-char0'));
      await tester.tap(key('inspiration-select-char1'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(key('desktop-inspiration-selection')).height,
        lessThan(80),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(key('inspiration-card-char0')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 项'), findsOneWidget);
      expect(
        find.widgetWithText(PopupMenuItem<String>, '加入角色'),
        findsOneWidget,
      );
      await captureDesktop(
        tester,
        capture,
        'windows17-inspiration-context-menu',
      );
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '取消选择'));
      await tester.pumpAndSettle();
      expect(key('desktop-inspiration-selection'), findsNothing);
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isFalse,
      );
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char1')).value,
        isFalse,
      );
      expect(
        container.read(tagLibraryProvider).value!.entries.length,
        entries.length,
      );

      await tester.tap(key('inspiration-select-char0'));
      await tester.tap(key('inspiration-select-char1'));
      await tester.pumpAndSettle();
      final unselected = await tester.startGesture(
        tester.getCenter(key('inspiration-card-char2')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await unselected.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        container.read(tagLibraryProvider).value!.entries.length,
        entries.length,
      );
      await tester.tap(key('inspiration-selection-menu'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(PopupMenuItem<String>, '主提示词'));
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).prompt, contains('purple hair'));
      expect(
        container.read(generateProvider).prompt,
        isNot(contains('white hair')),
      );
      for (
        var i = 0;
        i < 50 && key('desktop-inspiration-selection').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(key('desktop-inspiration-selection'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'public collection appears under My favorites and search survives scope changes',
    (tester) async {
      await mount(tester);
      await tester.tap(key('inspiration-scope-public'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-pub_cat'), findsOneWidget);
      await tester.enterText(key('tag-search-character'), '公共猫娘');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(
            of: key('inspiration-card-pub_cat'),
            matching: find.byTooltip('收藏'),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.byTooltip('已收藏'), findsOneWidget);
      await tester.tap(key('inspiration-scope-mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('tag-search-character')).controller!.text,
        '公共猫娘',
      );
      expect(find.text('公共猫娘'), findsWidgets);
      expect(
        container
            .read(tagLibraryProvider)
            .value!
            .entries
            .where((e) => e.publicId == 'cat')
            .length,
        1,
      );
      await finish(tester);
    },
  );
}
