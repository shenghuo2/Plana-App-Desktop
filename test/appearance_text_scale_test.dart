import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/theme/app_text_scale.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/profile/appearance_page.dart';
import 'package:plana_app/main.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

/// Use the production app's theme and builder with a small settings route.
class _App extends ConsumerWidget {
  const _App({this.systemScaler, this.home = const _Page()});
  final Widget home;

  final TextScaler? systemScaler;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = const PlanaApp().build(context, ref) as MaterialApp;
    return MaterialApp(
      theme: app.theme,
      darkTheme: app.darkTheme,
      themeMode: app.themeMode,
      builder: systemScaler == null
          ? app.builder
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: systemScaler),
              child: Builder(
                builder: (context) => app.builder!(context, child),
              ),
            ),
      home: home,
    );
  }
}

class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text(
          'Text outside settings',
          key: ValueKey('outside-text'),
          style: TextStyle(fontSize: 14, height: 1),
        ),
        const TextField(key: ValueKey('draft')),
        const OriginalTextBaseline(
          child: Text('Prompt baseline', key: ValueKey('prompt-baseline')),
        ),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
              content: Text('Dialog text', key: ValueKey('dialog-text')),
            ),
          ),
          child: const Text('Open dialog'),
        ),
        const Expanded(child: AppearancePage()),
      ],
    ),
  );
}

class _SystemScaler extends TextScaler {
  const _SystemScaler();

  @override
  double scale(double fontSize) =>
      fontSize < 20 ? fontSize * 1.2 : fontSize * 1.1;

  @override
  double get textScaleFactor => 1.2;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesktopCaptureFonts);
  late AppStores stores;
  late ProviderContainer container;

  setUp(() {
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() {
    container.dispose();
  });

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> settlePrefs(WidgetTester tester) async {
    var done = false;
    unawaited(stores.prefs.idle.then((_) => done = true));
    await pumpUntil(
      tester,
      () => done,
      reason: 'Font preference must finish writing to disk',
    );
  }

  Future<ThemeSettings> reloadTheme(WidgetTester tester) async {
    await settlePrefs(tester);
    return (await tester.runAsync(() async {
      final prefs = await PrefsStore.open(
        stores.desktopOutput.root.parent,
        legacyRead: (_) async => null,
      );
      return loadThemeSettings(prefs);
    }))!;
  }

  Future<void> mount(
    WidgetTester tester, {
    TextScaler? systemScaler,
    Widget home = const _Page(),
  }) async {
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _App(systemScaler: systemScaler, home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('prompt folding is enabled by default and its switch persists', (
    tester,
  ) async {
    await mount(tester);
    final setting = key('appearance-collapse-prompts');
    final toggle = find.descendant(of: setting, matching: find.byType(Switch));
    await tester.scrollUntilVisible(
      setting,
      250,
      scrollable: find
          .descendant(
            of: find.byType(AppearancePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('提示词卡片折叠'), findsOneWidget);
    expect(find.text('默认收起提示词卡'), findsNothing);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    final restored = await reloadTheme(tester);
    expect(restored.collapsiblePromptCards, isFalse);
    expect(restored.compactCharCards, isFalse);
    container.dispose();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        themeInitProvider.overrideWithValue(restored),
      ],
    );
    await mount(tester);
    await tester.scrollUntilVisible(
      setting,
      250,
      scrollable: find
          .descendant(
            of: find.byType(AppearancePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'font setting updates the app, keeps drafts and survives reload',
    (tester) async {
      await mount(tester);
      expect(find.text('100%'), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(tester.element(key('outside-text'))).scale(14),
        closeTo(14 * 1.05, .001),
      );
      final before = tester.getSize(key('outside-text')).height;
      await tester.enterText(key('draft'), 'cat, outdoors');
      final slider = key('appearance-text-scale');
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final position = tester.getRect(slider);
      await tester.tapAt(Offset(position.right - 24, position.center.dy));
      await tester.pumpAndSettle();
      expect(container.read(themeSettingsProvider).textScale, 1.4);
      expect(tester.getSize(key('outside-text')).height, greaterThan(before));
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'cat, outdoors',
      );
      final restored = await reloadTheme(tester);
      expect(restored.textScale, 1.4);
      final restart = ProviderContainer(
        overrides: [themeInitProvider.overrideWithValue(restored)],
      );
      expect(restart.read(themeSettingsProvider).textScale, 1.4);
      restart.dispose();

      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      var scaler = MediaQuery.textScalerOf(tester.element(key('dialog-text')));
      expect(scaler.scale(14), closeTo(19.6 * 1.05, .001));
      container
          .read(themeSettingsProvider.notifier)
          .patch((settings) => settings.copyWith(textScale: .8));
      await tester.pumpAndSettle();
      expect(key('dialog-text'), findsOneWidget);
      scaler = MediaQuery.textScalerOf(tester.element(key('dialog-text')));
      expect(scaler.scale(14), closeTo(11.2 * 1.05, .001));
      Navigator.of(tester.element(key('dialog-text'))).pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      await tester.tap(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      expect(container.read(themeSettingsProvider).textScale, 1);
      expect(tester.getSize(key('outside-text')).height, before);
      expect((await reloadTheme(tester)).textScale, 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inspiration category row snapping can be enabled and disabled across restarts',
    (tester) async {
      await mount(tester);
      final setting = key('appearance-inspiration-row-snap');
      await tester.scrollUntilVisible(
        setting,
        300,
        scrollable: find
            .descendant(
              of: find.byType(AppearancePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final toggle = find.descendant(
        of: setting,
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect((await reloadTheme(tester)).inspirationRowSnap, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await reloadTheme(tester)).inspirationRowSnap, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'auto-fold after saving an inspiration persists from the creation settings',
    (tester) async {
      await mount(tester);
      final setting = key('appearance-fold-after-inspiration-save');
      await tester.scrollUntilVisible(
        setting,
        300,
        scrollable: find
            .descendant(
              of: find.byType(AppearancePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final toggle = find.descendant(
        of: setting,
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await reloadTheme(tester)).foldAfterInspirationSave, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await reloadTheme(tester)).foldAfterInspirationSave, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'album drag settings align with adjacent rows and keep their control usable when narrow',
    (tester) async {
      final capture = GlobalKey();
      await mount(
        tester,
        home: RepaintBoundary(
          key: capture,
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return Theme(
                data: theme.copyWith(
                  textTheme: theme.textTheme.apply(
                    fontFamily: 'Microsoft YaHei',
                  ),
                ),
                child: const AppearancePage(),
              );
            },
          ),
        ),
      );
      final controls = key('gallery-drag-feel');
      Future<void> revealControl() async {
        await tester.scrollUntilVisible(
          controls,
          250,
          scrollable: find
              .descendant(
                of: find.byType(AppearancePage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }

      await revealControl();
      final title = find.text('拖动跟手曲线');
      final hint = find.text('调整拖动图库卡片时相邻卡片让位、松手后卡片归位的动画。');
      final otherTitle = find.text('保存后自动合并成块');
      final otherHint = find.text('把选中的提示词存入灵感库后，在原位置合并为一个命名块。');
      final otherIcon = find
          .descendant(
            of: key('appearance-fold-after-inspiration-save'),
            matching: find.byType(Icon),
          )
          .first;
      expect(tester.getTopLeft(title).dx, tester.getTopLeft(otherTitle).dx);
      expect(tester.getTopLeft(hint).dx, tester.getTopLeft(otherHint).dx);
      expect(
        tester.widget<Text>(title).style,
        tester.widget<Text>(otherTitle).style,
      );
      expect(
        tester.widget<Text>(hint).style,
        tester.widget<Text>(otherHint).style,
      );
      final icon = find.byIcon(Icons.open_with);
      expect(tester.getTopLeft(icon).dx, tester.getTopLeft(otherIcon).dx);
      expect(
        tester.widget<Icon>(icon).size,
        tester.widget<Icon>(otherIcon).size,
      );
      expect(
        tester.getTopLeft(controls).dx,
        greaterThan(tester.getTopRight(title).dx),
      );
      await Scrollable.ensureVisible(tester.element(controls), alignment: .55);
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'gallery-appearance-controls');
      await tester.tap(find.text('微弹'));
      await tester.pumpAndSettle();
      expect(
        (await reloadTheme(tester)).galleryDragFeel,
        GalleryDragFeel.bouncy,
      );

      tester.view.physicalSize = const Size(360, 700);
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(textScale: 1.4));
      await tester.pumpAndSettle();
      await revealControl();
      expect(
        tester.getTopLeft(controls).dy,
        greaterThan(tester.getBottomLeft(hint).dy),
      );
      expect(tester.takeException(), isNull);
      await settlePrefs(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('app font size preserves the system scaling curve', (
    tester,
  ) async {
    container
        .read(themeSettingsProvider.notifier)
        .patch((settings) => settings.copyWith(textScale: 1.25));
    await mount(tester, systemScaler: const _SystemScaler());
    final scaler = MediaQuery.textScalerOf(tester.element(key('outside-text')));
    expect(scaler.scale(14), closeTo(14 * 1.2 * 1.25 * 1.05, .001));
    expect(scaler.scale(28), closeTo(28 * 1.1 * 1.25 * 1.05, .001));
    final promptScaler = MediaQuery.textScalerOf(
      tester.element(key('prompt-baseline')),
    );
    expect(promptScaler.scale(14), closeTo(14 * 1.2 * 1.25, .001));
    expect(promptScaler.scale(28), closeTo(28 * 1.1 * 1.25, .001));
    await settlePrefs(tester);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop baseline and preference do not change mobile text', (
    tester,
  ) async {
    container.dispose();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(false),
        themeInitProvider.overrideWithValue(
          const ThemeSettings(textScale: 1.4),
        ),
      ],
    );
    await mount(tester, systemScaler: const _SystemScaler());
    final scaler = MediaQuery.textScalerOf(tester.element(key('outside-text')));
    expect(scaler.scale(14), closeTo(14 * 1.2, .001));
    expect(scaler.scale(28), closeTo(28 * 1.1, .001));
    expect(key('appearance-text-scale'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'maximum app font size leaves settings usable in a narrow window',
    (tester) async {
      container
          .read(themeSettingsProvider.notifier)
          .patch((settings) => settings.copyWith(textScale: 1.4));
      await mount(tester);
      tester.view.physicalSize = const Size(360, 650);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        key('appearance-text-scale'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(AppearancePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(key('appearance-text-scale').hitTestable(), findsOneWidget);
      await tester.ensureVisible(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      await tester.tap(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      expect(container.read(themeSettingsProvider).textScale, 1);
      await settlePrefs(tester);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
