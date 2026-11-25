import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'codex_history.dart';
import 'codex_models.dart';

/// Both desktop entry points deal from the same rounds for this app session.
final codexDrawRoundsProvider = NotifierProvider<CodexDrawRounds, bool>(
  CodexDrawRounds.new,
);

class CodexDrawRounds extends Notifier<bool> {
  final _seen = <String, Set<String>>{};
  final _random = Random();

  @override
  bool build() => true;

  void toggle() => state = !state;

  int seenCount(String scope, List<CodexEntry> pool) {
    final seen = _seen[scope];
    return seen == null
        ? 0
        : pool.where((entry) => seen.contains(entry.id)).length;
  }

  void reshuffle(String scope) {
    if (state && _seen.remove(scope) != null) ref.notifyListeners();
  }

  bool _saving = false;
  bool get saving => _saving;

  Future<bool> draw({
    required CodexMeta book,
    required String scopeKey,
    required String scopeLabel,
    required List<CodexEntry> pool,
    String? previousId,
  }) async => (await deal(
    book: book,
    scopeKey: scopeKey,
    scopeLabel: scopeLabel,
    pool: pool,
    previousId: previousId,
  )).isNotEmpty;

  /// The pool may be a subset of the selected scope for a contextual draw.
  /// Commit the entire hand and the round together after history reaches disk.
  Future<List<CodexDrawRecord>> deal({
    required CodexMeta book,
    required String scopeKey,
    required String scopeLabel,
    required List<CodexEntry> pool,
    int count = 1,
    String? previousId,
  }) async {
    if (_saving || count < 1 || pool.isEmpty) return const [];
    final available = {for (final entry in pool) entry.id: entry};
    final tracked = state
        ? _seen.putIfAbsent(scopeKey, () => <String>{})
        : null;
    final seen = {...?tracked};
    final picked = <String>{};
    final draws = <CodexDrawRecord>[];
    final session = ref.read(codexDrawSessionProvider);
    while (picked.length < min(count, available.length)) {
      final remaining = available.keys.where((id) => !picked.contains(id));
      var choices = remaining.where((id) => !seen.contains(id)).toList();
      if (choices.isEmpty) {
        // Finishing a subcategory does not reset the rest of the deck.
        seen.removeAll(available.keys);
        choices = remaining.toList();
      }
      if (picked.isEmpty && choices.length > 1) choices.remove(previousId);
      final id = choices[_random.nextInt(choices.length)];
      picked.add(id);
      if (tracked != null) seen.add(id);
      draws.add(session.create(book, available[id]!, scope: scopeLabel));
    }
    _saving = true;
    ref.notifyListeners();
    try {
      if (!await ref.read(codexHistoryProvider.notifier).saveDraws(draws)) {
        return const [];
      }
      if (ref.mounted) {
        if (tracked != null && identical(tracked, _seen[scopeKey])) {
          _seen[scopeKey] = seen;
        }
        ref.read(codexSelectedDrawProvider.notifier).select(draws.last);
      }
      return draws;
    } finally {
      _saving = false;
      if (ref.mounted) ref.notifyListeners();
    }
  }
}

final codexSelectedDrawProvider = NotifierProvider<CodexSelectedDraw, String?>(
  CodexSelectedDraw.new,
);

class CodexSelectedDraw extends Notifier<String?> {
  @override
  String? build() => null;
  void select(CodexDrawRecord record) => state = record.id;
}
