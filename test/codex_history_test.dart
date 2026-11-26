import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/codex/codex_history.dart';
import 'package:plana_app/features/inspiration/codex/codex_draw_pool.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const book = CodexMeta(
    id: 'book',
    title: '画风',
    type: CodexType.string,
    version: '3',
    assetBaseUrl: 'https://example.test/pictures',
    assetPathMode: 'relative',
  );
  const entry = CodexEntry(
    id: 'entry',
    title: '森林',
    tags: '1.4::forest::',
    image: 'forest.webp',
    original: 'forest.png',
    characters: [CodexCharacter('char1', 'blue eyes')],
  );

  test(
    'history snapshots retain weighted tags, characters and image origins',
    () {
      final record = CodexDrawRecord(codex: book, entry: entry, savedAt: 3);
      final restored = CodexDrawRecord.fromJson(record.toJson())!;
      expect(restored.entry.toJson(), entry.toJson());
      expect(restored.codex.assetBaseUrl, book.assetBaseUrl);
      expect(restored.codex.assetPathMode, book.assetPathMode);
      expect(restored.savedAt, 3);
      expect(CodexDrawRecord.fromJson({'entry': {}}), isNull);
    },
  );

  test(
    'old duplicate snapshots and multiple draws survive restart, recent only includes this session',
    () async {
      final temp = Directory.systemTemp.createTempSync('plana_deck_restart_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => temp.path,
      );
      final first = ProviderContainer();
      final second = ProviderContainer();
      try {
        final snapshot = CodexDrawRecord(
          codex: book,
          entry: entry,
          savedAt: 55,
        ).toJson();
        File(
          '${temp.path}/codex_random_history.json',
        ).writeAsStringSync(jsonEncode([snapshot, snapshot]));
        final old = await first.read(codexHistoryProvider.future);
        expect(old.map((r) => r.id).toSet(), hasLength(2));
        final session = first.read(codexDrawSessionProvider);
        expect(old.where(session.contains), isEmpty);
        final notifier = first.read(codexHistoryProvider.notifier);
        await Future.wait([
          notifier.record(book, entry, now: 55),
          notifier.record(book, entry, now: 55),
        ]);
        await notifier.remove(old.first.id);
        final saved = first.read(codexHistoryProvider).requireValue;
        expect(saved.where(session.contains), hasLength(2));
        final reopened = await second.read(codexHistoryProvider.future);
        expect(reopened.map((e) => e.id), saved.map((e) => e.id));
        expect(reopened.last.id, old.last.id);
        expect(
          reopened.where(second.read(codexDrawSessionProvider).contains),
          isEmpty,
        );
        await second
            .read(codexHistoryProvider.notifier)
            .record(book, entry, now: 55);
        expect(
          second
              .read(codexHistoryProvider)
              .requireValue
              .where(second.read(codexDrawSessionProvider).contains),
          hasLength(1),
        );
        expect(second.read(codexHistoryProvider).requireValue, hasLength(4));
      } finally {
        first.dispose();
        second.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
        temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'no-repeat rounds respect active filters and reset independently',
    () async {
      final temp = Directory.systemTemp.createTempSync('plana_draw_rounds_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => temp.path,
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
        temp.deleteSync(recursive: true);
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final rounds = c.read(codexDrawRoundsProvider.notifier);
      final pool = [
        entry,
        const CodexEntry(id: 'a', title: 'A', tags: 'a'),
        const CodexEntry(id: 'b', title: 'B', tags: 'b'),
      ];
      Future<CodexEntry?> pick(
        String scope,
        List<CodexEntry> source,
        String? previous,
      ) async {
        final saved = await rounds.draw(
          book: book,
          scopeKey: scope,
          scopeLabel: scope,
          pool: source,
          previousId: previous,
        );
        return saved
            ? c.read(codexHistoryProvider).requireValue.first.entry
            : null;
      }

      String? previous;
      for (var cycle = 0; cycle < 3; cycle++) {
        final drawn = <String>{};
        for (var i = 0; i < pool.length; i++) {
          final id = (await pick('all', pool, previous))!.id;
          expect(id, isNot(previous));
          expect(drawn.add(id), isTrue);
          previous = id;
          expect(rounds.seenCount('all', pool), i + 1);
        }
      }
      final failedWrite = Directory(
        '${temp.path}/codex_random_history.json.tmp',
      )..createSync();
      expect(await pick('all', pool, previous), isNull);
      expect(rounds.seenCount('all', pool), pool.length);
      expect(rounds.saving, isFalse);
      failedWrite.deleteSync();
      expect(await pick('favorites', [entry], previous), entry);
      rounds.reshuffle('all');
      expect(rounds.seenCount('all', pool), 0);
      expect(rounds.seenCount('favorites', [entry]), 1);
      expect(rounds.seenCount('favorites', pool.skip(1).toList()), 0);
      rounds.toggle();
      expect(c.read(codexDrawRoundsProvider), isFalse);
      expect(await pick('all', [], null), isNull);
      expect(await pick('all', [entry], entry.id), entry);
      expect(await pick('all', [entry, entry], entry.id), entry);
      expect(rounds.seenCount('all', pool), 0);
    },
  );

  test(
    'batch deals commit once, keep the rest of the round, and never duplicate a card',
    () async {
      final temp = Directory.systemTemp.createTempSync('plana_deal_batch_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => temp.path,
      );
      final c = ProviderContainer();
      addTearDown(() {
        c.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
        temp.deleteSync(recursive: true);
      });
      final rounds = c.read(codexDrawRoundsProvider.notifier);
      final pool = [
        for (var i = 0; i < 5; i++)
          CodexEntry(id: 'item$i', title: '$i', tags: '$i'),
      ];
      Future<List<CodexDrawRecord>> deal(
        List<CodexEntry> eligible,
        int count,
      ) => rounds.deal(
        book: book,
        scopeKey: 'all',
        scopeLabel: 'all',
        pool: eligible,
        count: count,
      );
      final other = await deal([pool.last], 1);
      final pair = pool.take(2).toList();
      for (var i = 0; i < 3; i++) {
        final hand = await deal([...pair, pair.first], 3);
        expect(hand.map((r) => r.entry.id).toSet(), {
          pair.first.id,
          pair.last.id,
        });
        expect(rounds.seenCount('all', [pool.last]), 1);
        expect(rounds.seenCount('all', pool), 3);
      }
      final before = c
          .read(codexHistoryProvider)
          .requireValue
          .map((r) => r.id)
          .toList();
      expect(before.last, other.single.id);
      final blocker = Directory('${temp.path}/codex_random_history.json.tmp')
        ..createSync();
      expect(await deal(pool, 3), isEmpty);
      expect(
        c.read(codexHistoryProvider).requireValue.map((r) => r.id),
        before,
      );
      expect(rounds.seenCount('all', pool), 3);
      blocker.deleteSync();
      final across = await deal(pool, 3);
      expect(across.take(2).map((r) => r.entry.id).toSet(), {
        pool[2].id,
        pool[3].id,
      });
      expect(across.map((r) => r.entry.id).toSet(), hasLength(3));
      c.invalidate(codexHistoryProvider);
      expect(
        (await c.read(codexHistoryProvider.future)).take(3).map((r) => r.id),
        across.reversed.map((r) => r.id),
      );
      rounds.toggle();
      expect(
        (await deal(pair, 3)).map((r) => r.entry.id).toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'early concurrent draws persist newest first, including repeated results',
    () async {
      final temp = Directory.systemTemp.createTempSync('plana_codex_history_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => temp.path,
      );
      final container = ProviderContainer();
      try {
        final notifier = container.read(codexHistoryProvider.notifier);
        // No prior await of build(): recording must not discard the initial read.
        await Future.wait([
          notifier.record(book, entry, now: 1),
          notifier.record(
            book,
            const CodexEntry(id: 'two', title: '海岸', tags: 'sea'),
            now: 2,
          ),
          notifier.record(book, entry, now: 2),
        ]);
        expect(
          container.read(codexHistoryProvider).value!.map((e) => e.entry.id),
          ['entry', 'two', 'entry'],
        );
        container.invalidate(codexHistoryProvider);
        final restored = await container.read(codexHistoryProvider.future);
        expect(restored.map((e) => e.entry.id), ['entry', 'two', 'entry']);
        await container
            .read(codexHistoryProvider.notifier)
            .record(
              book,
              const CodexEntry(id: 'three', title: '花园', tags: 'flowers'),
              now: 3,
            );
        container.invalidate(codexHistoryProvider);
        expect(
          (await container.read(
            codexHistoryProvider.future,
          )).map((e) => e.entry.id),
          ['three', 'entry', 'two', 'entry'],
        );
        final history = container.read(codexHistoryProvider.notifier);
        final blockedTempFile = Directory(
          '${temp.path}/codex_random_history.json.tmp',
        )..createSync();
        expect(await history.clearAll(), isFalse);
        expect(container.read(codexHistoryProvider).value, hasLength(4));
        blockedTempFile.deleteSync();
        // A late save must not restore cleared records or discard subsequent draws.
        expect(
          await Future.wait([
            history.record(book, entry, now: 4),
            history.clearAll(),
            history.record(book, entry, now: 5),
          ]),
          [true, true, true],
        );
        container.invalidate(codexHistoryProvider);
        expect(
          (await container.read(codexHistoryProvider.future)).single.savedAt,
          5,
        );
      } finally {
        container.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
        temp.deleteSync(recursive: true);
      }
    },
  );
}
