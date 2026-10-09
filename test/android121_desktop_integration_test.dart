import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/widgets/model_sheet.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/features/inspiration/tag_editor_page.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

const pair = PromptFoldLink(
  id: 'style',
  positiveName: 'style',
  positiveBody: 'rain',
  negativeName: 'style',
  negativeBody: 'blurry',
);

GenerateState pairedSections() => GenerateState.initial().copyWith(
  prompt: 'rain',
  promptRaw: '<#style: rain>',
  negativePrompt: 'blurry',
  negativePromptRaw: '<#style: blurry>',
  promptFoldLinks: [pair],
  sections: const [
    PromptSection.main(),
    PromptSection(
      id: 'scene',
      name: '场景',
      positive: 'rain',
      positiveRaw: '<#style: rain>',
      negative: 'blurry',
      negativeRaw: '<#style: blurry>',
      foldLinks: [pair],
    ),
  ],
);

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState();
}

void main() {
  test('section merge renames colliding folds and keeps both paired links', () {
    final merged = mergeSectionsIn(pairedSections(), {'main', 'scene'})!;
    expect(merged.sections, isEmpty);
    expect(merged.prompt, 'rain, rain');
    expect(merged.promptFoldLinks.map((l) => l.id).toSet(), hasLength(2));
    expect(
      parseFolds(merged.promptRaw).map((f) => f.name).toSet(),
      hasLength(2),
    );
    expect(
      validPromptFoldLinks(
        merged.promptRaw,
        merged.negativePromptRaw,
        merged.promptFoldLinks,
      ),
      merged.promptFoldLinks,
    );
  });

  test(
    'disabled main does not leak positive raw text or invalid paired links',
    () {
      final original = pairedSections();
      final snapshot = composeSections(
        original.copyWith(
          sections: [
            const PromptSection.main(enabled: false),
            original.sections.last,
          ],
        ),
      );
      expect(snapshot.prompt, 'rain');
      expect(snapshot.negativePrompt, 'blurry');
      expect(outputOf(snapshot.promptRaw), snapshot.prompt);
      expect(outputOf(snapshot.negativePromptRaw), snapshot.negativePrompt);
      expect(
        snapshot.promptFoldLinks,
        isEmpty,
        reason: 'the remaining negative fold is owned by the disabled main',
      );
    },
  );

  test(
    'billing fallback includes relay charge once and keeps decimal amounts',
    () {
      final fields = {
        'image_fee': 12,
        'anlas_fee': .5,
        'relay_fee': .75,
        'relay_calls': 3,
      };
      expect(BillingParty.fromJson(fields).totalFee, 13.25);
      expect(
        BillingParty.fromJson({...fields, 'total_fee': 13.25}).totalFee,
        13.25,
      );
      expect(BillingParty.fromJson(fields).relayCalls, 3);
    },
  );

  late AppStores stores;
  late ProviderContainer c;
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
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        tagLibraryProvider.overrideWith(_Library.new),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
        assistantBotAuthorizedProvider.overrideWithValue(false),
        agentModelsProvider.overrideWith(
          (_) async => parseAgentModels({
            'active': 'paid',
            'choices': {
              'paid': {'name': 'Paid Model'},
              'free': {'name': 'Free Model', 'free': true},
            },
          }),
        ),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 500, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('desktop free model menu is usable without Bot authorization', (
    tester,
  ) async {
    await mount(tester, const AssistantModelDropdown());
    await tester.tap(find.byKey(const ValueKey('assistant-model-button')));
    await tester.pumpAndSettle();
    expect(find.text('免费模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-model-paid')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('assistant-model-free')));
    await tester.pumpAndSettle();
    expect(c.read(assistantModelKeyProvider), 'free');
    await finish(tester);
  });

  testWidgets(
    'mouse selection flushes inline edits; merge undo belongs to source canvas',
    (tester) async {
      final gen = c.read(generateProvider.notifier);
      gen.applyCanvas(CanvasPrompts.of(pairedSections()), force: true);
      final source = c.read(canvasWorkspaceProvider).activeId;
      await mount(tester, const PromptCard());
      final input = find.descendant(
        of: find.byKey(const ValueKey('desktop-prompt-text')),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        input,
        '${tester.widget<TextField>(input).controller!.text}, forest',
      );
      await tester.tap(find.byKey(const ValueKey('prompt-section-select')));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).prompt, 'rain, forest');
      final before = c.read(generateProvider);
      await tester.tap(find.byKey(const ValueKey('prompt-section-pick-scene')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('合并'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).promptFoldLinks, hasLength(2));
      c.read(canvasWorkspaceProvider.notifier).create();
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).prompt, isEmpty);
      final restored = c.read(canvasWorkspaceProvider).find(source)!.prompts;
      expect(restored.prompt, before.prompt);
      expect(restored.promptFoldLinks, before.promptFoldLinks);
      expect(restored.sections, before.sections);
      await finish(tester);
    },
  );

  testWidgets(
    'saving a section uses the desktop floating editor with both prompts',
    (tester) async {
      c
          .read(generateProvider.notifier)
          .applyCanvas(CanvasPrompts.of(pairedSections()), force: true);
      await mount(tester, const PromptCard());
      await tester.tap(find.byKey(const ValueKey('prompt-section-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('prompt-section-pick-main')));
      await tester.tap(find.byKey(const ValueKey('prompt-section-pick-scene')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('存到灵感库'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tag-editor-dialog')), findsOneWidget);
      final editor = tester.widget<TagEditorPage>(find.byType(TagEditorPage));
      expect(editor.floating, isTrue);
      expect(editor.draft?.positive, 'rain');
      expect(editor.draft?.negative, 'blurry');
      expect(editor.cat, TagCategory.scene);
      await finish(tester);
    },
  );

  test('negative editing keeps disabled main; positive editing reopens it', () {
    final gen = c.read(generateProvider.notifier);
    gen.applyCanvas(CanvasPrompts.of(pairedSections()), force: true);
    gen.updateSection('main', enabled: false);
    final editor = c.read(editorProvider.notifier);
    editor.load(positive: 'rain', negative: 'blurry', startPositive: false);
    editor.editActive('fog');
    editor.flushWriteBack();
    expect(c.read(generateProvider).sections.first.enabled, isFalse);
    editor.setActivePositive(true);
    editor.editActive('forest');
    editor.flushWriteBack();
    expect(c.read(generateProvider).sections.first.enabled, isTrue);
  });
}
