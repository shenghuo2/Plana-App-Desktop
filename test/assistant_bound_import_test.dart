import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_import_binding.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';

DrawProposal proposal(
  String section,
  String label,
  String text, {
  String negative = 'AI exclusion',
}) {
  final result = AgentResult.fromJson({
    'section': section,
    'positive': text,
    'negative': negative,
    'blocks': {
      'positive': ['场景·$label·Moon'],
      'negative': ['场景·$label·Moon'],
    },
  });
  return DrawProposal.fromJson(
    DrawProposal(
      section: result.section,
      positive: result.positive,
      negative: result.negative,
      blocks: result.blocks,
    ).toJson(),
  );
}

GenerateState canvas() => GenerateState.initial().copyWith(
  prompt: 'manual',
  promptRaw: '<#手写: manual#>',
  negativePrompt: 'fixed',
  negativePromptRaw: '<#固定排除: fixed#>',
  sections: const [
    PromptSection.main(),
    PromptSection(
      id: 'art',
      name: '画师',
      artist: true,
      positive: 'watercolor',
      negative: 'lowres',
      negativeRaw: '<#画师排除: lowres#>',
      sources: ['library-art'],
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = proposal('池边', '月光', 'moonlight');
  final second = proposal('教堂', '窗边', 'moonlight');
  final third = proposal('', '日落', 'sunset');
  int seq = 0;
  String id() => 'item-${seq++}';

  for (final mode in SectionImport.values) {
    test(
      'locked global negatives survive $mode in their source rows and in generation',
      () {
        final base = canvas();
        final state = proposalSendState(base, first, mode, newId: id);
        expect(state.negativePromptRaw, base.negativePromptRaw);
        final artist = state.sections.singleWhere((r) => r.id == 'art');
        expect(artist.negativeRaw, base.sections.last.negativeRaw);
        expect(artist.sources, ['library-art']);
        expect(
          composeSections(state).negativePrompt,
          composeSections(base).negativePrompt,
        );
        expect(
          state.sections.every((r) => !r.negative.contains('AI exclusion')),
          isTrue,
        );
      },
    );
  }

  test('unlocked replace-main only accepts a nonblank new negative', () {
    for (final empty in ['', '  ']) {
      final state = proposalSendState(
        canvas(),
        proposal('池边', '光', 'soft light', negative: empty),
        SectionImport.main,
        allowEditNegative: true,
        newId: id,
      );
      expect(state.negativePromptRaw, canvas().negativePromptRaw);
    }
    final state = proposalSendState(
      canvas(),
      first,
      SectionImport.main,
      allowEditNegative: true,
      newId: id,
    );
    expect(state.negativePrompt, 'AI exclusion');
    expect(state.negativePromptRaw, contains('月光'));
  });

  test(
    'append only replaces the bound span and keeps surrounding raw text and links',
    () {
      var binding = const PromptImportBinding();
      GenerateState write(
        GenerateState s,
        DrawProposal d, {
        bool allowNeg = false,
      }) => proposalSendState(
        s,
        d,
        SectionImport.appendMain,
        binding: binding,
        allowEditNegative: allowNeg,
        onBinding: (next) => binding = next,
        newId: id,
      );
      var s = write(canvas(), first, allowNeg: true);
      expect(s.prompt, 'manual, moonlight');
      expect(s.negativePrompt, 'fixed, AI exclusion');
      expect(s.promptFoldLinks.single.paired, true);
      final firstNegative = s.negativePromptRaw;
      final edited = '<#前缀: dawn#>, ${s.promptRaw}, <#后缀: flowers#>';
      s = s.copyWith(prompt: outputOf(edited), promptRaw: edited);
      binding = PromptImportBinding.fromJson(binding.toJson());
      s = write(s, second);
      expect(s.sections.map((r) => r.id), ['main', 'art']);
      expect(s.prompt, 'dawn, manual, moonlight, flowers');
      expect(parseFolds(s.promptRaw).map((f) => f.name), [
        '前缀',
        '手写',
        '☀ 窗边 · 场景',
        '后缀',
      ]);
      expect(s.negativePromptRaw, firstNegative);
      final summary = assistantCanvasBlockSummary(s, binding);
      expect(summary, contains('1. ☀ 窗边 · 场景'));
      expect(summary, contains('负面块顺序'));
      expect(summary, isNot(contains('前缀')));
      expect(summary, isNot(contains('后缀')));
      expect(
        s.promptFoldLinks.where((l) => l.negativeName.isNotEmpty),
        hasLength(1),
      );
      s = write(s, third);
      expect(s.prompt, 'dawn, manual, sunset, flowers');
      expect(s.promptRaw, contains('日落'));
      expect(
        s.promptFoldLinks
            .singleWhere((l) => l.positiveName.isNotEmpty)
            .temporaryIcon,
        'Moon',
      );
      expect(s.sections.last.positive, 'watercolor');
    },
  );

  test(
    'append also revises loose terms and deduplicates user and artist words',
    () {
      var binding = const PromptImportBinding();
      GenerateState write(GenerateState s, String pos) => proposalSendState(
        s,
        DrawProposal(positive: pos),
        SectionImport.appendMain,
        binding: binding,
        onBinding: (b) => binding = b,
        newId: id,
      );
      var s = write(canvas(), 'manual, watercolor, beach, rain');
      expect(s.prompt, 'manual, beach, rain');
      s = s.copyWith(
        prompt: 'manual, beach, rain, my suffix',
        promptRaw: '<#手写: manual#>, beach, rain, my suffix',
      );
      s = write(s, 'watercolor, snow');
      expect(s.prompt, 'manual, snow, my suffix');
      expect(s.promptRaw, '<#手写: manual#>, snow, my suffix');
    },
  );

  test(
    'append leaves interleaved user tags and ambiguous or nested matches intact',
    () {
      const old = ImportedPromptSpan(8, 'beach, rain', []);
      final slot = PromptInsertSlot.locate(
        'manual, beach, my flowers, rain',
        old,
        [],
        negative: false,
      );
      expect(slot.insert('snow', []).$1, 'manual, snow, my flowers');
      for (final text in [
        'manual, rain, rain',
        'manual, <#手写: a, rain, b#>',
        'manual, 1.1::a, rain, b::',
      ]) {
        final slot = PromptInsertSlot.locate(
          text,
          const ImportedPromptSpan(8, 'rain', []),
          [],
          negative: false,
        );
        expect(slot.insert('snow', []).$1, '$text, snow');
      }
    },
  );

  test(
    'one conversation has independent append ownership on two canvases and restores it with undo',
    () async {
      final stores = AppStores.ephemeral();
      stores.assistant.initialCurrent = [
        const AssistantMsg(id: 'user', role: MsgRole.user, text: '画', at: 1),
        for (final (i, p) in [first, second, third, second].indexed)
          AssistantMsg(
            id: 'r$i',
            role: MsgRole.ai,
            text: '好',
            at: i + 2,
            draw: p,
          ),
      ];
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      try {
        await c.read(assistantSettingsProvider.future);
        await c
            .read(assistantSettingsProvider.notifier)
            .patch((s) => s.copyWith(importTo: SectionImport.appendMain));
        final workspace = c.read(canvasWorkspaceProvider.notifier);
        final gen = c.read(generateProvider.notifier);
        final assistant = c.read(assistantProvider.notifier);
        final a = c.read(canvasWorkspaceProvider).activeId;
        gen.setPrompts(positive: 'A');
        expect(assistant.applyProposal('r0'), true);
        final b = workspace.create();
        gen.setPrompts(positive: 'B');
        expect(assistant.applyProposal('r1'), true);
        expect(assistant.applyProposal('r2', canvasId: a), true);
        expect(
          c.read(canvasWorkspaceProvider).find(a)!.prompts.prompt,
          'A, sunset',
        );
        expect(c.read(generateProvider).prompt, 'B, moonlight');
        expect(assistant.undo('r2'), true);
        await stores.flushForExit();
        await stores.assistant.load();
        c.invalidate(assistantProvider);
        final restored = c.read(assistantProvider.notifier);
        expect(restored.applyProposal('r3', canvasId: a), true);
        final p = c.read(canvasWorkspaceProvider).find(a)!.prompts;
        expect(p.prompt, 'A, moonlight');
        expect(p.promptRaw, contains('窗边'));
        expect(p.sections, isEmpty);
        expect(
          c.read(assistantProvider).currentMeta!.bindings.keys,
          containsAll([a, b]),
        );
        // A confirmed rollback of an earlier snapshot permits replay of a
        // later import, and leaves receipts on the other canvas intact.
        expect(restored.undo('r0'), false);
        expect(restored.undo('r0', force: true), true);
        final msgs = c.read(assistantProvider).msgs;
        expect(msgs.singleWhere((m) => m.id == 'r3').change!.undone, true);
        expect(msgs.singleWhere((m) => m.id == 'r1').change!.undone, false);
        expect(restored.applyProposal('r3', canvasId: a), true);
        expect(
          c.read(canvasWorkspaceProvider).find(a)!.prompts.prompt,
          'A, moonlight',
        );
      } finally {
        c.dispose();
        await stores.flushForExit();
      }
    },
  );

  test(
    'dedicated row survives move, reload, rename, undo, deletion and other conversations',
    () async {
      final stores = AppStores.ephemeral();
      AssistantMsg answer(String id, DrawProposal draw) =>
          AssistantMsg(id: id, role: MsgRole.ai, text: '好', at: 2, draw: draw);
      const ask = AssistantMsg(id: 'u', role: MsgRole.user, text: '画', at: 1);
      stores.assistant.initialCurrentMeta = const ConversationMeta(
        id: 101,
        at: 1,
      );
      stores.assistant.initialCurrent = [
        ask,
        answer('one', first),
        answer('two', second),
        answer('three', third),
      ];
      stores.assistant.initialSessions = [
        ArchivedSession(id: 102, at: 3, msgs: [ask, answer('other', second)]),
      ];
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      try {
        await c.read(assistantSettingsProvider.future);
        final gen = c.read(generateProvider.notifier);
        gen.applyCanvas(CanvasPrompts.of(canvas()), force: true);
        var assistant = c.read(assistantProvider.notifier);
        expect(assistant.applyProposal('one'), true);
        final canvasId = c.read(canvasWorkspaceProvider).activeId;
        final row = c.read(generateProvider).sections.last;
        expect(row.name, '池边');
        gen.replaceSections([
          row.copyWith(enabled: false, sources: ['merged-entry']),
          ...canvas().sections,
        ]);
        await stores.flushForExit();
        await stores.assistant.load();
        c.invalidate(assistantProvider);
        assistant = c.read(assistantProvider.notifier);
        expect(
          c.read(assistantProvider).currentMeta!.bindings[canvasId]!.sectionId,
          row.id,
        );
        final before = PromptSnapshot.of(c.read(generateProvider));
        expect(assistant.applyProposal('two'), true);
        final after = c.read(generateProvider);
        expect(after.sections.map((r) => r.id), [row.id, 'main', 'art']);
        expect(after.sections.first.name, '教堂');
        expect(after.sections.first.enabled, false);
        expect(after.sections.first.sources, ['merged-entry']);
        expect(after.sections.first.positive, 'moonlight');
        expect(
          after.sections.first.foldLinks.single.positiveName,
          contains('窗边'),
        );
        expect(after.sections.first.positiveRaw, isNot(contains('月光')));
        expect(
          assistantCanvasBlockSummary(
            after,
            c.read(assistantProvider).currentMeta!.bindings[canvasId]!,
          ),
          allOf(contains('教堂'), contains('1.'), contains('窗边')),
        );
        expect(assistant.undo('two'), true);
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          true,
        );
        expect(assistant.applyProposal('two'), true);
        assistant.openSession(102);
        expect(assistant.applyProposal('other'), true);
        final otherRow = c.read(generateProvider).sections.last;
        expect(otherRow.id, isNot(row.id));
        assistant.openSession(101);
        gen.removeSection(row.id);
        expect(assistant.applyProposal('three'), true);
        final restored = c.read(generateProvider).sections;
        expect(restored.last.name, '日落');
        expect(restored.last.id, isNot(anyOf(row.id, otherRow.id)));
        expect(restored.singleWhere((r) => r.id == otherRow.id).name, '教堂');
      } finally {
        c.dispose();
        await stores.flushForExit();
      }
    },
  );
}
