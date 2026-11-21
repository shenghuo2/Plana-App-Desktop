import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/fold_inspector.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';
import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;
  final capture = GlobalKey();
  const raw = '<#画风: 0.4::artist:jyt::, {blue eyes}, ~hat~#>, sunrise';
  setUpAll(loadDesktopCaptureFonts);

  setUp(() async {
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
    container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    gen = container.read(generateProvider.notifier);
    gen.setPrompts(positive: outputOf(raw), positiveRaw: raw);
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Future<void> mount(
    WidgetTester tester, {
    String? charId,
    String? sectionId,
    bool dark = false,
    double scale = 1,
    double width = 380,
    double topPadding = 0,
  }) async {
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.only(top: topPadding),
                      child: DesktopPromptCard(
                        charId: charId,
                        sectionId: sectionId,
                      ),
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
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Finder foldHit() => find.byWidgetPredicate(
    (widget) =>
        widget is GestureDetector &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('fold-hit-'),
  );
  Future<void> inspect(WidgetTester tester) async {
    await tester.tap(foldHit().first);
    await tester.pump();
    expect(
      find.byType(FoldInspector),
      findsOneWidget,
      reason: 'Inspection must not wait for the double-click timeout',
    );
    await tester.pumpAndSettle();
    expect(find.byType(FoldInspector), findsOneWidget);
  }

  Finder bodyField() => find.descendant(
    of: find.byType(FoldInspector),
    matching: find.byType(AnnotatedField),
  );

  testWidgets(
    'single click inspects and edits weighted text without unfolding; undo restores body',
    (tester) async {
      await mount(tester);
      final parent = tester
          .widget<AnnotatedField>(find.byType(AnnotatedField))
          .controller;
      final before = parent.text;
      await inspect(tester);
      await captureDesktop(tester, capture, 'fold-inspector-light');
      expect(parent.text, before);
      expect(gen.state.promptRaw, raw);
      final scoped = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      expect(scoped.read(editorProvider).canUndo, isFalse);
      final body = find.descendant(
        of: bodyField(),
        matching: find.byType(TextField),
      );
      await tester.enterText(body, '0.7::artist:jyt::, {blue eyes}, ~hat~');
      await tester.pumpAndSettle();
      expect(parent.text, before);
      expect(
        gen.state.promptRaw,
        '<#画风: 0.7::artist:jyt::, {blue eyes}, ~hat~#>, sunrise',
      );
      scoped.read(editorProvider.notifier).undo();
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      expect(
        tester.widget<AnnotatedField>(bodyField()).controller.text,
        '0.4::artist:jyt::, {blue eyes}, ~hat~',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'member click opens weight actions and applies changes inside the block',
    (tester) async {
      await mount(tester);
      await inspect(tester);
      final field = tester.widget<AnnotatedField>(bodyField());
      field.controller.selection = const TextSelection.collapsed(offset: 8);
      await tester.pumpAndSettle();
      final actions = find.byKey(const ValueKey('fold-member-actions'));
      expect(actions, findsOneWidget);
      expect(tester.widget<TagPanel>(actions).tok.tagMult, .4);
      await tester.tap(
        find.descendant(of: actions, matching: find.byIcon(Icons.add)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FoldInspector), findsOneWidget);
      expect(gen.state.promptRaw, contains('<#画风: 0.5::artist:jyt::'));
      expect(tester.widget<TagPanel>(actions).tok.tagMult, closeTo(.5, .00001));
      await captureDesktop(tester, capture, 'fold-inspector-member');
      await finish(tester);
    },
  );

  for (final chip in [false, true]) {
    testWidgets(
      'only a consecutive double click unfolds in ${chip ? 'tag' : 'text'} view',
      (tester) async {
        await mount(tester);
        if (chip) {
          await tester.tap(find.byKey(const ValueKey('desktop-prompt-mode')));
          await tester.pumpAndSettle();
        }
        final point = chip
            ? tester
                  .state<ChipFlowViewState>(find.byType(ChipFlowView))
                  .chipAnchor(0)!
                  .center
            : tester.getCenter(foldHit().first);
        await tester.tapAt(point);
        await tester.pump();
        expect(find.byType(FoldInspector), findsOneWidget);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('desktop-tag-popover')))
              .contains(point),
          isFalse,
          reason:
              'Immediate inspection must leave the title reachable for a second click',
        );
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(find.byType(FoldInspector), findsNothing);
        expect(gen.state.promptRaw, isNot(contains('<#画风:')));
        expect(gen.state.prompt, outputOf(raw));
        final page = chip
            ? find.byType(ChipFlowView)
            : find.byType(AnnotatedField);
        final scoped = ProviderScope.containerOf(tester.element(page));
        scoped.read(editorProvider.notifier).undo();
        await tester.pumpAndSettle();
        expect(gen.state.promptRaw, raw);
        await finish(tester);
      },
    );
  }

  for (final target in ['character', 'section']) {
    testWidgets(
      '$target inspector writes only its own block and survives mode switches',
      (tester) async {
        String? charId, sectionId;
        if (target == 'character') {
          gen.addCharacter();
          charId = gen.state.characters.single.id;
          gen.updateCharacter(
            charId,
            positive: outputOf(raw),
            positiveRaw: raw,
          );
        } else {
          sectionId = 'inspector-section';
          gen.replaceSections([
            PromptSection(
              id: sectionId,
              name: '场景',
              positive: outputOf(raw),
              positiveRaw: raw,
            ),
          ]);
        }
        await mount(tester, charId: charId, sectionId: sectionId);
        await inspect(tester);
        await tester.enterText(
          find.descendant(of: bodyField(), matching: find.byType(TextField)),
          '1.4::moonlight::',
        );
        await tester.pumpAndSettle();
        expect(gen.state.promptRaw, raw);
        final prefix = charId == null
            ? 'desktop-section-$sectionId'
            : 'desktop-character-$charId';
        await tester.tap(find.byKey(ValueKey('$prefix-mode')));
        await tester.pumpAndSettle();
        expect(find.byType(FoldInspector), findsNothing);
        final flow = tester.widget<ChipFlowView>(find.byType(ChipFlowView));
        expect(
          topLevelUnits(flow.controller.text, flow.foldBodies).first.isFold,
          isTrue,
        );
        final point = tester
            .state<ChipFlowViewState>(find.byType(ChipFlowView))
            .chipAnchor(0)!
            .center;
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(
          tester.widget<AnnotatedField>(bodyField()).controller.text,
          '1.4::moonlight::',
        );
        expect(
          charId == null
              ? gen.state.sections
                    .singleWhere((s) => s.id == sectionId)
                    .positiveRaw
              : gen.state.characters.single.positiveRaw,
          '<#画风: 1.4::moonlight::#>, sunrise',
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'linked positive and negative contents are editable without changing the parent tab',
    (tester) async {
      const negative = '<#画风·排除: bad anatomy#>';
      gen.setPrompts(
        negative: 'bad anatomy',
        negativeRaw: negative,
        promptFoldLinks: [
          const PromptFoldLink(
            id: 'pair',
            positiveName: '画风',
            positiveBody: '0.4::artist:jyt::, {blue eyes}, ~hat~',
            negativeName: '画风·排除',
            negativeBody: 'bad anatomy',
          ),
        ],
      );
      await mount(tester);
      await inspect(tester);
      await tester.tap(find.byKey(const ValueKey('fold-inspector-负面')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: bodyField(), matching: find.byType(TextField)),
        '0.6::bad anatomy::',
      );
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      expect(gen.state.negativePromptRaw, '<#画风·排除: 0.6::bad anatomy::#>');
      final scoped = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      expect(scoped.read(editorProvider).activePositive, isTrue);
      expect(
        gen.state.promptFoldLinks.single.negativeBody,
        '0.6::bad anatomy::',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'long inspector stays inside a narrow dark viewport at large text scale',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long =
          '<#画风: ${List.generate(25, (i) => '1.2::artist sample $i::').join(', ')}#>';
      gen.setPrompts(positive: outputOf(long), positiveRaw: long);
      await mount(tester, dark: true, scale: 1.5, width: 340);
      await inspect(tester);
      final bounds = tester.getRect(
        find.byKey(const ValueKey('desktop-tag-popover')).first,
      );
      expect(bounds.left, greaterThanOrEqualTo(8));
      expect(bounds.right, lessThanOrEqualTo(352));
      expect(bounds.top, greaterThanOrEqualTo(8));
      expect(bounds.bottom, lessThanOrEqualTo(752));
      final title = tester.getRect(find.text('#画风'));
      final footer = tester.getRect(find.text('删除'));
      expect(footer.bottom, lessThanOrEqualTo(bounds.bottom));
      final input = tester.widget<AnnotatedField>(bodyField());
      expect(
        input.scrollController!.position.maxScrollExtent,
        greaterThan(100),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(bodyField()),
          scrollDelta: const Offset(0, 300),
        ),
      );
      await tester.pumpAndSettle();
      expect(input.scrollController!.offset, greaterThan(100));
      expect(tester.getRect(find.text('#画风')), title);
      expect(tester.getRect(find.text('删除')), footer);
      expect(tester.takeException(), isNull);
      await captureDesktop(tester, capture, 'fold-inspector-dark-narrow');
      await finish(tester);
    },
  );

  for (final character in [false, true]) {
    testWidgets(
      'fullscreen edits ${character ? 'character' : 'main'} block in the same undo session',
      (tester) async {
        String? id;
        if (character) {
          gen.addCharacter();
          id = gen.state.characters.single.id;
          gen.updateCharacter(id, positive: outputOf(raw), positiveRaw: raw);
        }
        await mount(tester, charId: id);
        final parent = tester
            .widget<AnnotatedField>(find.byType(AnnotatedField))
            .controller;
        final parentText = parent.text;
        await inspect(tester);
        final scoped = ProviderScope.containerOf(
          tester.element(find.byType(FoldInspector)),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.open_in_full)).dx,
          lessThan(tester.getCenter(find.byIcon(Icons.content_copy)).dx),
        );
        await tester.tap(find.byIcon(Icons.open_in_full));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(FoldInspector), findsOneWidget);
        expect(
          tester.widget<FoldInspector>(find.byType(FoldInspector)).fullscreen,
          isTrue,
        );
        expect(tester.getSize(bodyField()).height, greaterThan(300));
        expect(
          ProviderScope.containerOf(tester.element(find.byType(FoldInspector))),
          same(scoped),
        );
        await tester.enterText(
          find.descendant(of: bodyField(), matching: find.byType(TextField)),
          '1.3::moonlight::, blue eyes',
        );
        await tester.pumpAndSettle();
        expect(parent.text, parentText);
        expect(
          character
              ? gen.state.characters.single.positiveRaw
              : gen.state.promptRaw,
          '<#画风: 1.3::moonlight::, blue eyes#>, sunrise',
        );
        await captureDesktop(
          tester,
          capture,
          'fold-fullscreen-${character ? 'character' : 'main'}',
        );
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(parent.text, parentText);
        scoped.read(editorProvider.notifier).undo();
        await tester.pumpAndSettle();
        expect(
          character
              ? gen.state.characters.single.positiveRaw
              : gen.state.promptRaw,
          raw,
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'long block near the middle of a short window keeps both action bars accessible',
    (tester) async {
      tester.view.physicalSize = const Size(880, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final long =
          '<#画风: ${List.generate(60, (i) => 'sample tag $i').join(', ')}#>';
      gen.setPrompts(positive: outputOf(long), positiveRaw: long);
      await mount(tester, scale: 1.5, topPadding: 150);
      await inspect(tester);
      final panel = tester.getRect(
        find.byKey(const ValueKey('fold-inspector')),
      );
      expect(tester.getSize(bodyField()).height, greaterThan(24));
      expect(tester.getRect(find.text('删除')).bottom, lessThan(panel.bottom));
      expect(panel.contains(tester.getCenter(foldHit().first)), isFalse);
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      final title = tester.getRect(find.text('#画风'));
      final footer = tester.getRect(find.text('删除'));
      final scroll = tester
          .widget<AnnotatedField>(bodyField())
          .scrollController!;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(bodyField()),
          scrollDelta: const Offset(0, 350),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(tester.getRect(find.text('#画风')), title);
      expect(tester.getRect(find.text('删除')), footer);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'fullscreen deletion still targets the block after its popover closes',
    (tester) async {
      await mount(tester);
      await inspect(tester);
      final scoped = ProviderScope.containerOf(
        tester.element(find.byType(FoldInspector)),
      );
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(gen.state.prompt, 'sunrise');
      expect(gen.state.promptRaw, isEmpty);
      scoped.read(editorProvider.notifier).undo();
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, raw);
      await finish(tester);
    },
  );

  for (final character in [false, true]) {
    testWidgets(
      'mode switch preserves ${character ? 'character' : 'main'} folds and draft',
      (tester) async {
        String? id;
        if (character) {
          gen.addCharacter();
          id = gen.state.characters.single.id;
          gen.updateCharacter(id, positive: outputOf(raw), positiveRaw: raw);
        }
        await mount(tester, charId: id);
        final field = tester.widget<AnnotatedField>(
          find.byType(AnnotatedField),
        );
        final before = field.controller.text;
        expect(parseFoldRefs(before, field.controller.foldBodies).length, 1);
        final mode = find.byKey(
          ValueKey(
            id == null ? 'desktop-prompt-mode' : 'desktop-character-$id-mode',
          ),
        );
        await tester.tap(mode);
        await tester.pumpAndSettle();
        final flow = tester.widget<ChipFlowView>(find.byType(ChipFlowView));
        expect(flow.controller.text, before);
        expect(
          topLevelUnits(
            flow.controller.text,
            flow.foldBodies,
          ).where((u) => u.isFold).length,
          1,
        );
        await tester.tap(mode);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AnnotatedField>(find.byType(AnnotatedField))
              .controller
              .text,
          before,
        );
        expect(
          id == null
              ? gen.state.promptRaw
              : gen.state.characters.single.positiveRaw,
          raw,
        );
        await finish(tester);
      },
    );
  }
}
