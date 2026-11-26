import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/store/atomic_file.dart';
import '../../../core/util/log.dart';
import 'codex_models.dart';

/// Snapshots keep past draws available without loading every source book.
class CodexDrawRecord {
  const CodexDrawRecord({
    required this.codex,
    required this.entry,
    required this.savedAt,
    this.id = '',
    this.scope,
  });
  final CodexMeta codex;
  final CodexEntry entry;
  final int savedAt;
  final String id;
  final String? scope;

  Map<String, dynamic> toJson() => {
    'codex': {
      'id': codex.id,
      'type': codex.type.name,
      'title': codex.title,
      'version': codex.version,
      'nsfw': codex.nsfw,
      'assetBaseUrl': codex.assetBaseUrl,
      'assetPathMode': codex.assetPathMode,
    },
    'entry': entry.toJson(),
    'savedAt': savedAt,
    if (id.isNotEmpty) 'id': id,
    if (scope != null) 'scope': scope,
  };

  static CodexDrawRecord? fromJson(Object? value, {String fallbackId = ''}) {
    if (value is! Map ||
        value['codex'] is! Map<String, dynamic> ||
        value['entry'] is! Map<String, dynamic> ||
        value['savedAt'] is! num) {
      return null;
    }
    try {
      final codex = CodexMeta.fromJson(value['codex'] as Map<String, dynamic>);
      final entry = CodexEntry.fromJson(value['entry'] as Map<String, dynamic>);
      if (codex.id.isEmpty || entry.id.isEmpty) return null;
      return CodexDrawRecord(
        codex: codex,
        entry: entry,
        savedAt: (value['savedAt'] as num).toInt(),
        id: value['id'] is String && (value['id'] as String).isNotEmpty
            ? value['id'] as String
            : fallbackId,
        scope: value['scope'] is String ? value['scope'] as String : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// New for each app run and shared by the main catalog and the creation sidebar.
final codexDrawSessionProvider = Provider((ref) => CodexDrawSession());

class CodexDrawSession {
  final _prefix =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}/';
  int _sequence = 0;

  bool contains(CodexDrawRecord record) => record.id.startsWith(_prefix);

  CodexDrawRecord create(
    CodexMeta book,
    CodexEntry entry, {
    String? scope,
    int? now,
  }) => CodexDrawRecord(
    id: '$_prefix${_sequence++}',
    codex: book,
    entry: entry,
    scope: scope,
    savedAt: now ?? DateTime.now().millisecondsSinceEpoch,
  );
}

final codexHistoryProvider =
    AsyncNotifierProvider<CodexHistoryNotifier, List<CodexDrawRecord>>(
      CodexHistoryNotifier.new,
    );

class CodexHistoryNotifier extends AsyncNotifier<List<CodexDrawRecord>> {
  Future<void> _pending = Future.value();
  Future<void> flush() => _pending;
  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}/codex_random_history.json',
  );

  @override
  Future<List<CodexDrawRecord>> build() async {
    final file = await _file();
    if (!await file.exists()) return const [];
    final json = jsonDecode(await file.readAsString());
    if (json is! List) throw const FormatException('抽取历史格式无效');
    // File order is draw order, including duplicates and equal timestamps.
    return [
      for (var i = 0; i < json.length; i++)
        ?CodexDrawRecord.fromJson(json[i], fallbackId: 'legacy-$i'),
    ];
  }

  Future<bool> record(CodexMeta codex, CodexEntry entry, {int? now}) =>
      saveDraw(
        ref.read(codexDrawSessionProvider).create(codex, entry, now: now),
      );

  Future<bool> saveDraw(CodexDrawRecord draw) => saveDraws([draw]);

  Future<bool> saveDraws(List<CodexDrawRecord> draws) =>
      _update((current) => [...draws.reversed, ...current]);

  Future<bool> remove(String id) => _update(
    (current) => [
      for (final r in current)
        if (r.id != id) r,
    ],
  );

  Future<bool> clearAll() => _update((_) => const []);

  // Apply draws and clears in click order, publishing only a saved list.
  Future<bool> _update(
    List<CodexDrawRecord> Function(List<CodexDrawRecord>) change,
  ) {
    final saved = _pending.then((_) async {
      try {
        final current = await future;
        if (!ref.mounted) return false;
        final next = change(current);
        await writeStringAtomic(
          await _file(),
          jsonEncode([for (final item in next) item.toJson()]),
        );
        if (ref.mounted) state = AsyncData(next);
        return true;
      } catch (error) {
        logd('[codex] 抽取历史保存失败: $error');
        return false;
      }
    });
    _pending = saved.then<void>((_) {});
    return saved;
  }
}
