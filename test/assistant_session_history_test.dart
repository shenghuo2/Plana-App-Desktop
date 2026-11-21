import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/session_store.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/canvas_models.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/generation_controller.dart';

List<AssistantMsg> messages(int id) => [
  AssistantMsg(id: 'user-$id', role: MsgRole.user, text: 'chat $id', at: id),
  AssistantMsg(
    id: 'ai-$id',
    role: MsgRole.ai,
    text: 'reply',
    at: id + 1,
    draw: const DrawProposal(positive: '1girl'),
  ),
];
ArchivedSession session(int id) =>
    ArchivedSession(id: id, at: id, msgs: messages(id));

class _SeedAssistant extends AssistantNotifier {
  void seedTemporary() => state = state.copyWith(msgs: messages(999));
}

class _Settings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async =>
      const AssistantSettings(inlineImage: true);
}

class _DelayedGeneration extends GenerationNotifier {
  final finish = Completer<void>();
  int cancelled = 0;
  String? resultId;
  @override
  GenPool build() => const GenPool();
  @override
  void cancel() {
    cancelled++;
  }

  @override
  void cancelJob(String id) {
    cancelled++;
  }

  @override
  Future<GenOutcome> generate({
    GallerySaveTarget? galleryTarget,
    GenerateState? using,
    bool stay = false,
    void Function(String)? onJob,
    CanvasOrigin? origin,
  }) async {
    onJob?.call('delayed-image');
    await finish.future;
    final result = await ref
        .read(galleryProvider.notifier)
        .addResultToGallery(
          bytes: Uint8List.fromList(
            img.encodePng(img.Image(width: 16, height: 16)),
          ),
          width: 16,
          height: 16,
          seed: 1,
          target: const GallerySaveTarget.all(),
          input: using,
          notify: false,
        );
    resultId = result.id;
    return GenOutcome.ok;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late Directory root;
  ProviderContainer? c;
  setUp(() {
    stores = AppStores.ephemeral();
    root = stores.desktopOutput.root.parent;
  });
  tearDown(() async {
    c?.dispose();
    c = null;
    await stores.flushForExit();
    await root.delete(recursive: true);
  });

  test(
    'v1 migration preserves dates, resolves ID collision, persists rename and pins',
    () async {
      final file = File('${root.path}/assistant/sessions.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'v': 1,
          'current': [for (final m in messages(10)) m.toJson()],
          'sessions': [session(10).toJson(), session(30).toJson()],
        }),
      );
      await stores.assistant.load();
      c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      final n = c!.read(assistantProvider.notifier);
      final active = c!.read(assistantProvider).currentSession!;
      expect(active.id, isNot(10));
      expect(active.at, 11);
      final initialOrder = c!
          .read(assistantProvider)
          .history
          .map((s) => s.id)
          .toList();
      n.openSession(30);
      expect(c!.read(assistantProvider).history.map((s) => s.id), initialOrder);
      n.renameSession(active.id, '猫猫的画风');
      n.toggleSessionPin(active.id);
      n.openSession(active.id);
      n.toggleSessionPin(30);
      final expected = c!
          .read(assistantProvider)
          .history
          .map((s) => s.toJson())
          .toList();
      stores.assistant.flush();
      await stores.assistant.idle;
      final restored = AssistantStore(stores.blobs, root);
      await restored.load();
      final state = AssistantState(
        msgs: restored.initialCurrent,
        currentMeta: restored.initialCurrentMeta,
        sessions: restored.initialSessions,
      );
      expect(state.history.map((s) => s.toJson()).toList(), expected);
      expect(state.conversationTitle, '猫猫的画风');
      expect(state.currentSession!.meta.pinned, isTrue);
      expect(state.history.first.id, 30);
      expect(state.history.map((s) => s.id).toSet(), hasLength(3));
      // Reusing the store to reload an empty draft must not resurrect metadata.
      stores.assistant.schedule(const [], state.history);
      stores.assistant.flush();
      await stores.assistant.idle;
      await restored.load();
      expect(restored.initialCurrent, isEmpty);
      expect(restored.initialCurrentMeta, isNull);
    },
  );

  test(
    'empty drafts stay out of history and pinned conversations survive retention',
    () {
      stores.assistant.initialCurrent = messages(100);
      stores.assistant.initialSessions = [
        session(1).meta.copyWith(pinnedAt: 1).withMessages(messages(1)),
        for (var i = 2; i <= 40; i++) session(i),
      ];
      c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      final n = c!.read(assistantProvider.notifier);
      n.archiveCurrent();
      final state = c!.read(assistantProvider);
      expect(state.currentSession, isNull);
      expect(state.history, hasLength(AssistantStore.maxSessions));
      expect(state.history.first.id, 1);
      expect(state.history[1].id, 100);
      final before = state.history.map((s) => s.id).toList();
      n.setTemporary(true);
      n.setTemporary(false);
      n.archiveCurrent();
      expect(c!.read(assistantProvider).history.map((s) => s.id), before);
    },
  );

  test(
    'temporary image job survives switching; result persists only in gallery',
    () async {
      stores.assistant.initialSessions = [session(1)];
      c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          assistantProvider.overrideWith(_SeedAssistant.new),
          assistantSettingsProvider.overrideWith(_Settings.new),
          generationProvider.overrideWith(_DelayedGeneration.new),
        ],
      );
      await c!.read(assistantSettingsProvider.future);
      final n = c!.read(assistantProvider.notifier) as _SeedAssistant;
      n.setTemporary(true);
      n.seedTemporary();
      final pending = n.generateFrom('ai-999');
      final generation =
          c!.read(generationProvider.notifier) as _DelayedGeneration;
      expect(c!.read(assistantProvider).jobs['ai-999'], 'delayed-image');
      n.openSession(1);
      expect(c!.read(assistantProvider).jobs['ai-999'], 'delayed-image');
      expect(generation.cancelled, 0);
      generation.finish.complete();
      await pending;
      final id = generation.resultId!;
      expect(c!.read(galleryProvider).results.single.id, id);
      expect(await stores.gallery.readImage(id), isNotNull);
      expect(c!.read(assistantProvider).jobs, isEmpty);
      expect(c!.read(assistantProvider).history.map((s) => s.id), [1]);
      expect(
        c!.read(assistantProvider).msgs.expand((m) => m.imageIds),
        isEmpty,
      );
      await stores.flushForExit();
      final saved = await File(
        '${root.path}/assistant/sessions.json',
      ).readAsString();
      expect(saved, isNot(contains('999')));
      expect(saved, isNot(contains(id)));
    },
  );
}
