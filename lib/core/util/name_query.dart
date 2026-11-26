import 'package:unorm_dart/unorm_dart.dart' as unorm;

final _separators = RegExp(r'[\p{P}\s]+', unicode: true);

List<String> _words(String text) => unorm
    .nfkc(text)
    .toLowerCase()
    .split(_separators)
    .where((word) => word.isNotEmpty)
    .toList();

String normalizeName(String text) =>
    unorm.nfkc(text).toLowerCase().replaceAll(_separators, '');

/// The same query is reused for the index, individual cards and assistant tools.
class NameQuery {
  NameQuery(String text) : words = _words(text);
  final List<String> words;
  late final String compact = words.join();

  // Higher scores are more specific. Keep catalog order on ties.
  int score(Iterable<String> fields) {
    if (words.isEmpty) return 0;
    final normalized = fields
        .map(normalizeName)
        .where((s) => s.isNotEmpty)
        .toList();
    if (normalized.contains(compact)) return 4;
    if (normalized.any((s) => s.contains(compact))) return 3;
    if (words.length > 1 &&
        words.every((w) => normalized.any((s) => s.contains(w)))) {
      return 2;
    }
    // A name and a parenthesized form can also be entered without the separator.
    if (words.length == 1 &&
        fields.any((f) {
          final parts = _words(f);
          return parts.length == 2 && parts.reversed.join() == compact;
        })) {
      return 2;
    }
    return 0;
  }

  /// A conversational mention may contain other instructions around a name.
  int mentionLength(String name) {
    final parts = _words(name);
    if (parts.isEmpty) return 0;
    final joined = parts.join();
    if (compact.contains(joined) ||
        (parts.length > 1 && parts.every(compact.contains))) {
      return joined.runes.length;
    }
    return 0;
  }
}
