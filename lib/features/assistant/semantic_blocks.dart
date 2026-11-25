import '../../core/util/prompt_block.dart';
import '../editor/editor_models.dart';
import '../generate/models.dart';

/// Use the editor's weight ranges for both the proposal and the imported draft.
List<PromptBlock> completePromptBlocks(
  List<PromptBlock> blocks,
  Map<String, dynamic>? draw,
) {
  if (blocks.isEmpty || draw == null) return const [];
  final chars = draw['characters'];
  final ranges = <(int, bool), List<WeightSpan>>{};
  return blocks.where((b) {
    final owner = b.character == -1
        ? draw
        : chars is List && b.character >= 0 && b.character < chars.length
        ? chars[b.character]
        : null;
    if (owner is! Map) return false;
    final text = owner[b.negative ? 'negative' : 'positive'];
    if (text is! String ||
        b.start < 0 ||
        b.start > text.length ||
        !text.startsWith(b.text, b.start)) {
      return false;
    }
    final spans = ranges.putIfAbsent((
      b.character,
      b.negative,
    ), () => _weights(text));
    return !_crossesWeight(spans, b.start, b.start + b.text.length);
  }).toList();
}

List<WeightSpan> _weights(String text) {
  final spans = <WeightSpan>[];
  parseToks(text, weightSpans: spans);
  return spans;
}

bool _crossesWeight(List<WeightSpan> spans, int a, int b) =>
    spans.any((s) => s.start < a && a < s.end || s.start < b && b < s.end);

/// Locate the surviving contents of old folds in the actual revised text.
/// Both ungrouped terms and terms from other folds are ownership boundaries.
Map<PromptBlock, (int, String)> revisedNegativeSpans(
  String previous,
  Iterable<PromptBlock> previousBlocks,
  String revised, {
  bool libraryFallback = false,
}) {
  final blocks =
      previousBlocks.where((b) => b.character == -1 && b.negative).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  if (blocks.isEmpty || revised.isEmpty) return {};
  if (!libraryFallback && previous == revised) {
    return {for (final b in blocks) b: (b.start, b.text)};
  }
  final old = parseToks(previous);
  final weights = <WeightSpan>[];
  final next = parseToks(revised, weightSpans: weights);
  final owners = <PromptBlock?>[];
  final byName = <String, Set<PromptBlock?>>{};
  final occurrences = <String, int>{};
  var index = 0;
  for (final token in old) {
    while (index < blocks.length &&
        blocks[index].start + blocks[index].text.length <= token.nameStart) {
      index++;
    }
    final owner =
        index < blocks.length &&
            blocks[index].start <= token.nameStart &&
            token.nameEnd <= blocks[index].start + blocks[index].text.length
        ? blocks[index]
        : null;
    owners.add(owner);
    byName.putIfAbsent(token.name, () => {}).add(owner);
    occurrences.update(token.name, (n) => n + 1, ifAbsent: () => 1);
  }
  // Shared terms in an unchanged prefix/suffix keep their positional owner.
  // Inside an edit, use only names attributable to a single original owner.
  var prefix = 0;
  while (!libraryFallback &&
      prefix < old.length &&
      prefix < next.length &&
      old[prefix].name == next[prefix].name) {
    prefix++;
  }
  var tail = next.length, oldTail = old.length;
  while (!libraryFallback &&
      tail > prefix &&
      oldTail > prefix &&
      old[oldTail - 1].name == next[tail - 1].name) {
    tail--;
    oldTail--;
  }
  final nextCounts = <String, int>{};
  for (final t in next) {
    nextCounts.update(t.name, (n) => n + 1, ifAbsent: () => 1);
  }
  final indices = <PromptBlock, List<int>>{};
  for (var i = 0; i < next.length; i++) {
    final key = next[i].name;
    final owner = i < prefix
        ? owners[i]
        : i >= tail
        ? owners[oldTail + i - tail]
        : nextCounts[key] == occurrences[key]
        ? byName[key]?.singleOrNull
        : null;
    if (owner != null) indices.putIfAbsent(owner, () => []).add(i);
  }
  final result = <PromptBlock, (int, String)>{};
  for (final entry in indices.entries) {
    final hits = entry.value;
    final first = hits.first, last = hits.last;
    // For legacy proposals without recorded ownership, require multiple
    // distinct library terms in one uninterrupted run.
    if (libraryFallback &&
        (hits.length != last - first + 1 ||
            hits.map((i) => next[i].name).toSet().length < 2)) {
      continue;
    }
    // New terms between two surviving anchors belong to the edited block.
    // A known but unassigned term (shared, duplicated or bare) is ambiguous.
    if (next
            .getRange(first, last + 1)
            .where((t) => byName.containsKey(t.name))
            .length !=
        hits.length) {
      continue;
    }
    final left = next[first], right = next[last];
    var start = left.segStart, end = right.segEnd;
    for (final w in weights) {
      if (w.start < start && left.nameStart < w.end) start = w.start;
      if (w.end > end && w.start < right.nameEnd) end = w.end;
    }
    if ((first > 0 && next[first - 1].nameEnd > start) ||
        (last + 1 < next.length && next[last + 1].nameStart < end)) {
      continue;
    }
    result[entry.key] = (start, revised.substring(start, end));
  }
  return result;
}

/// Decorate the selected row before it is placed at its actual destination.
PromptSection decorateProposalRow(
  PromptSection row,
  Iterable<PromptBlock> blocks,
  String Function(String, bool) retained,
  Set<String> reserved,
  String Function() newId,
) {
  if (blocks.isEmpty) return row;
  final draft = _blockDraft(
    row.positive,
    row.negative,
    row.positiveRaw,
    row.negativeRaw,
    row.foldLinks,
    blocks,
    newId,
    retained: (b) => retained(b.text, b.negative),
    reserved: reserved,
  );
  return row.copyWith(
    positiveRaw: draft.pos,
    negativeRaw: draft.neg,
    foldLinks: draft.links,
  );
}

List<CharacterPrompt> decorateProposalCharacters(
  List<CharacterPrompt> characters,
  List<PromptBlock> blocks,
  String Function() newId,
) {
  if (blocks.isEmpty) return characters;
  final result = [...characters];
  for (final (index, c) in characters.indexed) {
    final owned = blocks.where((b) => b.character == index);
    if (owned.isEmpty) continue;
    final draft = _blockDraft(
      c.positive,
      c.negative,
      c.positiveRaw,
      c.negativeRaw,
      c.foldLinks,
      owned,
      newId,
    );
    result[index] = c.copyWith(
      positiveRaw: draft.pos,
      negativeRaw: draft.neg,
      foldLinks: draft.links,
    );
  }
  return result;
}

({String pos, String neg, List<PromptFoldLink> links}) _blockDraft(
  String positive,
  String negative,
  String oldPos,
  String oldNeg,
  List<PromptFoldLink> previous,
  Iterable<PromptBlock> blocks,
  String Function() newId, {
  String Function(PromptBlock)? retained,
  Set<String> reserved = const {},
}) {
  final placed = <PromptBlock, PromptFoldLink>{};
  final taken = {
    ...reserved,
    for (final s in [oldPos, oldNeg])
      for (final f in parseFolds(s)) f.name,
  };
  String wrap(String text, String oldRaw, bool negative) {
    if (oldRaw.isNotEmpty &&
        oldRaw != text &&
        pickEditorText(oldRaw, text) == oldRaw) {
      return oldRaw;
    }
    final weights = _weights(text);
    final pieces = StringBuffer();
    final added = <PromptBlock, PromptFoldLink>{};
    var cursor = 0;
    final side = blocks.where((b) => b.negative == negative).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    for (final block in side) {
      final body = retained?.call(block) ?? block.text;
      if (body.isEmpty || body.contains('<#') || body.contains(kFoldClose)) {
        continue;
      }
      var a = block.start;
      if (a < cursor || a > text.length || !text.startsWith(body, a)) {
        a = text.indexOf(body, cursor);
        if (a < 0 || text.indexOf(body, a + 1) >= 0) continue;
      }
      final end = a + body.length;
      if (_crossesWeight(weights, a, end)) continue;
      final base = sanitizeFoldName(
        negative && block.counterpartIn(blocks) != null
            ? '${block.foldTitle}·排除'
            : block.foldTitle,
      );
      var name = base;
      for (var n = 2; taken.contains(name); n++) {
        name = '$base $n';
      }
      taken.add(name);
      pieces.write(text.substring(cursor, a));
      pieces.write('<#$name: $body$kFoldClose');
      added[block] = PromptFoldLink(
        id: newId(),
        temporaryCategory: block.kind.libraryId,
        temporaryIcon: block.icon ?? block.counterpartIn(blocks)?.icon,
        positiveName: negative ? '' : name,
        positiveBody: negative ? '' : body,
        negativeName: negative ? name : '',
        negativeBody: negative ? body : '',
      );
      cursor = end;
    }
    if (added.isEmpty) return oldRaw;
    pieces.write(text.substring(cursor));
    final raw = pieces.toString();
    if (outputOf(raw) != text || parseFolds(raw).length != added.length) {
      return oldRaw;
    }
    placed.addAll(added);
    return raw;
  }

  final pos = wrap(positive, oldPos, false);
  final neg = wrap(negative, oldNeg, true);
  final links = [...previous];
  for (final entry in placed.entries) {
    final partner = placed[entry.key.counterpartIn(blocks)];
    if (partner == null) {
      // In replace-main mode one side may already be an intact editor draft.
      // Reconnect its original link when only the other side was rewritten.
      final block = entry.key;
      final other = block.counterpartIn(blocks);
      final base = sanitizeFoldName(
        block.negative ? block.foldTitle : '${block.foldTitle}·排除',
      );
      final kept = previous.where((link) {
        if (link.paired || link.temporaryCategory != block.kind.libraryId) {
          return false;
        }
        final name = block.negative ? link.positiveName : link.negativeName;
        final body = block.negative ? link.positiveBody : link.negativeBody;
        return (name == base ||
                name.replaceFirst(RegExp(r' \d+$'), '') == base) &&
            (other == null || body == (retained?.call(other) ?? other.text));
      }).singleOrNull;
      final fresh = entry.value;
      if (kept == null || !links.remove(kept)) {
        links.add(fresh);
      } else {
        links.add(
          block.negative
              ? kept.copyWith(
                  negativeName: fresh.negativeName,
                  negativeBody: fresh.negativeBody,
                )
              : kept.copyWith(
                  positiveName: fresh.positiveName,
                  positiveBody: fresh.positiveBody,
                ),
        );
      }
    } else if (!entry.key.negative) {
      links.add(
        entry.value.copyWith(
          negativeName: partner.negativeName,
          negativeBody: partner.negativeBody,
        ),
      );
    }
  }
  return (pos: pos, neg: neg, links: links);
}
