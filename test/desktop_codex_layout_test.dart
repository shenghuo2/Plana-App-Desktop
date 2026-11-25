import 'dart:io';

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/remote_image.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/horizontal_scroll_strip.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/inspiration/codex/codex_history.dart';
import 'package:plana_app/features/inspiration/codex/codex_card.dart';
import 'package:plana_app/features/inspiration/codex/codex_sheets.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/codex/codex_favorites.dart';
import 'package:plana_app/features/inspiration/codex/codex_block.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_providers.dart';
import 'package:plana_app/features/inspiration/codex/codex_view.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

class _Acknowledged extends CodexIntro {
  @override
  bool? build() => true;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const meta = CodexMeta(
    id: 'styles',
    type: CodexType.string,
    title: '画风词典',
    author: '示例画师',
    aliases: ['Painter styles'],
    entryCount: 12,
  );
  const other = CodexMeta(
    id: 'scenes',
    type: CodexType.composition,
    title: '场景法典',
    author: '示例构图',
    entryCount: 1,
    nsfw: true,
  );
  const thumbnail = 'https://example.test/codex-thumbnail.png';
  const original = 'https://example.test/codex-original.png';
  final entries = [
    for (var i = 0; i < 12; i++)
      CodexEntry(
        id: 'style$i',
        isNew: i == 0 || i == 6,
        image: i == 0 ? thumbnail : null,
        original: i == 0 ? original : null,
        imageWidth: i == 0 ? 1024 : null,
        imageHeight: i == 0 ? 1536 : null,
        title: '${['水彩森林', '暮色海岸', '午后花园'][i % 3]} ${i + 1}',
        tags: [
          'watercolor, forest, light rays',
          'sunset, sea, warm light',
          'garden, flowers, afternoon',
        ][i % 3],
        path: i < 6 ? ['自然', if (i < 3) '森林' else '花园'] : ['光影'],
        characters: i == 0 || i == 7
            ? const [CodexCharacter('char1', 'test CHARACTER-only detail')]
            : const [],
      ),
  ];
  late List<CodexEntry> bookEntries;
  List<CodexNode>? bookTree;
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  late bool desktop;
  late List<CodexMeta> index;
  final capture = GlobalKey();
  Finder key(String value) => find.byKey(ValueKey(value));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_codex_desktop_');
    stores = AppStores.ephemeral();
    RemoteImageStore.bind(temp);
    final art = await File(
      'examples/inspiration-previews/moonlit-waterfall.png',
    ).readAsBytes();
    for (final url in [thumbnail, original]) {
      await RemoteImageStore.write(url, art);
      RemoteImageStore.markChecked(url);
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    desktop = true;
    index = [meta, other];
    bookEntries = entries;
    bookTree = null;
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWith((ref) => desktop),
        codexIntroProvider.overrideWith(_Acknowledged.new),
        codexIndexProvider.overrideWith((ref) async => index),
        codexMediaProvider.overrideWith((ref) async => CodexMedia.fallback),
        codexDataProvider.overrideWith(
          (ref, id) async => id == meta.id
              ? CodexData(
                  meta: meta,
                  entries: bookEntries,
                  tree:
                      bookTree ??
                      const [
                        CodexNode('自然', 6, [
                          CodexNode('森林', 3, []),
                          CodexNode('花园', 3, []),
                        ]),
                        CodexNode('光影', 6, []),
                      ],
                )
              : const CodexData(
                  meta: other,
                  entries: [
                    CodexEntry(id: 'scene0', title: '夜空', tags: 'night sky'),
                  ],
                ),
        ),
        codexTagZhProvider.overrideWith((ref, id) async => null),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    // Windows may still hold a thumbnail read handle for a frame after unmount.
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on PathAccessException catch (error) {
        if (error.osError?.errorCode != 32 || attempt >= 6) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  });

  Future<void> finish(WidgetTester tester) async {
    // Let local thumbnail reads complete within the test's fake-async zone
    // before removing its Windows cache directory.
    await pumpUntil(
      tester,
      () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1500, 900),
    double textScale = 1,
    TargetPlatform platform = TargetPlatform.windows,
    Widget? home,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await container.read(codexFavoritesProvider.future);
      await container.read(codexHistoryProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              platform: platform,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home:
                home ??
                Scaffold(
                  body: CodexView(
                    desktop: true,
                    desktopHeaderBuilder: (search) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '灵感 · 法典',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Flexible(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 348),
                              child: search,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const CodexMainDrawButton(),
                        ],
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

  testWidgets('法典三个视图平铺为连续方格，点击边角也能切换', (tester) async {
    await mount(tester);
    Rect? previous;
    for (final mode in ['gallery', 'grouped', 'list']) {
      final finder = key('codex-view-$mode');
      final rect = tester.getRect(finder);
      expect(rect.size, const Size.square(40));
      if (previous != null) expect(rect.topLeft, previous.topRight);
      await tester.tapAt(rect.topLeft + const Offset(2, 2));
      await tester.pumpAndSettle();
      final button = tester.widget<IconButton>(finder);
      expect(button.isSelected, isTrue);
      final shape = button.style!.shape!.resolve({WidgetState.selected});
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.zero,
      );
      previous = rect;
    }
    await captureDesktop(tester, capture, 'codex-square-view-switch');
    await finish(tester);
  });

  testWidgets(
    'desktop codex supports nested filters, search, resizing and book switching',
    (tester) async {
      await mount(tester);
      final rail = key('desktop-codex-categories');
      expect(key('desktop-codex-random'), findsNothing);
      expect(key('codex-main-draw-toggle').hitTestable(), findsOneWidget);
      final tree = find.descendant(of: rail, matching: find.byType(ListView));
      final favorites = key('desktop-codex-favorites');
      final updates = key('desktop-codex-recent');
      expect(
        tester.getTopLeft(favorites).dy - tester.getBottomLeft(tree).dy,
        inInclusiveRange(0, 9),
      );
      expect(
        tester.getBottomLeft(rail).dy - tester.getBottomLeft(updates).dy,
        inInclusiveRange(0, 9),
      );
      final first = tester.getRect(key('desktop-codex-card-style0'));
      expect(first.width, lessThan(300));
      expect(first.height, greaterThan(first.width));
      expect(tester.getTopLeft(key('desktop-codex-card-style4')).dy, first.top);
      await captureDesktop(tester, capture, 'windows17-codex-wide');
      await tester.tap(key('codex-category-自然'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '6 条');
      expect(key('codex-child-森林'), findsOneWidget);
      await tester.tap(key('codex-category-自然/森林'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '3 条');
      await tester.enterText(key('desktop-codex-search'), 'sea');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(key('desktop-codex-card-style1'), findsOneWidget);
      expect(key('desktop-codex-card-style0'), findsNothing);
      tester.view.physicalSize = const Size(740, 700);
      await tester.pumpAndSettle();
      expect(key('desktop-codex-categories'), findsNothing);
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        'sea',
      );
      expect(tester.takeException(), isNull);
      await captureDesktop(tester, capture, 'windows17-codex-compact');
      await tester.tap(find.byType(CodexPickerButton));
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsOneWidget);
      expect(key('codex-desktop-dialog'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getRect(key('desktop-popover')).top,
        closeTo(tester.getRect(key('codex-picker-button')).bottom + 8, 1),
      );
      expect(find.text('示例画师 · 12 条'), findsOneWidget);
      expect(find.text('示例构图 · 1 条'), findsOneWidget);
      expect(find.text('R18'), findsOneWidget);
      expect(find.text('词典'), findsOneWidget);
      expect(find.text('构图'), findsOneWidget);
      await tester.enterText(key('codex-picker-search'), '示例构图');
      await tester.pumpAndSettle();
      expect(find.text('示例画师 · 12 条'), findsNothing);
      await tester.tap(find.text('场景法典'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-card-scene0'), findsOneWidget);
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        isEmpty,
      );
      await tester.tap(key('codex-picker-button'));
      await tester.pumpAndSettle();
      await tester.enterText(key('codex-picker-search'), 'PAINTER');
      await tester.pumpAndSettle();
      expect(find.text('示例构图 · 1 条'), findsNothing);
      await tester.tap(find.text('画风词典'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
        'sea',
      );
      expect(key('desktop-codex-card-style1'), findsOneWidget);
      expect(key('desktop-codex-card-style7'), findsNothing);
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'blocked categories stay out of desktop search, random and detail paging',
    (tester) async {
      await mount(tester);
      await tester.tap(key('codex-category-自然'));
      await tester.pumpAndSettle();
      container.read(codexBlocksProvider.notifier).toggle(meta.id, ['自然']);
      await tester.pumpAndSettle();
      expect(find.text('全部词条 · 6 条'), findsOneWidget);
      expect(key('desktop-codex-card-style0'), findsNothing);
      expect(
        tester.widget<ListTile>(key('codex-category-自然')).enabled,
        isFalse,
      );
      await tester.enterText(key('desktop-codex-search'), 'character-ONLY');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(key('desktop-codex-card-style7'), findsOneWidget);
      expect(key('desktop-codex-card-style0'), findsNothing);
      await tester.enterText(key('desktop-codex-search'), '');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.tap(key('desktop-codex-card-style6'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 6'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('codex-main-draw-toggle'));
      await tester.pumpAndSettle();
      for (final entry in entries.take(6)) {
        expect(
          find.descendant(
            of: key('desktop-codex-grid'),
            matching: find.text(entry.title),
          ),
          findsNothing,
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('codex-category-picker'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解除屏蔽'), findsOneWidget);
      await tester.tap(find.byTooltip('解除屏蔽'));
      await tester.pumpAndSettle();
      expect(container.read(codexBlockProvider(meta.id)).active, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('desktop-codex-card-style0'), findsOneWidget);
      await finish(tester);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'catalog child buttons follow the path and recent entries combine with favorites',
    (tester) async {
      await mount(tester);
      expect(
        tester.getRect(key('codex-picker-button')).right,
        lessThan(tester.getRect(key('codex-results-count')).left),
      );
      expect(
        tester.getRect(key('desktop-codex-favorites')).top,
        greaterThan(tester.getRect(key('codex-category-光影')).bottom),
      );
      await tester.tap(key('codex-child-自然'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '6 条');
      expect(key('codex-child-花园'), findsOneWidget);
      await tester.tap(key('codex-child-森林'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '3 条');
      await tester.tap(find.widgetWithText(TextButton, '全部分类'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-codex-recent'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '2 条');
      expect(key('desktop-codex-card-style0'), findsOneWidget);
      expect(key('desktop-codex-card-style6'), findsOneWidget);
      expect(key('desktop-codex-card-style1'), findsNothing);
      await tester.runAsync(
        () => container
            .read(codexFavoritesProvider.notifier)
            .toggle(meta.id, entries[6], now: 1),
      );
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '1 条');
      expect(key('desktop-codex-card-style6'), findsOneWidget);
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('codex-results-count')).data, '12 条');
      await tester.tap(key('codex-view-grouped'));
      await tester.pumpAndSettle();
      expect(key('codex-grouped-gallery'), findsOneWidget);
      await tester.tap(key('desktop-codex-card-style1'));
      await tester.pumpAndSettle();
      expect(key('codex-desktop-dialog'), findsOneWidget);
      expect(key('codex-list-inspector'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final regular = tester.getSize(key('desktop-codex-card-style0'));
      await tester.tap(key('codex-density'));
      await tester.pumpAndSettle();
      final large = tester.getSize(key('desktop-codex-card-style0'));
      expect(large.width, greaterThanOrEqualTo(regular.width));
      expect(large.height, greaterThan(regular.height));
      await finish(tester);
    },
  );

  testWidgets(
    'mouse can drag the subcategory scrollbar without moving the results',
    (tester) async {
      bookTree = [];
      bookEntries = [
        for (var i = 0; i < 36; i++)
          CodexEntry(
            id: 'chip$i',
            title: '词条 $i',
            tags: 'tag $i',
            path: ['分类按钮 $i', '下一层'],
          ),
      ];
      await mount(tester);
      final strip = find.byType(HorizontalScrollStrip);
      final rect = tester.getRect(strip);
      final controller = tester.widget<HorizontalScrollStrip>(strip).controller;
      final scrollbar = tester.widget<Scrollbar>(
        find.descendant(of: strip, matching: find.byType(Scrollbar)),
      );
      expect(scrollbar.thickness, 8);
      final results = tester
          .widget<GridView>(key('desktop-codex-grid'))
          .controller!;
      final before = results.offset;
      final gesture = await tester.startGesture(
        Offset(rect.left + 10, rect.bottom - 14),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(Offset(rect.width - 12, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(results.offset, before);
      final last = key('codex-child-分类按钮 35');
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(key('codex-child-下一层').hitTestable(), findsOneWidget);
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'gallery and grouped cards show the whole source at its own aspect',
    (tester) async {
      const cases = [
        ('coastal-station', 1.5),
        ('greenhouse', 1.0),
        ('moonlit-waterfall', 2 / 3),
      ];
      bookTree = [];
      bookEntries = [
        for (final (name, _) in cases)
          CodexEntry(
            id: name,
            title: name,
            tags: name,
            path: const ['分组'],
            image: 'https://example.test/$name.png',
          ),
      ];
      await tester.runAsync(() async {
        for (final item in bookEntries) {
          final bytes = await File(
            'examples/inspiration-previews/${item.id}.png',
          ).readAsBytes();
          await RemoteImageStore.write(item.image!, bytes);
          RemoteImageStore.markChecked(item.image!);
        }
      });
      await mount(tester);
      for (final mode in ['gallery', 'grouped']) {
        if (mode == 'grouped') {
          await tester.tap(key('codex-view-grouped'));
          await tester.pumpAndSettle();
        }
        for (final (id, aspect) in cases) {
          final card = key('desktop-codex-card-$id');
          final raw = find.descendant(
            of: card,
            matching: find.byType(RawImage),
          );
          await pumpUntil(
            tester,
            () => tester.widgetList<RawImage>(raw).any((w) => w.image != null),
          );
          final render = tester.widget<RawImage>(raw);
          final bitmap = render.image!;
          final bitmapSize = Size(
            bitmap.width.toDouble(),
            bitmap.height.toDouble(),
          );
          final preview = tester.getSize(raw);
          expect(preview.height, greaterThan(preview.width));
          expect(preview.aspectRatio, closeTo(.8, .025));
          expect(render.alignment, Alignment.center);
          expect(render.fit, BoxFit.contain);
          expect(bitmapSize.aspectRatio, closeTo(aspect, .015));
          expect(
            applyBoxFit(render.fit!, bitmapSize, preview).source,
            bitmapSize,
          );
        }
        await captureDesktop(tester, capture, 'codex-original-aspects-$mode');
      }
      await finish(tester);
    },
  );

  testWidgets(
    'style outline jumps to headers and follows scrolling through layout changes',
    (tester) async {
      final groups = [
        ['自然', '同名'],
        for (var g = 1; g <= 12; g++) ['画风 $g'],
        ['光影', '同名'],
      ];
      bookEntries = [
        for (var g = 0; g < groups.length; g++)
          for (var i = 0; i < (g == groups.length - 1 ? 1 : 9); i++)
            CodexEntry(
              id: 'nav-$g-$i',
              title: '卡片 $g-$i',
              tags: 'style',
              path: groups[g],
            ),
      ];
      bookTree = [];
      await mount(tester);
      final rail = key('codex-group-tick-navigation');
      expect(rail, findsNothing);
      await tester.tap(key('codex-view-grouped'));
      await tester.pumpAndSettle();
      final grid = key('codex-grouped-gallery');
      ScrollController getScroll() =>
          tester.widget<ScrollView>(grid).controller!;
      final scroll = getScroll();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(rail).center.dy,
        closeTo(tester.getRect(grid).center.dy, 1),
      );
      expect(
        tester.getRect(rail).right,
        closeTo(tester.getRect(grid).right - 24, 1),
      );
      expect(tester.getSize(rail).width, 40);
      String current() => tester
          .widgetList<Semantics>(
            find.ancestor(of: rail, matching: find.byType(Semantics)),
          )
          .firstWhere((s) => s.properties.label == '画风分组定位')
          .properties
          .value!;
      void atHeader(int i) {
        final heading = key('codex-group-heading-${groups[i].join('\u0000')}');
        expect(
          tester.getTopLeft(heading).dy,
          closeTo(tester.getTopLeft(grid).dy, 1),
        );
        expect(current(), startsWith('${i + 1} / ${groups.length}'));
      }

      atHeader(0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      final point = tester.getCenter(key('codex-group-tick-画风 7'));
      await mouse.moveTo(point);
      await tester.pumpAndSettle();
      expect(find.text('8 · 画风 7'), findsOneWidget);
      expect(tester.getSize(rail).width, 40);
      final outside = Offset(tester.getRect(rail).left - 1, point.dy);
      await mouse.moveTo(outside);
      await tester.pumpAndSettle();
      expect(find.text('8 · 画风 7'), findsNothing);
      await mouse.moveTo(point);
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'codex-style-group-navigation');
      await mouse.down(point);
      await mouse.up();
      await tester.pumpAndSettle();
      atHeader(7);
      final adjacent = point + const Offset(0, 12);
      await mouse.down(point);
      await mouse.moveTo(adjacent);
      await mouse.up();
      await tester.pumpAndSettle();
      atHeader(8);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: adjacent,
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      atHeader(9);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      atHeader(groups.length - 1);
      expect(current(), contains('同名 · 光影'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      atHeader(groups.length - 2);
      await mouse.moveTo(Offset.zero);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      atHeader(0);
      expect(current(), contains('同名 · 自然'));
      tester.view.physicalSize = const Size(940, 720);
      await tester.pumpAndSettle();
      await tester.tap(key('codex-density'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(key('codex-group-tick-画风 2')));
      await tester.pumpAndSettle();
      atHeader(2);
      await mouse.removePointer();
      await tester.tap(key('codex-view-list'));
      await tester.pumpAndSettle();
      expect(rail, findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'fast grouped jumps build only viewport cards in a 15724-entry book',
    (tester) async {
      bookTree = [];
      bookEntries = [
        for (var i = 0; i < 15724; i++)
          CodexEntry(
            id: 'grouped$i',
            title: '词条 $i',
            tags: 'entry $i',
            path: ['单画师词典', '画风 ${i ~/ 123}'],
          ),
      ];
      await mount(tester);
      await tester.tap(key('codex-view-grouped'));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<ScrollView>(key('codex-grouped-gallery'))
          .controller!;
      final end = scroll.position.maxScrollExtent;
      final previous = debugOnRebuildDirtyWidget;
      var built = 0;
      debugOnRebuildDirtyWidget = (element, wasBuilt) {
        previous?.call(element, wasBuilt);
        if (element.widget is CodexCard) built++;
      };
      try {
        for (final fraction in [.91, .04, .76, .21, .99, .50, 1.0]) {
          built = 0;
          scroll.jumpTo(end * fraction);
          await tester.pump();
          expect(built, inInclusiveRange(1, 70));
          expect(scroll.position.maxScrollExtent, closeTo(end, 1));
          expect(find.byKey(const ValueKey('codex-hover-复制提示词')), findsNothing);
        }
        expect(key('desktop-codex-card-grouped15723'), findsOneWidget);
        final lastGroup = '单画师词典\u0000画风 127';
        await tester.tapAt(
          tester.getCenter(key('codex-group-tick-$lastGroup')),
        );
        await tester.pumpAndSettle();
        expect(
          key('codex-group-heading-$lastGroup').hitTestable(),
          findsOneWidget,
        );
        built = 0;
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(built, inInclusiveRange(1, 70));
        expect(scroll.offset, 0);
        expect(
          key('desktop-codex-card-grouped0').hitTestable(),
          findsOneWidget,
        );
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'list inspector retains the list position through selection, paging, filtering and full details',
    (tester) async {
      bookEntries = [
        ...entries,
        for (var i = 0; i < 15000; i++)
          CodexEntry(
            id: 'long$i',
            title: '词条 $i',
            tags: 'entry $i',
            path: const ['光影'],
          ),
      ];
      await mount(tester);
      await tester.tap(key('codex-view-list'));
      await tester.pumpAndSettle();
      ScrollController list() =>
          tester.widget<ListView>(key('codex-compact-list')).controller!;
      list().jumpTo(66 * 68);
      await tester.pumpAndSettle();
      final before = list().offset;
      expect(before, greaterThan(4000));
      await tester.tap(key('codex-row-long58'));
      await tester.pumpAndSettle();
      Finder inPane(Finder what) =>
          find.descendant(of: key('codex-list-inspector'), matching: what);
      expect(inPane(find.text('词条 58')), findsOneWidget);
      expect(key('codex-desktop-dialog'), findsNothing);
      expect(list().offset, before);
      await tester.tap(inPane(find.byTooltip('下一条')));
      await tester.pumpAndSettle();
      expect(inPane(find.text('词条 59')), findsOneWidget);
      expect(list().offset, before);
      await tester.tap(inPane(find.byTooltip('展开详情')));
      await tester.pumpAndSettle();
      expect(key('codex-desktop-dialog'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(inPane(find.text('词条 59')), findsOneWidget);
      await tester.tap(inPane(find.byIcon(Icons.close)));
      await tester.pumpAndSettle();
      expect(key('codex-list-inspector'), findsNothing);
      expect(list().offset, before);
      final rowStar = find.descendant(
        of: key('codex-row-long58'),
        matching: find.byTooltip('收藏'),
      );
      await tester.tap(rowStar);
      await tester.pumpAndSettle();
      expect(container.read(codexFavKeysProvider), contains('styles/long58'));
      expect(list().offset, before);
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      expect(list().offset, 0);
      expect(key('codex-row-long58'), findsOneWidget);
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      expect(list().offset, before);
      await tester.tap(key('codex-row-long58'));
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'codex-catalog-list-inspector');
      await tester.tap(key('codex-view-gallery'));
      await tester.pumpAndSettle();
      expect(key('codex-list-inspector'), findsNothing);
      await tester.tap(key('desktop-codex-card-style0'));
      await tester.pumpAndSettle();
      expect(key('codex-desktop-dialog'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('character prompt search still respects the chosen category', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(key('desktop-codex-search'), 'character-ONLY');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(key('desktop-codex-card-style0'), findsOneWidget);
    expect(key('desktop-codex-card-style7'), findsOneWidget);
    expect(key('desktop-codex-card-style1'), findsNothing);
    await tester.tap(key('codex-category-自然'));
    await tester.pumpAndSettle();
    expect(key('desktop-codex-card-style0'), findsOneWidget);
    expect(key('desktop-codex-card-style7'), findsNothing);
    await finish(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing the dropdown preserves selection and entry search', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(key('desktop-codex-search'), 'sea');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(key('codex-picker-button'));
    await tester.pumpAndSettle();
    await tester.enterText(key('codex-picker-search'), '不存在的法典');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的法典'), findsOneWidget);
    await tester.tap(find.byTooltip('清空法典搜索'));
    await tester.pumpAndSettle();
    expect(find.text('示例画师 · 12 条'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(key('desktop-popover'), findsNothing);
    expect(container.read(selectedCodexProvider), isNull);
    await tester.tap(key('codex-picker-button'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(key('desktop-popover'), findsNothing);
    expect(container.read(selectedCodexProvider), isNull);
    expect(
      tester.widget<TextField>(key('desktop-codex-search')).controller!.text,
      'sea',
    );
    expect(key('desktop-codex-card-style1'), findsOneWidget);
    await finish(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'embedded macOS picker uses window bounds with large text and a scrollable list',
    (tester) async {
      index = [
        const CodexMeta(
          id: 'styles',
          type: CodexType.string,
          title: 'NovelAI v4.5 画师词典与更多内容，长标题仍应截断',
          nsfw: true,
        ),
        other,
        for (var i = 0; i < 25; i++)
          CodexMeta(
            id: 'extra$i',
            type: CodexType.codex,
            title: '更多法典 $i',
            entryCount: i,
          ),
      ];
      container.read(selectedCodexProvider.notifier).select('styles');
      await mount(
        tester,
        size: const Size(740, 700),
        textScale: 1.4,
        platform: TargetPlatform.macOS,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 360,
              child: MediaQuery(
                data: MediaQueryData(
                  size: Size(360, 700),
                  textScaler: TextScaler.linear(1.4),
                ),
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CodexPickerButton(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final anchor = tester.getRect(key('codex-picker-button'));
      expect(anchor.width, lessThanOrEqualTo(320));
      await tester.tap(key('codex-picker-button'));
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 380);
      expect(panel.top, closeTo(anchor.bottom + 8, 1));
      expect(panel.right, closeTo(anchor.right, 1));
      expect(panel.bottom, lessThanOrEqualTo(688));
      expect(find.byType(BottomSheet), findsNothing);
      final menuScrollable = find
          .descendant(
            of: key('desktop-popover'),
            matching: find.byType(Scrollable),
          )
          .last;
      await tester.scrollUntilVisible(
        find.text('更多法典 24'),
        200,
        scrollable: menuScrollable,
      );
      await tester.tap(find.text('更多法典 24'));
      await tester.pumpAndSettle();
      expect(container.read(selectedCodexProvider), 'extra24');
      expect(key('desktop-popover'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('hover preview delay, crossing, dismissal and preference', (
    tester,
  ) async {
    await mount(tester);
    final card = key('desktop-codex-card-style0');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 5));
    await mouse.moveTo(tester.getCenter(card));
    final originalImage = find.byWidgetPredicate(
      (w) => w is RemoteImage && w.url == original,
    );
    await tester.pump(const Duration(milliseconds: 399));
    expect(key('codex-hover-preview'), findsNothing);
    expect(originalImage, findsNothing);
    for (final label in ['导入图片', '复制提示词', '创建分区并导入', '导入主提示词']) {
      expect(
        find
            .descendant(of: card, matching: key('codex-hover-$label'))
            .hitTestable(),
        findsOneWidget,
      );
    }
    expect(find.text('查看提示词'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(originalImage, findsOneWidget);
    await pumpUntil(
      tester,
      () => find
          .descendant(of: originalImage, matching: key('codex-hover-preview'))
          .evaluate()
          .isNotEmpty,
    );
    final preview = tester.getRect(key('codex-hover-preview'));
    final cardBounds = tester.getRect(card);
    expect(preview.width, greaterThan(cardBounds.width));
    final grid = tester.getRect(key('desktop-codex-grid'));
    expect(grid.intersect(preview), preview);
    final copy = find.descendant(of: card, matching: key('codex-hover-复制提示词'));
    expect(preview.overlaps(tester.getRect(copy)), isFalse);
    await captureDesktop(tester, capture, 'codex-hover-preview');
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: cardBounds.center,
        scrollDelta: const Offset(0, 48),
      ),
    );
    await tester.pumpAndSettle();
    expect(key('codex-hover-preview'), findsNothing);
    expect(key('desktop-codex-detail'), findsNothing);
    expect(tester.getRect(card).top, lessThan(cardBounds.top));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: cardBounds.center,
        scrollDelta: const Offset(0, -48),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(card).top, closeTo(cardBounds.top, .01));
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 200));
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 400));
    await pumpUntil(
      tester,
      () => key('codex-hover-preview').evaluate().isNotEmpty,
    );
    await mouse.down(tester.getCenter(card));
    await tester.pump();
    expect(key('codex-hover-preview'), findsNothing);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(key('desktop-codex-detail'), findsOneWidget);
    Navigator.of(tester.element(key('desktop-codex-detail'))).pop();
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 400));
    await pumpUntil(
      tester,
      () => key('codex-hover-preview').evaluate().isNotEmpty,
    );
    container
        .read(themeSettingsProvider.notifier)
        .patch((s) => s.copyWith(codexHoverPreview: false));
    await tester.pump();
    expect(key('codex-hover-preview'), findsNothing);
    expect(
      find
          .descendant(of: card, matching: key('codex-hover-复制提示词'))
          .hitTestable(),
      findsOneWidget,
    );
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 200));
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(seconds: 2));
    expect(key('codex-hover-preview'), findsNothing);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(key('desktop-codex-detail'), findsOneWidget);
    expect(find.text('导入主提示词').hitTestable(), findsOneWidget);
    expect(find.text('创建分区并导入').hitTestable(), findsOneWidget);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets(
    'hover main import appends weighted tags despite existing sections',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.setModel('NAI 4.5 Full');
      gen.setPrompts(positive: 'existing words', negative: 'keep negative');
      gen.addEntrySections([
        const TagEntry(
          id: 'old',
          category: TagCategory.other,
          name: '已有分区',
          positive: 'keep section',
        ),
      ]);
      final original = gen.state;
      const entry = CodexEntry(
        id: 'weighted',
        title: '加权词条',
        tags: '1.4::forest::, light',
        characters: [CodexCharacter('char1', 'blue eyes')],
      );
      await mount(
        tester,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 330,
              child: CodexCard(
                codex: meta,
                entry: entry,
                media: CodexMedia.fallback,
                desktop: true,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      await mouse.moveTo(tester.getCenter(find.byType(CodexCard)));
      await tester.pump(const Duration(milliseconds: 110));
      await tester.tap(key('codex-hover-导入主提示词'));
      await tester.pumpAndSettle();
      expect(gen.state.prompt, startsWith('existing words'));
      expect(gen.state.prompt, contains('1.4::forest::'));
      expect(gen.state.prompt, contains('blue eyes'));
      expect(parseFolds(gen.state.promptRaw).single.name, '加权词条');
      expect(gen.state.sections, original.sections);
      expect(gen.state.characters, original.characters);
      expect(gen.state.negativePrompt, 'keep negative');
      await mouse.removePointer();
      await finish(tester);
    },
  );

  testWidgets(
    'missing original falls back to the cover and quick actions still receive clicks',
    (tester) async {
      const unavailable = 'https://example.test/unavailable-original.png';
      const entry = CodexEntry(
        id: 'unavailable',
        title: '画风',
        tags: 'forest',
        image: thumbnail,
        original: unavailable,
      );
      var favorites = 0;
      await mount(
        tester,
        size: const Size(360, 480),
        home: Scaffold(
          body: ListView(
            children: [
              SizedBox(
                height: 325,
                child: CodexCard(
                  codex: meta,
                  entry: entry,
                  media: CodexMedia.fallback,
                  desktop: true,
                  embedded: true,
                  onTap: () {},
                  onFavorite: () => favorites++,
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final art = find.byWidgetPredicate(
        (w) => w is RemoteImage && w.url == thumbnail,
      );
      await mouse.addPointer(location: tester.getCenter(art));
      await tester.pump(const Duration(milliseconds: 400));
      final overlay = key('codex-hover-preview');
      final originalWidget = find.byWidgetPredicate(
        (w) => w is RemoteImage && w.url == unavailable,
      );
      await pumpUntil(
        tester,
        () => find
            .descendant(
              of: originalWidget,
              matching: find.descendant(of: art, matching: overlay),
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byTooltip('收藏').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('收藏'));
      await tester.pumpAndSettle();
      expect(favorites, 1);
      expect(overlay, findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await finish(tester);
    },
  );

  testWidgets('text-only entries keep quick actions without an image overlay', (
    tester,
  ) async {
    final long = CodexEntry(
      id: 'long',
      title: '较长的加权提示词',
      tags: List.filled(500, '1.4::forest::, sunlight').join(', '),
    );
    await mount(
      tester,
      size: const Size(420, 760),
      textScale: 1.4,
      home: Theme(
        data: AppTheme.dark().copyWith(
          textTheme: AppTheme.dark().textTheme.apply(
            fontFamily: 'Microsoft YaHei',
          ),
        ),
        child: Scaffold(
          body: ListView(
            children: [
              SizedBox(
                height: 330,
                child: CodexCard(
                  codex: meta,
                  entry: long,
                  media: CodexMedia.fallback,
                  desktop: true,
                  onTap: () {},
                ),
              ),
              const SizedBox(height: 1600),
            ],
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(410, 750));
    await mouse.moveTo(tester.getCenter(find.byType(CodexCard)));
    await tester.pump(const Duration(seconds: 2));
    expect(key('codex-hover-preview'), findsNothing);
    expect(key('codex-hover-复制提示词').hitTestable(), findsOneWidget);
    await tester.dragFrom(const Offset(410, 700), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(key('codex-hover-preview'), findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await finish(tester);
  });

  testWidgets('mobile picker retains the bottom sheet and book selection', (
    tester,
  ) async {
    desktop = false;
    await mount(
      tester,
      size: const Size(400, 800),
      platform: TargetPlatform.android,
      home: const Scaffold(body: Center(child: CodexPickerButton())),
    );
    await tester.tap(key('codex-picker-button'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(key('desktop-popover'), findsNothing);
    expect(find.text('示例构图 · 1 条'), findsOneWidget);
    await tester.tap(find.text('场景法典'));
    await tester.pumpAndSettle();
    expect(container.read(selectedCodexProvider), 'scenes');
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets(
    'desktop favorites and random details keep all actions accessible',
    (tester) async {
      await mount(tester);
      final favoriteButton = find.descendant(
        of: key('desktop-codex-card-style0'),
        matching: find.byTooltip('收藏'),
      );
      await tester.ensureVisible(favoriteButton);
      await tester.pumpAndSettle();
      expect(favoriteButton.hitTestable(), findsOneWidget);
      final onFavorite =
          tester
                  .widget<IconButton>(
                    find.ancestor(
                      of: favoriteButton,
                      matching: find.byType(IconButton),
                    ),
                  )
                  .onPressed!
              as Future<void> Function();
      await tester.runAsync(() async {
        // Await persistence before the temporary directory can be removed.
        await onFavorite();
      });
      await tester.pumpAndSettle();
      expect(container.read(codexFavKeysProvider), contains('styles/style0'));
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      expect(find.text(entries.first.title), findsWidgets);
      expect(find.byType(Dialog), findsNothing);
      expect(key('desktop-codex-card-style1'), findsNothing);
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-codex-card-style0'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-detail'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await captureDesktop(tester, capture, 'windows17-codex-detail');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一条'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 12'), findsOneWidget);
      // Clicking a control must not steal the dialog's arrow shortcuts.
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      expect(find.text('12 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('11 / 12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('codex-main-draw-toggle'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-random-workspace'), findsOneWidget);
      expect(key('desktop-codex-detail'), findsNothing);
      expect(find.text('12 候选'), findsOneWidget);
      // The original random detail sheet also records only newly viewed draws.
      final ctx = tester.element(key('desktop-codex-browser'));
      final closed = showCodexRandomSheet(
        ctx,
        meta,
        CodexMedia.fallback,
        entries,
      );
      await tester.pumpAndSettle();
      await pumpUntilComplete(
        tester,
        container.read(codexHistoryProvider.notifier).flush(),
      );
      final before = container.read(codexHistoryProvider).value!.length;
      expect(before, 1); // No prefetched draw.
      final randomTitle = find.descendant(
        of: key('desktop-codex-detail'),
        matching: find.byWidgetPredicate(
          (w) => w is Text && entries.any((e) => e.title == w.data),
        ),
      );
      final firstDraw = tester.widget<Text>(randomTitle).data;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(randomTitle).data, isNot(firstDraw));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(randomTitle).data, firstDraw);
      await pumpUntilComplete(
        tester,
        container.read(codexHistoryProvider.notifier).flush(),
      );
      // One forward draw, no new record for navigating back.
      expect(container.read(codexHistoryProvider).value, hasLength(before + 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await closed;
      await tester.tap(key('codex-random-history'));
      await tester.pumpAndSettle();
      expect(key('codex-draw-history-list'), findsOneWidget);
      await finish(tester);
    },
  );

  for (final embedded in [false, true]) {
    testWidgets(
      'recent draw arrows, keys and scrollbar follow thumbnail order: embedded=$embedded',
      (tester) async {
        await mount(
          tester,
          home: embedded
              ? const Scaffold(
                  body: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 360,
                      child: CodexView(desktop: true, embedded: true),
                    ),
                  ),
                )
              : null,
        );
        final history = container.read(codexHistoryProvider.notifier);
        final session = container.read(codexDrawSessionProvider);
        await tester.runAsync(
          () => history.saveDraws([
            for (var i = 0; i < 26; i++)
              session.create(
                meta,
                CodexEntry(id: 'recent$i', title: '抽样 $i', tags: 'draw'),
              ),
          ]),
        );
        await tester.tap(
          key(embedded ? 'desktop-codex-random' : 'codex-main-draw-toggle'),
        );
        await tester.pumpAndSettle();
        final records = container.read(codexHistoryProvider).requireValue;
        final previous = key('codex-draw-previous');
        final next = key('codex-draw-next');
        final strip = key('codex-recent-draws');
        final controller = tester.widget<ListView>(strip).controller!;
        Future<void> arrow(Finder button) async {
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
        }

        Future<void> keyboard(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
        }

        void expectCard(int index) {
          expect(
            tester.widget<Text>(key('codex-draw-title')).data,
            records[index].entry.title,
          );
          expect(
            tester.widget<IconButton>(previous).onPressed != null,
            index > 0,
          );
          expect(
            tester.widget<IconButton>(next).onPressed != null,
            index < records.length - 1,
          );
        }

        expectCard(0);
        await keyboard(LogicalKeyboardKey.arrowLeft);
        expectCard(0);
        await arrow(next);
        expectCard(1);
        await keyboard(LogicalKeyboardKey.arrowRight);
        expectCard(2);
        await arrow(previous);
        expectCard(1);
        await keyboard(LogicalKeyboardKey.arrowLeft);
        expectCard(0);

        final reset = key('codex-draw-reshuffle');
        final start = tester.getCenter(reset);
        await tester.ensureVisible(strip);
        await tester.pumpAndSettle();
        expect(tester.getCenter(reset).dy, closeTo(start.dy, 1));
        final oldest = key('codex-recent-${records.last.id}');
        expect(oldest, findsNothing);
        final rect = tester.getRect(strip);
        // Grab in the gutter just above the visible thumb.
        final gesture = await tester.startGesture(
          Offset(rect.left + 8, rect.bottom - 14),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await gesture.moveBy(Offset(rect.width - 10, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(oldest.hitTestable(), findsOneWidget);
        await tester.tap(oldest);
        await tester.pumpAndSettle();
        expectCard(25);
        await keyboard(LogicalKeyboardKey.arrowRight);
        expectCard(25);
        for (var i = records.length - 2; i >= 0; i--) {
          await keyboard(LogicalKeyboardKey.arrowLeft);
          expectCard(i);
        }
        expect(controller.offset, 0);
        expect(
          container.read(codexHistoryProvider).requireValue,
          hasLength(26),
        );
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'wide single and trio share the deck while contextual draws leave the rail untouched',
    (tester) async {
      const covers = ['moonlit-waterfall', 'coastal-station', 'greenhouse'];
      await tester.runAsync(() async {
        for (final name in covers) {
          final url = 'https://example.test/$name.png';
          await RemoteImageStore.write(
            url,
            await File('examples/inspiration-previews/$name.png').readAsBytes(),
          );
          RemoteImageStore.markChecked(url);
        }
      });
      bookEntries = [
        for (var i = 0; i < entries.length; i++)
          CodexEntry(
            id: entries[i].id,
            title: entries[i].title,
            tags: entries[i].tags,
            path: entries[i].path,
            image: 'https://example.test/${covers[i % 3]}.png',
            characters: entries[i].characters,
          ),
      ];
      await mount(tester, size: const Size(1500, 860));
      final history = container.read(codexHistoryProvider.notifier);
      List<CodexDrawRecord> saved() =>
          container.read(codexHistoryProvider).requireValue;
      Future<void> tapAndSave(Finder target) async {
        await tester.tap(target);
        await pumpUntilComplete(tester, history.flush());
        await tester.pumpAndSettle();
      }

      await tester.runAsync(() => history.record(meta, bookEntries.first));
      await tester.tap(key('codex-category-自然'));
      await tester.pumpAndSettle();
      await tester.tap(key('codex-main-draw-toggle'));
      await tester.pumpAndSettle();

      final reset = key('codex-draw-reshuffle');
      final resetPosition = tester.getCenter(reset);
      expect(tester.widget<TextButton>(reset).onPressed, isNull);
      final fromForest = <String>{};
      for (var i = 0; i < 3; i++) {
        await tapAndSave(key('codex-draw-in-category'));
        expect(saved().first.entry.path, ['自然', '森林']);
        expect(fromForest.add(saved().first.entry.id), isTrue);
        expect(
          tester.widget<ListTile>(key('codex-category-自然')).selected,
          isTrue,
        );
        expect(find.text('6 候选'), findsOneWidget);
        expect(tester.getCenter(reset), resetPosition);
      }
      await tester.tap(key('codex-draw-image'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-detail'), findsOneWidget);
      expect(
        find.descendant(
          of: key('desktop-codex-detail'),
          matching: find.text(saved().first.entry.title),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(saved(), hasLength(4));
      await tapAndSave(key('codex-random-draw'));
      expect(saved().first.entry.path, ['自然', '花园']);
      await pumpUntil(
        tester,
        () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
      );
      await tester.pump();
      await captureDesktop(tester, capture, 'codex-wide-single');
      await tapAndSave(find.byTooltip('三张并排挑'));
      final three = saved().take(3).toList();
      expect(saved(), hasLength(8));
      expect(three.map((r) => r.entry.id).toSet(), hasLength(3));
      for (final r in three) {
        expect(key('codex-choice-${r.entry.id}').hitTestable(), findsOneWidget);
      }
      await pumpUntil(
        tester,
        () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
      );
      await tester.pump();
      await captureDesktop(tester, capture, 'codex-wide-three');
      await tester.tap(key('codex-choice-${three.last.entry.id}'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(key('codex-draw-title')).data,
        three.last.entry.title,
      );
      expect(saved(), hasLength(8));
      await tapAndSave(find.byTooltip('三张并排挑'));
      expect(saved(), hasLength(8));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpUntilComplete(tester, history.flush());
      await tester.pumpAndSettle();
      expect(saved(), hasLength(11));
      expect(saved().take(3).map((r) => r.entry.id).toSet(), hasLength(3));
      final historyToggle = key('codex-random-history');
      final caret = find.descendant(
        of: historyToggle,
        matching: find.byIcon(Icons.expand_less),
      );
      final anchor = tester.getCenter(caret);
      expect(find.text('查看历史'), findsNothing);
      expect(tester.getSemantics(historyToggle).label, '查看历史');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(anchor);
      await tester.pumpAndSettle();
      expect(find.text('查看历史'), findsOneWidget);
      expect(tester.getCenter(caret), anchor);
      await mouse.moveTo(tester.getCenter(find.text('查看历史')));
      await tester.pumpAndSettle();
      expect(find.text('查看历史'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.text('查看历史'), findsNothing);
      await mouse.removePointer();
      await tester.tap(historyToggle);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
      );
      await tester.pump();
      await captureDesktop(tester, capture, 'codex-wide-history');
      final first = key('codex-history-${saved()[0].id}');
      final second = key('codex-history-${saved()[1].id}');
      expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
      expect(
        tester.getTopLeft(first).dx,
        lessThan(tester.getTopLeft(second).dx),
      );
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(key('desktop-codex-detail'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('codex-random-history'));
      await tester.pumpAndSettle();
      await tester.tap(key('codex-category-光影'));
      await tester.pumpAndSettle();
      expect(key('codex-choice-${three.last.entry.id}'), findsNothing);
      await tapAndSave(key('codex-random-draw'));
      expect(saved().take(3).every((r) => r.entry.path.first == '光影'), isTrue);
      // A recalled card is also usable with a different branch selected in the rail.
      final forest = saved().last;
      final recent = key('codex-recent-${forest.id}');
      await pumpUntil(
        tester,
        () =>
            tester.widget<Text>(key('codex-draw-recent-count')).data ==
            '最近抽取 · ${saved().length}',
      );
      await tester.scrollUntilVisible(
        recent,
        450,
        scrollable: find.descendant(
          of: key('codex-recent-draws'),
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 10,
      );
      await tester.pumpAndSettle();
      await tester.tap(recent);
      await tester.pumpAndSettle();
      final progress = tester.widget<Text>(key('codex-draw-seen')).data;
      await tapAndSave(key('codex-draw-in-category'));
      expect(saved().first.entry.path, forest.entry.path);
      expect(
        tester.widget<ListTile>(key('codex-category-光影')).selected,
        isTrue,
      );
      expect(tester.widget<Text>(key('codex-draw-seen')).data, progress);
      await tester.tap(key('codex-draw-image'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-detail'), findsOneWidget);
      expect(find.textContaining('/ 3'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'wide draw adapts to a short window and preserves the card in the narrow layout',
    (tester) async {
      await mount(tester, size: const Size(950, 510), textScale: 1.4);
      final history = container.read(codexHistoryProvider.notifier);
      await tester.runAsync(() => history.record(meta, entries.first));
      await tester.tap(key('codex-main-draw-toggle'));
      await tester.pumpAndSettle();
      final reset = key('codex-draw-reshuffle');
      expect(reset.hitTestable(), findsOneWidget);
      expect(find.byTooltip('三张并排挑'), findsOneWidget);
      expect(key('codex-draw-image').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('codex-draw-in-category'));
      expect(key('codex-draw-in-category').hitTestable(), findsOneWidget);
      tester.view.physicalSize = const Size(790, 540);
      await tester.pumpAndSettle();
      expect(find.byTooltip('三张并排挑'), findsNothing);
      expect(
        tester.widget<Text>(key('codex-draw-title')).data,
        entries.first.title,
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  for (final embedded in [false, true]) {
    testWidgets(
      'draw desk filters, details, date navigation and durable history: embedded=$embedded',
      (tester) async {
        await mount(
          tester,
          size: const Size(1500, 900),
          textScale: 1.4,
          home: embedded
              ? const Scaffold(
                  body: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 390,
                      child: CodexView(desktop: true, embedded: true),
                    ),
                  ),
                )
              : null,
        );
        final history = container.read(codexHistoryProvider.notifier);
        final now = DateTime.now();
        final oldDay = DateTime(now.year, now.month, now.day - 5, 10, 45);
        String iso(DateTime d) =>
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        final fixture = [
          for (var i = 0; i < 16; i++)
            CodexDrawRecord(
              id: 'fixture$i',
              codex: meta,
              entry: i == 0 ? entries.first : entries[(i + 2) % entries.length],
              savedAt:
                  (i == 0
                          ? oldDay
                          : DateTime(
                              now.year,
                              now.month,
                              now.day - (i < 4 ? 2 : 1),
                              10,
                              i,
                            ))
                      .millisecondsSinceEpoch,
            ),
        ];
        await tester.runAsync(() async {
          await container
              .read(codexFavoritesProvider.notifier)
              .toggle(meta.id, entries.first, now: 1);
          for (final r in fixture) {
            await history.saveDraw(r);
          }
        });
        await tester.tap(
          key(embedded ? 'desktop-codex-random' : 'codex-main-draw-toggle'),
        );
        await tester.pumpAndSettle();
        final desk = key('desktop-codex-random-workspace');
        Finder inDesk(Finder target) =>
            find.descendant(of: desk, matching: target);
        Future<void> press(String id) async {
          final w = inDesk(key(id));
          await tester.ensureVisible(w);
          await tester.tap(w);
          await tester.pumpAndSettle();
        }

        Future<void> draw({bool keyboard = false}) async {
          if (keyboard) {
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
          } else {
            await tester.tap(key('codex-random-draw'));
          }
          await pumpUntilComplete(tester, history.flush());
          await tester.pumpAndSettle();
        }

        expect(desk, findsOneWidget);
        if (!embedded) {
          expect(key('desktop-codex-grid'), findsNothing);
          expect(key('desktop-codex-categories').hitTestable(), findsOneWidget);
        }
        expect(find.text('最近抽取 · 0'), findsOneWidget);
        final reset = key('codex-draw-reshuffle');
        expect(tester.widget<TextButton>(reset).onPressed, isNull);
        if (embedded) {
          await press('codex-category-picker');
          expect(find.text('自然').hitTestable(), findsWidgets);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await press('codex-draw-only-favorites');
        } else {
          await tester.tap(key('desktop-codex-favorites'));
          await tester.pumpAndSettle();
        }
        expect(find.text('1 候选'), findsOneWidget);
        final location = tester.getCenter(reset);
        await draw();
        expect(key('codex-draw-title'), findsOneWidget);
        expect(
          tester.widget<Text>(key('codex-draw-title')).data,
          entries.first.title,
        );
        if (embedded) {
          expect(tester.widget<Text>(key('codex-draw-prompt')).maxLines, 3);
          expect(
            tester.getBottomLeft(key('codex-draw-prompt')).dy,
            lessThanOrEqualTo(tester.getTopLeft(key('codex-random-draw')).dy),
          );
        } else {
          expect(inDesk(find.text('forest')), findsOneWidget);
          expect(
            inDesk(find.text('test CHARACTER-only detail')),
            findsOneWidget,
          );
        }
        expect(tester.widget<TextButton>(reset).onPressed, isNotNull);
        expect(tester.getCenter(reset), location);
        expect(find.text('最近抽取 · 1'), findsOneWidget);
        await press('codex-draw-no-repeat');
        expect(tester.widget<TextButton>(reset).onPressed, isNull);
        await press('codex-draw-no-repeat');
        await press('codex-draw-reshuffle');
        expect(tester.widget<TextButton>(reset).onPressed, isNull);
        expect(find.text('已阅 0/1'), findsOneWidget);
        await press('codex-draw-image');
        expect(key('desktop-codex-detail'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(container.read(codexHistoryProvider).requireValue.length, 17);
        // The second draw is an independent occurrence even with just one candidate.
        await draw(keyboard: true);
        expect(container.read(codexHistoryProvider).requireValue.length, 18);
        expect(find.text('最近抽取 · 2'), findsOneWidget);
        await captureDesktop(
          tester,
          capture,
          'codex-draw-desk-${embedded ? 'sidebar' : 'catalog'}',
        );
        await press('codex-random-history');
        final nav = key('codex-draw-date-tick-navigation');
        expect(nav, findsOneWidget);
        expect(tester.getSize(nav).width, 40);
        expect(find.text('今天 · 2'), findsOneWidget);
        expect(find.text('昨天 · 12'), findsOneWidget);
        await tester.tap(key('codex-draw-date-tick-${iso(oldDay)}'));
        await tester.pumpAndSettle();
        final list = tester.widget<ListView>(key('codex-draw-history-list'));
        final offset = list.controller!.offset;
        expect(offset, greaterThan(0));
        final row = key('codex-history-fixture0');
        expect(row.hitTestable(), findsOneWidget);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        final title = find.descendant(
          of: row,
          matching: find.text(fixture.first.entry.title),
        );
        final point = tester.getCenter(title);
        await mouse.addPointer(location: Offset.zero);
        final date = iso(oldDay);
        await mouse.moveTo(tester.getCenter(key('codex-draw-date-tick-$date')));
        await tester.pumpAndSettle();
        expect(key('codex-draw-date-tick-label-$date'), findsOneWidget);
        expect(tester.getSize(nav).width, 40);
        await mouse.moveTo(point);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 399));
        expect(key('codex-draw-date-tick-label-$date'), findsNothing);
        expect(key('codex-hover-preview'), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        final preview = key('codex-hover-preview');
        await pumpUntil(
          tester,
          () => find
              .descendant(of: key(original), matching: preview)
              .evaluate()
              .isNotEmpty,
        );
        final panelBounds = tester.getRect(key('codex-draw-history-list'));
        expect(
          panelBounds.intersect(tester.getRect(preview)),
          tester.getRect(preview),
        );
        await captureDesktop(
          tester,
          capture,
          'codex-history-hover-${embedded ? 'sidebar' : 'wide'}',
        );
        await mouse.down(point);
        await tester.pump();
        expect(preview, findsNothing);
        await mouse.up();
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: key('desktop-codex-detail'),
            matching: find.text(fixture.first.entry.title),
          ),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(key('codex-draw-history-list'), findsOneWidget);
        expect(list.controller!.offset, offset);
        expect(container.read(codexHistoryProvider).requireValue.length, 18);
        await captureDesktop(
          tester,
          capture,
          'codex-draw-history-${embedded ? 'sidebar' : 'catalog'}',
        );
        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('移除')),
        );
        await pumpUntilComplete(tester, history.flush());
        await tester.pumpAndSettle();
        expect(
          container
              .read(codexHistoryProvider)
              .requireValue
              .any((r) => r.id == 'fixture0'),
          isFalse,
        );
        await press('codex-random-clear');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(container.read(codexHistoryProvider).requireValue.length, 17);
        await tester.runAsync(() async {
          for (final old in fixture.skip(1)) {
            await history.remove(old.id);
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('今天 · 2'), findsOneWidget);
        expect(
          nav,
          findsNothing,
        ); // Multiple records on the same day give one group.
        await press('codex-random-clear');
        await tester.tap(find.widgetWithText(FilledButton, '删除历史'));
        await pumpUntilComplete(tester, history.flush());
        await tester.pumpAndSettle();
        expect(container.read(codexHistoryProvider).requireValue, isEmpty);
        expect(nav, findsNothing);
        expect(
          tester.widget<TextButton>(key('codex-random-clear')).onPressed,
          isNull,
        );
        await press('codex-draw-back');
        expect(find.text('最近抽取 · 0'), findsOneWidget);
        if (embedded) {
          expect(
            tester
                .widget<OutlinedButton>(key('codex-draw-import-section'))
                .onPressed,
            isNull,
          );
        }
        if (!embedded) {
          await tester.enterText(
            key('desktop-codex-search'),
            'no matching entry',
          );
          await tester.tap(key('codex-random-draw'));
          await pumpUntilComplete(tester, history.flush());
          await tester.pumpAndSettle(const Duration(milliseconds: 300));
          expect(
            tester.widget<FilledButton>(key('codex-random-draw')).onPressed,
            isNull,
          );
          expect(container.read(codexHistoryProvider).requireValue, isEmpty);
        }
        await press('codex-draw-back');
        expect(desk, findsNothing);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );

    testWidgets(
      'anchored categories and in-place favorites: embedded=$embedded',
      (tester) async {
        await mount(
          tester,
          size: Size(embedded ? 470 : 1500, 900),
          home: embedded
              ? const Scaffold(body: CodexView(desktop: true, embedded: true))
              : null,
        );
        await tester.runAsync(() async {
          final favorites = container.read(codexFavoritesProvider.notifier);
          await favorites.toggle(meta.id, entries[0], now: 1);
          await favorites.toggle(meta.id, entries[6], now: 2);
        });
        await tester.pumpAndSettle();
        await tester.tap(key('desktop-codex-favorites'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(key('desktop-codex-card-style0'), findsOneWidget);
        expect(key('desktop-codex-card-style6'), findsOneWidget);
        expect(key('desktop-codex-card-style1'), findsNothing);
        expect(find.text('收藏 · 2'), findsNothing);
        final button = tester.getRect(key('codex-category-picker'));
        await tester.tap(key('codex-category-picker'));
        await tester.pumpAndSettle();
        final panel = key('codex-category-panel');
        final bounds = tester.getRect(key('desktop-popover'));
        expect(bounds.top, greaterThanOrEqualTo(button.bottom));
        expect(bounds.width, lessThanOrEqualTo(400));
        expect(find.byType(BottomSheet), findsNothing);
        Finder item(String text) =>
            find.descendant(of: panel, matching: find.text(text));
        await tester.tap(item('自然'));
        await tester.pumpAndSettle();
        expect(tester.getRect(key('desktop-popover')), bounds);
        expect(item('森林'), findsOneWidget);
        expect(item('全部「自然」'), findsOneWidget);
        await tester.tap(item('分类'));
        await tester.pumpAndSettle();
        expect(item('光影'), findsOneWidget);
        await tester.tap(item('自然'));
        await tester.pumpAndSettle();
        await captureDesktop(
          tester,
          capture,
          'codex-drilldown-${embedded ? 'sidebar' : 'full'}',
        );
        await tester.tap(item('森林'));
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(key('desktop-codex-card-style0'), findsOneWidget);
        expect(key('desktop-codex-card-style6'), findsNothing);
        await tester.enterText(key('desktop-codex-search'), 'nonexistent');
        await tester.pumpAndSettle(const Duration(milliseconds: 300));
        expect(find.text('没有匹配的收藏词条'), findsOneWidget);
        await tester.enterText(key('desktop-codex-search'), 'watercolor');
        await tester.pumpAndSettle(const Duration(milliseconds: 300));
        expect(key('desktop-codex-card-style0'), findsOneWidget);
        await tester.runAsync(
          () => container
              .read(codexFavoritesProvider.notifier)
              .toggle(meta.id, entries[0], now: 3),
        );
        await tester.pumpAndSettle();
        expect(key('desktop-codex-card-style0'), findsNothing);
        expect(find.text('没有匹配的收藏词条'), findsOneWidget);
        await tester.tap(key('desktop-codex-favorites'));
        await tester.pumpAndSettle();
        expect(key('desktop-codex-card-style0'), findsOneWidget);
        await tester.tap(key('codex-category-picker'));
        await tester.pumpAndSettle();
        expect(item('全部「自然」'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(key('desktop-codex-card-style6'), findsNothing);
        expect(tester.takeException(), isNull);
        await finish(tester);
        await tester.pumpAndSettle();
      },
    );
  }
}
