import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/codex/codex_history.dart';
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
