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
    for (final block in blocks.where((b) => b.negative == negative)) {
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
      links.add(entry.value);
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
