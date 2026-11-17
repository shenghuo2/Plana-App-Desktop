import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/editor/widgets/fold_inspector.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';

import 'support/character_avatar_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CharacterAvatarFixture fixture;
  late ScrollController scroll;
  final viewportKey = GlobalKey();
  final longText = List.generate(100, (i) => 'long prompt word $i').join(', ');
  Finder key(String id) => find.byKey(ValueKey(id));
  GenerateNotifier gen() => fixture.container.read(generateProvider.notifier);

  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
    scroll = ScrollController();
    gen().applyCanvas(
      CanvasPrompts.of(fixture.container.read(generateProvider)).copyWith(
        prompt: longText,
        sections: [
          const PromptSection.main(),
          PromptSection(id: 's1', name: '分区 1', positive: longText),
        ],
        characters: [
          for (var i = 1; i <= 3; i++)
            CharacterPrompt(id: 'c$i', name: '角色 $i', positive: longText),
        ],
      ),
      force: true,
    );
  });
  tearDown(() async {
    scroll.dispose();
    await fixture.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: Column(
                children: [
                  const SizedBox(height: 70, child: Text('固定顶部')),
                  Expanded(
                    child: SizedBox(
                      key: viewportKey,
                      child: SingleChildScrollView(
                        key: const PageStorageKey('prompt-sidebar'),
                        controller: scroll,
                        child: const Column(
                          children: [
                            SizedBox(height: 200),
                            PromptCard(),
                            CharacterCard(),
                            SizedBox(height: 900),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 80, child: Text('固定底部')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await pumpUntilComplete(tester, fixture.stores.flushForExit());
  }

  Rect viewport(WidgetTester tester) => tester.getRect(find.byKey(viewportKey));
  Finder field(String prefix) => find.descendant(
    of: key('$prefix-text'),
    matching: find.byType(AnnotatedField),
  );
  RenderEditable editable(WidgetTester tester, String prefix) => tester
      .state<EditableTextState>(
        find.descendant(of: field(prefix), matching: find.byType(EditableText)),
      )
      .renderEditable;

  for (final target in ['main', 'section', 'character']) {
    final prefix = switch (target) {
      'main' => 'desktop-prompt',
      'section' => 'desktop-section-s1',
      _ => 'desktop-character-c3',
    };
    final heading = switch (target) {
      'main' => 'prompt-section-header-main',
      'section' => 'prompt-section-header-s1',
      _ => 'character-header-c3',
    };
    testWidgets(
      '$target mode switch reveals its own heading without text animation',
      (tester) async {
        await mount(tester);
        await pumpUntilComplete(
          tester,
          fixture.container
              .read(editorSettingsProvider.notifier)
              .patch((s) => s.copyWith(showTranslation: true)),
        );
        await tester.pumpAndSettle();
        // A previous caret near the end must not pull the newly mounted text
        // field away from the requested heading when switching back.
        tester.widget<AnnotatedField>(field(prefix)).controller.selection =
            TextSelection.collapsed(offset: longText.length - 5);
        await Scrollable.ensureVisible(
          tester.element(key('$prefix-mode')),
          alignment: .4,
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 2; i++) {
          if (i == 1) {
            // Simulate an existing sidebar position restored by PageStorage.
            // Newly mounted inner text viewports must not read that entry.
            final ctx = tester.element(key('$prefix-mode'));
            PageStorage.of(ctx).writeState(ctx, 200.0);
          }
          await tester.tap(key('$prefix-mode'));
          await tester.pump();
          if (i == 1) {
            final initial = editable(
              tester,
              prefix,
            ).getLocalRectForCaret(TextPosition(offset: longText.length ~/ 2));
            // Inspect the first rendered frames, not just the settled view:
            // text and its annotation paint layers must never slide apart.
            for (var frame = 0; frame < 20; frame++) {
              final render = editable(tester, prefix);
              expect(
                render.offset.pixels,
                0,
                reason: 'Fresh text must not inherit the sidebar scroll offset',
              );
              expect(
                render.getLocalRectForCaret(const TextPosition(offset: 0)).top,
                inInclusiveRange(0, 30),
              );
              expect(
                render.getLocalRectForCaret(
                  TextPosition(offset: longText.length ~/ 2),
                ),
                initial,
                reason: 'Text layout must be final from its first frame',
              );
              await tester.pump(const Duration(milliseconds: 16));
            }
          }
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(key(heading)).dy,
            inInclusiveRange(viewport(tester).top, viewport(tester).top + 16),
          );
          expect(gen().state.characters.last.positive, longText);
          expect(gen().state.sections.last.positive, longText);
        }
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  for (final up in [false, true]) {
    testWidgets(
      'character drag retains its origin across outer scroll ${up ? 'up' : 'down'}',
      (tester) async {
        await mount(tester);
        const prefix = 'desktop-character-c3';
        final input = tester.widget<AnnotatedField>(field(prefix));
        final render = editable(tester, prefix);
        final origin = up ? longText.length - 10 : 10;
        final caret = render.getLocalRectForCaret(TextPosition(offset: origin));
        final desiredY = up
            ? viewport(tester).bottom - 100
            : viewport(tester).top + 100;
        scroll.jumpTo(
          scroll.offset + render.localToGlobal(caret.center).dy - desiredY,
        );
        await tester.pumpAndSettle();
        final start = render.localToGlobal(caret.center);
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(Offset(12, up ? -22 : 22));
        await tester.pump();
        final base = input.controller.selection.baseOffset;
        final beforeRange =
            input.controller.selection.end - input.controller.selection.start;
        scroll.jumpTo(scroll.offset + (up ? -500 : 500));
        await tester.pump();
        await mouse.moveBy(Offset(1, up ? -1 : 1));
        await tester.pump();
        expect(
          input.controller.selection.baseOffset,
          base,
          reason:
              'Scrolling must not move the text offset where dragging began',
        );
        expect(
          input.controller.selection.end - input.controller.selection.start,
          greaterThan(beforeRange + 200),
        );
        expect(
          key('desktop-tag-popover'),
          findsNothing,
          reason: 'Selection controls must not cover a drag in progress',
        );
        await mouse.moveTo(
          Offset(
            start.dx,
            up ? viewport(tester).top + 1 : viewport(tester).bottom - 1,
          ),
        );
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(input.controller.selection.baseOffset, base);
        expect(
          input.controller.selection.extentOffset,
          up ? 0 : longText.length,
          reason:
              'One uninterrupted drag must reach beyond its original viewport to the end',
        );
        final selection = input.controller.selection;
        await mouse.up();
        await tester.pumpAndSettle();
        expect(input.controller.selection, selection);
        final stopped = scroll.offset;
        await tester.pump(const Duration(seconds: 1));
        expect(scroll.offset, stopped);
        expect(gen().state.characters.last.positive, longText);
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets(
    'double-click word dragging keeps word boundaries',
    (tester) async {
      await mount(tester);
      const prefix = 'desktop-character-c3';
      final input = tester.widget<AnnotatedField>(field(prefix));
      final render = editable(tester, prefix);
      final caret = render.getLocalRectForCaret(const TextPosition(offset: 7));
      scroll.jumpTo(
        scroll.offset +
            render.localToGlobal(caret.center).dy -
            viewport(tester).top -
            100,
      );
      await tester.pumpAndSettle();
      final start = render.localToGlobal(caret.center);
      await tester.tapAt(start, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(55, 0));
      await tester.pump();
      expect(
        input.controller.selection.baseOffset,
        render.getWordBoundary(const TextPosition(offset: 7)).start,
      );
      final at = render.getPositionForPoint(start + const Offset(55, 0));
      expect(
        input.controller.selection.extentOffset,
        render.getWordBoundary(at).end,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      await finish(tester);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'shift drag keeps its anchor and cancellation stops edge scrolling',
    (tester) async {
      await mount(tester);
      const prefix = 'desktop-character-c3';
      final input = tester.widget<AnnotatedField>(field(prefix));
      final render = editable(tester, prefix);
      final caret = render.getLocalRectForCaret(
        const TextPosition(offset: 100),
      );
      scroll.jumpTo(
        scroll.offset +
            render.localToGlobal(caret.center).dy -
            viewport(tester).top -
            100,
      );
      await tester.pumpAndSettle();
      input.controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final mouse = await tester.startGesture(
        render.localToGlobal(caret.center),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(12, 24));
      await tester.pump();
      scroll.jumpTo(scroll.offset + 450);
      await tester.pump();
      await mouse.moveBy(const Offset(1, 1));
      await tester.pump();
      expect(input.controller.selection.baseOffset, 5);
      await mouse.moveTo(Offset(180, viewport(tester).bottom - 1));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await mouse.cancel();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      final stopped = scroll.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, stopped);
      expect(gen().state.characters.last.positive, longText);
      await finish(tester);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'inspector opens at the beginning after sidebar scrolling',
    (tester) async {
      final raw = '<#角色: $longText#>';
      gen().updateCharacter('c3', positive: longText, positiveRaw: raw);
      await mount(tester);
      await Scrollable.ensureVisible(
        tester.element(key('desktop-character-c3-text')),
        alignment: .7,
      );
      await tester.pumpAndSettle();
      // Persist the sidebar offset before an overlay with the same ancestors mounts.
      scroll.jumpTo(scroll.offset + 20);
      await tester.pumpAndSettle();
      final before = scroll.offset;
      final hit = find.descendant(
        of: key('desktop-character-c3-text'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is GestureDetector &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('fold-hit-'),
        ),
      );
      await tester.tap(hit);
      await tester.pump(const Duration(milliseconds: 350));
      final contents = find.descendant(
        of: find.byType(FoldInspector),
        matching: find.byType(AnnotatedField),
      );
      final positions = tester
          .stateList<ScrollableState>(
            find.descendant(of: contents, matching: find.byType(Scrollable)),
          )
          .map((s) => s.position)
          .toList();
      expect(positions, isNotEmpty);
      for (final p in positions) {
        expect(p.pixels, 0);
      }
      await tester.pump(const Duration(milliseconds: 200));
      for (final p in positions) {
        expect(p.pixels, 0);
      }
      expect(scroll.offset, before);
      await finish(tester);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
