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
  final entries = [
    for (var i = 0; i < 12; i++)
      CodexEntry(
        id: 'style$i',
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
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  late bool desktop;
  late List<CodexMeta> index;
  final capture = GlobalKey();
  Finder key(String value) => find.byKey(ValueKey(value));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_codex_desktop_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    desktop = true;
    index = [meta, other];
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
                  entries: entries,
                  tree: const [
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
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    temp.deleteSync(recursive: true);
  });

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
                const Scaffold(
                  body: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.all(24),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '灵感 · 法典',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            CodexPickerButton(),
                          ],
                        ),
                      ),
                      Expanded(child: CodexView(desktop: true)),
                    ],
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop codex supports nested filters, search, resizing and book switching',
    (tester) async {
      await mount(tester);
      final first = tester.getRect(key('desktop-codex-card-style0'));
      expect(first.width, lessThan(300));
      expect(first.height, 330);
      expect(tester.getTopLeft(key('desktop-codex-card-style4')).dy, first.top);
      await captureDesktop(tester, capture, 'windows17-codex-wide');
      await tester.tap(key('codex-category-自然'));
      await tester.pumpAndSettle();
      expect(find.text('自然 · 6 条'), findsOneWidget);
      await tester.tap(key('codex-category-自然/森林'));
      await tester.pumpAndSettle();
      expect(find.text('自然 / 森林 · 3 条'), findsOneWidget);
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
      await tester.pumpWidget(const SizedBox());
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
      await tester.tap(key('desktop-codex-random'));
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
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
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
    await tester.pumpWidget(const SizedBox());
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
    await tester.pumpWidget(const SizedBox());
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
      await tester.pumpWidget(const SizedBox());
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
    await tester.pump(const Duration(milliseconds: 1400));
    expect(key('codex-hover-preview'), findsNothing);
    for (final label in ['导入图片', '复制提示词', '创建分区并导入', '导入主提示词']) {
      expect(
        find
            .descendant(of: card, matching: key('codex-hover-$label'))
            .hitTestable(),
        findsOneWidget,
      );
    }
    expect(find.text('查看提示词'), findsNothing);
    await tester.pump(const Duration(milliseconds: 110));
    expect(key('codex-hover-preview'), findsOneWidget);
    final preview = tester.getRect(key('codex-hover-preview'));
    final cardBounds = tester.getRect(card);
    expect(preview.intersect(cardBounds), preview);
    expect(preview.center.dx, closeTo(cardBounds.center.dx, 1));
    final copy = find.descendant(of: card, matching: key('codex-hover-复制提示词'));
    expect(preview.overlaps(tester.getRect(copy)), isFalse);
    await captureDesktop(tester, capture, 'codex-hover-preview');
    await mouse.moveTo(tester.getCenter(key('codex-hover-preview')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(key('codex-hover-preview'), findsOneWidget);
    await mouse.down(tester.getCenter(key('codex-hover-preview')));
    await mouse.up();
    await tester.pump(const Duration(seconds: 2));
    expect(key('codex-hover-preview'), findsNothing);
    expect(key('desktop-codex-detail'), findsNothing);
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 200));
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 1510));
    expect(key('codex-hover-preview'), findsOneWidget);
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
    await tester.pumpWidget(const SizedBox());
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
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('long hover text stays bounded and scrolling dismisses it', (
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
    await tester.pump(const Duration(milliseconds: 1510));
    final rect = tester.getRect(key('codex-hover-preview'));
    expect(rect.width, lessThanOrEqualTo(396));
    expect(rect.height, lessThanOrEqualTo(480));
    final body = tester.widget<Text>(
      find.descendant(
        of: key('codex-hover-preview'),
        matching: find.byWidgetPredicate(
          (w) => w is Text && (w.data?.startsWith('1.4::') ?? false),
        ),
      ),
    );
    expect(body.data!.length, lessThanOrEqualTo(2401));
    expect(body.data, endsWith('…'));
    expect(body.overflow, TextOverflow.ellipsis);
    await captureDesktop(tester, capture, 'codex-hover-long-dark');
    // Drag the uncovered gutter, not the preview that intentionally consumes input.
    await tester.dragFrom(const Offset(410, 700), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(key('codex-hover-preview'), findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
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
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop favorites and random details keep all actions accessible',
    (tester) async {
      await mount(tester);
      final favoriteButton = find.descendant(
        of: key('desktop-codex-card-style0'),
        matching: find.byTooltip('收藏'),
      );
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
      await tester.tap(key('desktop-codex-random'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-random-workspace'), findsOneWidget);
      expect(key('desktop-codex-detail'), findsNothing);
      expect(find.text('候选内容 12'), findsOneWidget);
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
      expect(key('codex-random-history-grid'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final embedded in [false, true]) {
    testWidgets('random scope and newest-first history: embedded=$embedded', (
      tester,
    ) async {
      await mount(
        tester,
        size: Size(embedded ? 390 : 1500, 900),
        textScale: 1.4,
        home: embedded
            ? const Scaffold(body: CodexView(desktop: true, embedded: true))
            : null,
      );
      await tester.runAsync(() async {
        await container
            .read(codexFavoritesProvider.notifier)
            .toggle(meta.id, entries[0], now: 1);
        final history = container.read(codexHistoryProvider.notifier);
        for (var i = 0; i < 3; i++) {
          await history.record(meta, entries[i], now: i);
        }
      });
      await tester.tap(key('desktop-codex-random'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-random-workspace'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(key('desktop-codex-favorites'));
      await tester.pumpAndSettle();
      expect(find.text('候选内容 1'), findsOneWidget);
      expect(find.text('随机灵感'), findsOneWidget);
      final selectedColor = tester
          .widget<OutlinedButton>(key('desktop-codex-favorites'))
          .style!
          .backgroundColor!
          .resolve({});
      expect(selectedColor, isNotNull);
      expect(
        tester
            .widget<OutlinedButton>(key('desktop-codex-random'))
            .style!
            .backgroundColor!
            .resolve({}),
        selectedColor,
      );
      expect(
        tester.getCenter(key('codex-random-candidates')).dy,
        lessThan(tester.getCenter(key('codex-random-draw')).dy),
      );
      expect(
        tester.getCenter(key('codex-random-clear')).dx,
        greaterThan(tester.getCenter(key('codex-random-history')).dx),
      );
      expect(
        tester.widget<Text>(key('codex-random-scope')).data,
        contains('仅收藏'),
      );
      expect(key('desktop-codex-card-style1'), findsNothing);
      await captureDesktop(
        tester,
        capture,
        'codex-random-scope-${embedded ? 'sidebar' : 'full'}',
      );
      await tester.tap(key('codex-random-history'));
      await tester.pumpAndSettle();
      expect(find.text('抽取历史 3'), findsOneWidget);
      expect(
        tester.widget<CodexCard>(key('codex-history-0')).entry.id,
        'style2',
      );
      expect(
        tester.widget<CodexCard>(key('codex-history-1')).entry.id,
        'style1',
      );
      final first = tester.getRect(key('codex-history-0'));
      final second = tester.getRect(key('codex-history-1'));
      if (embedded) {
        expect(first.top, lessThan(second.top));
        expect(first.left, second.left);
      } else {
        expect(first.top, second.top);
        expect(first.left, lessThan(second.left));
      }
      await captureDesktop(
        tester,
        capture,
        'codex-random-history-${embedded ? 'sidebar' : 'full'}',
      );
      await tester.tap(key('codex-history-0'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(codexHistoryProvider).value, hasLength(3));
      await tester.tap(key('codex-random-candidates'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-card-style0'), findsOneWidget);
      expect(key('desktop-codex-card-style1'), findsNothing);
      final history = container.read(codexHistoryProvider.notifier);
      Future<void> draw() async {
        await tester.tap(key('codex-random-draw'));
        await pumpUntilComplete(tester, history.flush());
        await tester.pumpAndSettle();
      }

      await draw();
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('抽取历史 4'), findsOneWidget);
      expect(
        tester.widget<CodexCard>(key('codex-history-0')).entry.id,
        'style0',
      );
      if (embedded) {
        await tester.drag(
          key('codex-random-history-grid'),
          const Offset(0, -560),
        );
        await tester.pumpAndSettle();
      }
      await draw();
      expect(find.text('抽取历史 5'), findsOneWidget);
      expect(key('codex-history-0').hitTestable(), findsOneWidget);
      await tester.tap(key('codex-random-history'));
      await tester.pumpAndSettle();
      expect(container.read(codexHistoryProvider).value, hasLength(5));
      await tester.tap(key('codex-random-clear'));
      await tester.pumpAndSettle();
      expect(find.text('将清空所有法典的 5 条抽取记录。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(container.read(codexHistoryProvider).value, hasLength(5));
      await tester.tap(key('codex-random-clear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除历史'));
      await tester.pumpAndSettle();
      await pumpUntilComplete(tester, history.flush());
      await tester.pumpAndSettle();
      expect(find.text('抽取历史 0'), findsOneWidget);
      expect(
        tester.widget<IconButton>(key('codex-random-clear')).onPressed,
        isNull,
      );
      await tester.tap(key('codex-random-candidates'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-card-style0'), findsOneWidget);
      await tester.enterText(key('desktop-codex-search'), 'no matching entry');
      await tester.tap(key('codex-random-draw'));
      await pumpUntilComplete(tester, history.flush());
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(container.read(codexHistoryProvider).value, isEmpty);
      expect(key('codex-random-history-grid'), findsNothing);
      expect(
        tester.widget<FilledButton>(key('codex-random-draw')).onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('返回法典浏览'));
      await tester.pumpAndSettle();
      expect(key('desktop-codex-random-workspace'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(key('desktop-codex-random'))
            .style
            ?.backgroundColor
            ?.resolve({}),
        isNot(selectedColor),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

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
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
