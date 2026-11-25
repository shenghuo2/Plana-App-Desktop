import '../editor/editor_models.dart';

/// A conversation remembers its own writes separately for each canvas.
class PromptImportBinding {
  const PromptImportBinding({this.sectionId, this.positive, this.negative});

  final String? sectionId;
  final ImportedPromptSpan? positive, negative;

  Map<String, dynamic> toJson() => {
    'sectionId': ?sectionId,
    'positive': ?positive?.toJson(),
    'negative': ?negative?.toJson(),
  };

  factory PromptImportBinding.fromJson(Map data) => PromptImportBinding(
    sectionId: data['sectionId'] is String ? data['sectionId'] : null,
    positive: ImportedPromptSpan.decode(data['positive']),
    negative: ImportedPromptSpan.decode(data['negative']),
  );
}

/// Offsets refer to editor text (including folds), never the generation payload.
class ImportedPromptSpan {
  const ImportedPromptSpan(this.start, this.raw, this.linkIds);
  final int start;
  final String raw;
  final List<String> linkIds;

  Map<String, dynamic> toJson() => {
    'start': start,
    'raw': raw,
    if (linkIds.isNotEmpty) 'links': linkIds,
  };

  static ImportedPromptSpan? decode(Object? data) {
    if (data case {
      'start': int start,
      'raw': String raw,
    } when start >= 0 && raw.isNotEmpty) {
      final ids = (data as Map)['links'];
      return ImportedPromptSpan(
        start,
        raw,
        ids is List ? ids.whereType<String>().toList() : const [],
      );
    }
    return null;
  }
}

/// The two untouched pieces around the place to write. An edited or ambiguous
/// range is never removed by offset alone. Intact fold links can still identify
/// the AI's individual blocks when the user has interleaved their own terms.
class PromptInsertSlot {
  const PromptInsertSlot(this.before, this.after, {this.replacing = false});
  final bool replacing;
  final String before, after;

  static final _leftBoundary = RegExp(r'(?:^|[,，\n])[ \t\r]*$');
  static final _rightBoundary = RegExp(r'^[ \t\r]*(?:$|[,，\n])');
  static final _leftSep = RegExp(r'[,，\n]\s*$');
  static final _rightSep = RegExp(r'^\s*[,，\n]\s*');

  factory PromptInsertSlot.locate(
    String text,
    ImportedPromptSpan? previous,
    List<PromptFoldLink> links, {
    required bool negative,
  }) {
    if (previous == null) return PromptInsertSlot(text, '');
    final ids = previous.linkIds.toSet();
    final names = {
      for (final link in links)
        if (ids.contains(link.id))
          negative ? link.negativeName : link.positiveName,
    }..remove('');
    final weights = <WeightSpan>[], folds = <FoldSpan>[];
    final tokens = parseToks(text, folds: folds, weightSpans: weights);
    bool cutsGroup(int a, int b) {
      bool cuts(int l, int r) => l < a && a < r || l < b && b < r;
      return folds.any((f) => cuts(f.start, f.end)) ||
          weights.any((w) => cuts(w.start, w.end)) ||
          tokens.any((t) => t.disabled && t.coreStart < b && a < t.coreEnd);
    }

    if (ids.isEmpty || names.isNotEmpty) {
      int? direct;
      for (final match in previous.raw.allMatches(text)) {
        if (!_leftBoundary.hasMatch(text.substring(0, match.start)) ||
            !_rightBoundary.hasMatch(text.substring(match.end)) ||
            cutsGroup(match.start, match.end)) {
          continue;
        }
        if (direct != null) {
          direct = null;
          break;
        }
        direct = match.start;
      }
      if (direct != null) {
        return PromptInsertSlot(
          text.substring(0, direct),
          text.substring(direct + previous.raw.length),
          replacing: true,
        );
      }
    }

    final ranges = [
      for (final f in folds)
        if (names.contains(f.name) && !cutsGroup(f.start, f.end))
          (f.start, f.end),
    ];
    // Interleaved, ungrouped user terms can also be preserved when all
    // former AI terms are still uniquely identifiable in their original order.
    if (ranges.isEmpty && ids.isEmpty && !_syntax.hasMatch(previous.raw)) {
      final old = previous.raw
          .split(RegExp(r'[,，]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (old.length > 1 && old.toSet().length == old.length) {
        final wanted = old.toSet();
        final matches = <String, List<(int, int)>>{};
        for (final token in tokens) {
          final word = text.substring(token.coreStart, token.coreEnd);
          if (wanted.contains(word) &&
              !cutsGroup(token.coreStart, token.coreEnd)) {
            (matches[word] ??= []).add((token.coreStart, token.coreEnd));
          }
        }
        var end = -1;
        for (final word in old) {
          final span = matches[word]?.singleOrNull;
          if (span == null ||
              span.$1 < end ||
              ranges.isEmpty && span.$1 != previous.start) {
            ranges.clear();
            break;
          }
          ranges.add(span);
          end = span.$2;
        }
      }
    }
    if (ranges.isEmpty) return PromptInsertSlot(text, '');
    var remainder = text;
    for (final (start, end) in ranges.skip(1).toList().reversed) {
      remainder = PromptFoldSlot(remainder, start, end).replace('');
    }
    final first = ranges.first;
    return PromptInsertSlot(
      remainder.substring(0, first.$1),
      remainder.substring(first.$2),
      replacing: true,
    );
  }

  static final _syntax = RegExp(r'[<>{}\[\]~:\n]');

  static String _join(String left, String right) {
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    if (_leftSep.hasMatch(left)) {
      return left + right.replaceFirst(_rightSep, '');
    }
    return _rightSep.hasMatch(right) ? left + right : '$left, $right';
  }

  String get remainder {
    if (!replacing) return before;
    if (after.isEmpty) return before.replaceFirst(_leftSep, '');
    if (before.isEmpty) return after.replaceFirst(_rightSep, '');
    return _join(before, after);
  }

  (String, ImportedPromptSpan?) insert(String body, List<String> linkIds) {
    if (body.isEmpty) return (remainder, null);
    final prefix = _join(before, body);
    return (
      _join(prefix, after),
      ImportedPromptSpan(prefix.length - body.length, body, linkIds),
    );
  }
}
