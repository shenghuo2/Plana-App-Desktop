import 'dart:convert';
import 'dart:io';

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
  });
  final CodexMeta codex;
  final CodexEntry entry;
  final int savedAt;

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
  };

  static CodexDrawRecord? fromJson(Object? value) {
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
      );
    } catch (_) {
      return null;
    }
  }
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
    return [for (final row in json) ?CodexDrawRecord.fromJson(row)];
  }

  Future<void> record(CodexMeta codex, CodexEntry entry, {int? now}) {
    final draw = CodexDrawRecord(
      codex: codex,
      entry: entry,
      savedAt: now ?? DateTime.now().millisecondsSinceEpoch,
    );
    // Wait for the initial read and serialize writes, including fast rerolls.
    return _pending = _pending.then((_) async {
      try {
        final current = await future;
        if (!ref.mounted) return;
        final next = [draw, ...current];
        state = AsyncData(next);
        await writeStringAtomic(
          await _file(),
          jsonEncode([for (final item in next) item.toJson()]),
        );
      } catch (error) {
        logd('[codex] 抽取历史保存失败: $error');
      }
    });
  }
}
