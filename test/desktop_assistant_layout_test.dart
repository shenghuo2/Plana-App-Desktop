import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/widgets/proposal_actions.dart';
import 'package:plana_app/features/assistant/widgets/proposal_sheet.dart';
import 'package:plana_app/features/assistant/widgets/result_strip.dart';
import 'package:plana_app/features/assistant/widgets/conversation_navigation.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/generate/widgets/anlas_panel.dart';

class _FixtureAssistant extends AssistantNotifier {
  void seed(AssistantState initial) => state = initial;
  Completer<void>? delayedSubmit;
  int delayedCalls = 0;

  @override
  Future<void> submit(
    String text, {
    Uint8List? image,
    List<Uint8List> images = const [],
    bool withCanvas = false,
    void Function()? onAccepted,
  }) {
    if (delayedSubmit == null) {
      return super.submit(
        text,
        image: image,
        images: images,
        withCanvas: withCanvas,
        onAccepted: onAccepted,
      );
    }
    delayedCalls++;
    onAccepted?.call();
    return delayedSubmit!.future;
  }
}

class _FixedAnlas extends AnlasNotifier {
  int refreshes = 0;
  @override
  Future<NaiSubscription?> build() async => (
    anlas: 35738,
    fixedAnlas: 0,
    purchasedAnlas: 35738,
    isOpus: true,
    tier: 3,
    usage: (
      percent: 100.0,
      isNegative: false,
      secondsToNextPct: 6000,
      accounts: 1,
    ),
  );
  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

class _NoQuota extends NaiQuotaNotifier {
  @override
  Future<NaiQuota?> build() async => null;
  @override
  Future<void> refresh() async {}
}

const _current = [
  AssistantMsg(id: 'ask', role: MsgRole.user, text: '画一个站在樱花树下的猫娘', at: 1),
  AssistantMsg(
    id: 'reply',
    role: MsgRole.ai,
    text: '樱花树下,微风吹起花瓣。',
    at: 2,
    draw: DrawProposal(
      positive:
          '1girl, cat ears, white hair, red eyes, cherry blossoms, falling petals, outdoors, spring, sunlight',
    ),
  ),
];

ArchivedSession _session(int id, String title) => ArchivedSession(
  id: id,
  at: id,
  msgs: [
    AssistantMsg(id: 'ask-$id', role: MsgRole.user, text: title, at: id),
    AssistantMsg(
      id: 'reply-$id',
      role: MsgRole.ai,
      text: '已经为你整理好了提示词。',
      at: id + 1,
    ),
  ],
);

void main() {
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(() async {
    if (!Platform.isWindows) return;
    for (final font in [
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
      ('monospace', r'C:\Windows\Fonts\consola.ttf'),
      (
        'MaterialIcons',
        r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      ),
    ]) {
      final file = File(font.$2);
      if (await file.exists()) {
        await (FontLoader(
          font.$1,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  setUp(() {
    for (final entry in const {
      '1girl': '单人女性',
      'cat ears': '猫耳',
      'white hair': '白发',
      'red eyes': '红瞳',
      'cherry blossoms': '樱花',
      'falling petals': '落花',
      'outdoors': '户外',
      'spring': '春天',
      'sunlight': '阳光',
    }.entries) {
      cacheTagMeta(entry.key, trans: entry.value);
    }
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        assistantProvider.overrideWith(_FixtureAssistant.new),
        anlasProvider.overrideWith(_FixedAnlas.new),
        naiQuotaProvider.overrideWith(_NoQuota.new),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
        defaultRulesProvider.overrideWith(
          (ref, family) async => const DefaultRules(
            name: 'Test',
            author: '',
            version: '1',
            rules: [],
          ),
        ),
        agentModelsProvider.overrideWith(
          (ref) async => const AgentModelList(
            active: 'one',
            choices: [
              AgentModelChoice(key: 'one', name: 'DeepSeek v4.1 Flash'),
              AgentModelChoice(key: 'two', name: 'Model Two'),
            ],
          ),
        ),
      ],
    );
    (c.read(assistantProvider.notifier) as _FixtureAssistant).seed(
      AssistantState(
        msgs: _current,
        sessions: [
          _session(100, '森林中的小屋'),
          _session(200, '雨天的咖啡馆'),
          _session(300, '星空下的旅行'),
        ],
      ),
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    bool embedded = false,
    double embeddedWidth = 400,
    double scale = 1,
    bool dark = false,
    Widget? body,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: (dark ? AppTheme.dark() : AppTheme.light()).copyWith(
              platform: TargetPlatform.windows,
              textTheme: (dark ? AppTheme.dark() : AppTheme.light()).textTheme
                  .apply(
                    fontFamily: 'Microsoft YaHei',
                    fontFamilyFallback: const ['Segoe UI'],
                  ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body:
                  body ??
                  (embedded
                      ? Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(
                            width: embeddedWidth,
                            child: MediaQuery(
                              data: MediaQueryData(
                                size: Size(embeddedWidth, size.height),
                                textScaler: TextScaler.linear(scale),
                              ),
                              child: const AssistantPage(embedded: true),
                            ),
                          ),
                        )
                      : const AssistantPage()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    final disabled = debugDisableShadows;
    try {
      debugDisableShadows = false;
      for (final render in tester.allRenderObjects) {
        render.markNeedsPaint();
      }
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/windows-validation/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = disabled;
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'main assistant keeps history at left and model inside the composer',
    (tester) async {
      await mount(tester);
      expect(find.text('AI 助手'), findsNothing);
      expect(
        tester.widget<Text>(key('assistant-conversation-title')).data,
        _current.first.text,
      );
      expect(
        tester.getRect(key('assistant-main-settings')).right,
        greaterThan(1180),
      );
      expect(key('assistant-tick-navigation'), findsOneWidget);
      final sidebar = key('assistant-history-sidebar');
      expect(sidebar, findsOneWidget);
      expect(tester.getRect(sidebar).left, 0);
      final composer = find.widgetWithText(TextField, '想画什么、想改哪里…');
      final model = key('assistant-composer-model');
      final box = tester.getRect(key('assistant-composer'));
      expect(box.contains(tester.getRect(model).topLeft), isTrue);
      expect(box.contains(tester.getRect(model).bottomRight), isTrue);
      expect(box.contains(tester.getRect(composer).center), isTrue);
      final longModel = tester.getRect(key('assistant-model-button'));
      final send = tester.getRect(
        find.byTooltip('发送 (Enter) · Shift + Enter 换行'),
      );
      expect(longModel.width, lessThanOrEqualTo(240));
      expect(send.left - longModel.right, closeTo(8, 1));
      await tester.enterText(composer, '还没发送的草稿');
      await tester.enterText(key('assistant-history-search'), '森林');
      await tester.pumpAndSettle();
      expect(key('assistant-session-100'), findsOneWidget);
      expect(key('assistant-session-200'), findsNothing);
      await tester.enterText(key('assistant-history-search'), '');
      await tester.tap(key('assistant-session-100'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs.first.text, '森林中的小屋');
      expect(
        tester.widget<Text>(key('assistant-conversation-title')).data,
        '森林中的小屋',
      );
      expect(
        c.read(assistantProvider).sessions.any((s) => s.msgs.first.id == 'ask'),
        isTrue,
      );
      expect(tester.widget<TextField>(composer).controller!.text, '还没发送的草稿');
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('DeepSeek v4.1 Flash'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(key('assistant-model-two')).bottom,
        lessThanOrEqualTo(800),
      );
      await tester.tap(key('assistant-model-two'));
      await tester.pumpAndSettle();
      expect(c.read(assistantModelProvider)?.key, 'two');
      final shortModel = tester.getRect(key('assistant-model-button'));
      expect(shortModel.width, lessThan(longModel.width));
      expect(shortModel.right, longModel.right);
      await screenshot(tester, 'windows13-assistant-model');
      await tester.tap(find.widgetWithText(FilledButton, '新对话'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs, isEmpty);
      expect(
        tester.widget<Text>(key('assistant-conversation-title')).data,
        '新对话',
      );
      expect(
        c.read(assistantProvider).sessions.any((s) => s.title == '森林中的小屋'),
        isTrue,
      );
      await finish(tester);
    },
  );

  for (final (embedded, dark) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'conversation outline seeks lazy messages and returns to bottom: embedded=$embedded dark=$dark',
      (tester) async {
        final notifier =
            c.read(assistantProvider.notifier) as _FixtureAssistant;
        final msgs = <AssistantMsg>[
          for (var i = 0; i < 70; i++) ...[
            AssistantMsg(
              id: 'question-$i',
              role: MsgRole.user,
              text: '第 ${i + 1} 轮：请描绘森林中的小屋与星空 $i',
              at: i * 2 + 1,
            ),
            AssistantMsg(
              id: 'answer-$i',
              role: MsgRole.ai,
              text: List.filled(
                1 + (i % 7) * 4,
                '月光下的小屋，周围是茂密的森林。',
              ).join('\n\n'),
              at: i * 2 + 2,
            ),
          ],
        ];
        notifier.seed(AssistantState(msgs: msgs));
        await mount(
          tester,
          embedded: embedded,
          dark: dark,
          scale: dark ? 1.4 : 1,
          embeddedWidth: dark ? 330 : 400,
          size: dark ? const Size(820, 700) : const Size(1200, 800),
        );
        final frame = tester.widget<ConversationNavigation>(
          find.byType(ConversationNavigation),
        );
        final nav = frame.controller;
        expect(nav.scroll.offset, 0);
        expect(nav.entries.length, 70);
        expect(nav.keyFor('question-0').currentContext, isNull);
        if (embedded) {
          expect(key('assistant-conversation-title'), findsNothing);
        } else {
          expect(
            tester.getRect(key('assistant-message-list')).center.dx,
            closeTo(tester.getRect(key('assistant-composer')).center.dx, 1),
          );
        }
        final outline = tester.getRect(key('assistant-tick-navigation'));
        final body = tester.getRect(find.byType(ConversationNavigation));
        expect(outline.center.dy, closeTo(body.center.dy, 1));
        expect(outline.right, closeTo(body.right, 1));
        expect(find.text('对话目录'), findsNothing);
        expect(key('assistant-outline-drawer'), findsNothing);
        expect(key('assistant-outline-toggle'), findsNothing);
        await screenshot(
          tester,
          'assistant-taper-long-${embedded ? 'sidebar' : 'main'}${dark ? '-dark' : ''}-20261110',
        );
        final rail = tester.getRect(key('assistant-tick-navigation'));
        await tester.tapAt(Offset(rail.right - 18, rail.center.dy));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(nav.keyFor('question-0').currentContext, isNotNull);
        final oldest = tester.getRect(find.byKey(nav.keyFor('question-0')));
        final viewport = tester.getRect(find.byKey(nav.viewportKey));
        expect(oldest.overlaps(viewport), isTrue);
        expect(nav.activeId, 'question-0');
        expect(key('assistant-to-bottom'), findsOneWidget);
        expect(
          tester.getCenter(key('assistant-to-bottom')).dx,
          closeTo(
            tester.getRect(find.byType(ConversationNavigation)).center.dx,
            1,
          ),
        );
        await screenshot(
          tester,
          'assistant-bottom-${embedded ? 'embedded' : 'main'}${dark ? '-dark' : ''}-20261110',
        );

        // Streaming and queued turns must not pull a reader away from old messages.
        final before = nav.scroll.offset;
        notifier.seed(
          AssistantState(msgs: msgs, running: true, liveText: '正在续写新回复'),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(nav.scroll.offset, closeTo(before, 1));
        notifier.seed(AssistantState(msgs: msgs));
        await tester.pumpAndSettle();
        await tester.tap(key('assistant-to-bottom'));
        await tester.pumpAndSettle();
        expect(nav.scroll.offset, closeTo(0, .1));
        expect(key('assistant-to-bottom'), findsNothing);

        {
          // A held pointer at the rail edge scrolls the tick window; releasing
          // outside must stop that timer and leave the selected turn alone.
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          final rail = tester.getRect(key('assistant-tick-navigation'));
          await mouse.addPointer(location: const Offset(10, 10));
          final edge = Offset(rail.right - 18, rail.top + 3);
          await mouse.moveTo(edge);
          await tester.pumpAndSettle();
          await mouse.down(edge);
          await tester.pump();
          final startedAt = nav.activeId!;
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 110));
          }
          expect(
            int.parse(nav.activeId!.split('-').last),
            lessThan(int.parse(startedAt.split('-').last)),
          );
          await mouse.up();
          await mouse.moveTo(const Offset(10, 10));
          await tester.pumpAndSettle();
          final selected = nav.activeId;
          await tester.pump(const Duration(seconds: 1));
          expect(nav.activeId, selected);
          expect(tester.getSize(key('assistant-tick-navigation')).width, 44);
          await mouse.removePointer();
        }

        {
          final rail = tester.getRect(key('assistant-tick-navigation'));
          await tester.tapAt(Offset(rail.right - 18, rail.center.dy));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.home);
          for (var i = 0; i < 35; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          }
        }
        await tester.pumpAndSettle();
        expect(nav.activeId, 'question-35');
        expect(nav.keyFor('question-35').currentContext, isNotNull);
        expect(
          tester
              .getRect(find.byKey(nav.keyFor('question-35')))
              .overlaps(viewport),
          isTrue,
        );
        expect(nav.activeId, 'question-35');

        await tester.runAsync(
          () => c
              .read(assistantSettingsProvider.notifier)
              .patch((s) => s.copyWith(introVersion: kAssistantIntroVersion)),
        );
        notifier.delayedSubmit = Completer<void>();
        await tester.enterText(
          find.widgetWithText(TextField, '想画什么、想改哪里…'),
          '继续画',
        );
        await tester.pump();
        await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
        await tester.pumpAndSettle();
        expect(notifier.delayedCalls, 1);
        final reading = nav.reveal('question-35');
        await tester.pumpAndSettle();
        expect(await reading, isTrue);
        final readingOffset = nav.scroll.offset;
        notifier.delayedSubmit!.complete();
        await tester.pumpAndSettle();
        expect(
          nav.scroll.offset,
          closeTo(readingOffset, 1),
          reason:
              'Completing a delayed send must preserve the reader’s older turn.',
        );

        // Changing sessions cancels stale navigation and returns to the new chat.
        final inFlight = nav.reveal('question-0');
        notifier.seed(const AssistantState(msgs: _current));
        await tester.pumpAndSettle();
        expect(await inFlight, isFalse);
        expect(nav.entries.single.id, 'ask');
        expect(nav.scroll.offset, closeTo(0, .1));
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  for (final (embedded, dark) in [
    (false, false),
    (false, true),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'fisheye hovers, scrubs, steps and folds: embedded=$embedded dark=$dark',
      (tester) async {
        final notifier =
            c.read(assistantProvider.notifier) as _FixtureAssistant;
        notifier.seed(
          AssistantState(
            msgs: [
              for (var i = 0; i < 12; i++) ...[
                AssistantMsg(
                  id: 'tick-$i',
                  role: MsgRole.user,
                  text: '第 ${i + 1} 轮：森林小屋与星空，保留温暖的灯光',
                  at: i * 2 + 1,
                ),
                AssistantMsg(
                  id: 'text-$i',
                  role: MsgRole.ai,
                  text: List.filled(
                    12 + i % 3,
                    '窗边洒满月光，院子里有一只正在打盹的小猫。',
                  ).join('\n\n'),
                  at: i * 2 + 2,
                ),
              ],
            ],
          ),
        );
        await mount(
          tester,
          dark: dark,
          embedded: embedded,
          embeddedWidth: dark ? 330 : 400,
          scale: dark ? 1.4 : 1,
          size: dark ? const Size(1000, 820) : const Size(1600, 900),
        );
        final nav = tester
            .widget<ConversationNavigation>(find.byType(ConversationNavigation))
            .controller;
        final body = tester.getRect(find.byType(ConversationNavigation));
        final list = tester.getRect(key('assistant-message-list'));
        final input = embedded
            ? body
            : tester.getRect(key('assistant-composer'));
        expect(list.center.dx, closeTo(body.center.dx, 1));
        expect(input.center.dx, closeTo(body.center.dx, 1));
        expect(list.width, lessThanOrEqualTo(960));
        expect(find.text('对话目录'), findsNothing);
        expect(key('assistant-outline'), findsNothing);
        expect(tester.getSize(key('assistant-tick-navigation')).width, 44);
        final resting = <int, Offset>{
          for (var i = 0; i < 12; i++)
            i: tester.getCenter(key('assistant-tick-tick-$i')),
        };
        final idleWidth = tester.getSize(key('assistant-tick-tick-5')).width;
        await screenshot(
          tester,
          'assistant-taper-idle-${embedded ? 'sidebar' : 'main'}${dark ? '-dark' : ''}-20261110',
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(10, 10));
        await mouse.moveTo(resting[5]!);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(key('assistant-tick-tick-5')).width,
          greaterThan(idleWidth + 15),
        );
        final lengths = [
          for (var i = 0; i <= 5; i++)
            tester.getSize(key('assistant-tick-tick-${5 - i}')).width,
        ];
        expect(
          lengths[0] - lengths[1],
          greaterThan(8),
          reason: 'The focus tick must stand out from its neighbors.',
        );
        for (var i = 1; i < lengths.length; i++) {
          expect(lengths[i], lessThan(lengths[i - 1]));
          expect(
            tester.getSize(key('assistant-tick-tick-${5 + i}')).width,
            closeTo(lengths[i], .1),
          );
        }
        expect(key('assistant-tick-label-tick-5'), findsOneWidget);
        expect(key('assistant-tick-label-tick-0'), findsNothing);
        final labels = [
          for (var i = 3; i <= 7; i++)
            tester.getRect(key('assistant-tick-label-tick-$i')),
        ];
        for (final label in labels) {
          expect(label.left, greaterThanOrEqualTo(body.left));
          expect(label.right, lessThan(body.right));
        }
        for (var i = 1; i < labels.length; i++) {
          expect(
            labels[i - 1].bottom,
            lessThanOrEqualTo(labels[i].top + 2),
            reason: 'Hover labels must remain legible at large text sizes.',
          );
        }
        await screenshot(
          tester,
          'assistant-taper-hover-${embedded ? 'sidebar' : 'main'}${dark ? '-dark' : ''}-20261110',
        );
        await mouse.down(resting[5]!);
        await tester.pump(const Duration(milliseconds: 20));
        await mouse.moveTo(resting[8]!);
        await tester.pump(const Duration(milliseconds: 20));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(nav.activeId, 'tick-8');
        expect(nav.keyFor('tick-8').currentContext, isNotNull);
        expect(
          tester.getRect(find.byKey(nav.keyFor('tick-8'))).overlaps(list),
          isTrue,
        );
        expect(
          tester.getCenter(key('assistant-to-bottom')).dx,
          closeTo(input.center.dx, 1),
        );
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: resting[8]!,
            kind: PointerDeviceKind.mouse,
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.pumpAndSettle();
        expect(nav.activeId, 'tick-7');
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(nav.activeId, 'tick-0');
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pumpAndSettle();
        expect(nav.activeId, 'tick-11');
        await mouse.moveTo(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(tester.getSize(key('assistant-tick-navigation')).width, 44);
        expect(key('assistant-tick-label-tick-11'), findsNothing);
        await tester.tap(key('assistant-to-bottom'));
        await tester.pumpAndSettle();
        expect(nav.scroll.offset, 0);
        expect(key('assistant-to-bottom'), findsNothing);
        // Releasing outside the rail must also stop scrubbing and hide the lens.
        await mouse.moveTo(resting[5]!);
        await tester.pumpAndSettle();
        await mouse.down(resting[5]!);
        await mouse.moveTo(const Offset(10, 10));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(tester.getSize(key('assistant-tick-navigation')).width, 44);
        await mouse.removePointer();
        await finish(tester);
      },
    );
  }

  testWidgets('main proposal expands inside its message and survives resize', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ResultStrip),
        matching: find.byType(ProposalDetails),
      ),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(ProposalActions), findsOneWidget);
    await screenshot(tester, 'assistant-main-inline-windows12');
    tester.view.physicalSize = const Size(820, 640);
    await tester.pumpAndSettle();
    expect(key('assistant-history-sidebar'), findsOneWidget);
    expect(key('assistant-inline-proposal'), findsOneWidget);
    await screenshot(tester, 'assistant-main-compact-windows12');
    await Scrollable.ensureVisible(
      tester.element(find.text('收起')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalDetails), findsNothing);
    tester.view.physicalSize = const Size(650, 540);
    await tester.pumpAndSettle();
    expect(key('assistant-history-sidebar'), findsNothing);
    expect(find.byTooltip('历史会话'), findsOneWidget);
    expect(key('assistant-composer-model'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'embedded history opens by its button in global window coordinates',
    (tester) async {
      await mount(tester, embedded: true);
      expect(key('assistant-history-sidebar'), findsNothing);
      expect(key('assistant-composer-model'), findsNothing);
      final button = find.widgetWithIcon(IconButton, Icons.history);
      final anchor = tester.getRect(button);
      final composer = find.widgetWithText(TextField, '想画什么、想改哪里…');
      await tester.enterText(composer, '保留这段草稿');
      await tester.tap(button);
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 380);
      expect(panel.top, closeTo(anchor.bottom + 8, 1));
      expect(panel.right, closeTo(anchor.right, 1));
      expect(panel.height, lessThan(460));
      expect(find.byType(BottomSheet), findsNothing);
      await screenshot(tester, 'assistant-history-popover-windows11');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsNothing);
      expect(tester.widget<TextField>(composer).controller!.text, '保留这段草稿');
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(key('assistant-session-200'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs.first.text, '雨天的咖啡馆');
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'quota is a small anchored panel with refresh and outside dismissal',
    (tester) async {
      await mount(
        tester,
        body: const Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(200, 60, 0, 0),
            child: AnlasChip(),
          ),
        ),
      );
      final chip = find.byType(AnlasChip);
      final anchor = tester.getRect(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 370);
      expect(panel.top, closeTo(anchor.bottom + 8, 1));
      expect(panel.left, greaterThanOrEqualTo(12));
      expect(panel.height, lessThan(460));
      expect(find.text('NAI 5 额度'), findsOneWidget);
      expect(find.text('0+35,738'), findsOneWidget);
      final notifier = c.read(anlasProvider.notifier) as _FixedAnlas;
      expect(notifier.refreshes, 1);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(notifier.refreshes, 2);
      await screenshot(tester, 'quota-popover-windows11');
      await tester.tapAt(const Offset(1000, 400));
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'quota flips above a low anchor and scrolls within a short window',
    (tester) async {
      await mount(
        tester,
        size: const Size(620, 330),
        body: const Align(
          alignment: Alignment.bottomRight,
          child: Padding(padding: EdgeInsets.all(20), child: AnlasChip()),
        ),
      );
      final anchor = tester.getRect(find.byType(AnlasChip));
      await tester.tap(find.byType(AnlasChip));
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.bottom, lessThanOrEqualTo(anchor.top - 8));
      expect(panel.top, greaterThanOrEqualTo(12));
      expect(panel.right, lessThanOrEqualTo(608));
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(find.text('已充满').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );
}
