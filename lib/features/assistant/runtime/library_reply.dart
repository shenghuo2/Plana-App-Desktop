import '../../../core/util/prompt_block.dart';
import '../agent_trace.dart';
import '../assistant_models.dart' show stripArtistMarkers;
import '../domain/agent_result.dart';
import '../protocol/reply_parser.dart';
import '../tools/tool_context.dart';
import 'ledger.dart';
import 'placeholders.dart';

/// Older servers perform their own lookups and may wrap an expanded artist
/// in display markup. Calculate offsets on the same text the editor will use.
AgentResult legacyLibraryReply(
  Map<String, dynamic> wire,
  ToolContext context,
  Map<String, Map<String, String>> matches, {
  required bool useBlocks,
}) {
  final remote = AgentResult.fromJson(wire, recoverBlocks: useBlocks);
  String expand(String text) =>
      expandOcText(stripArtistMarkers(text), context.ocPlan);
  var changed = false;
  final draw = mapDrawTexts(wire, (value) {
    final text = expand('$value');
    if (value != text) changed = true;
    return text;
  });
  final resources = {
    for (final entry in remote.resources.entries)
      entry.key: {
        for (final e in entry.value.entries)
          e.key: expandOcText(e.value, context.ocPlan),
      },
  };
  final parts = {
    for (final kind in ['artist', 'oc'])
      kind: {
        ...?context.remembered[kind],
        ...?resources[kind],
        ...?matches[kind],
        if (kind == 'oc') ..._referenced(wire, ocTokenRe, context.ocPlan.get),
      },
  };
  var blocks = remote.blocks;
  if (!useBlocks) {
    blocks = PromptBlock.fromLibraryParts(
      draw,
      parts,
      insertedCopies: _insertedCopies(wire, context.ocPlan),
    );
  } else if (changed) {
    final saved = PromptBlock.decode(wire['promptBlocks']);
    blocks = saved.isEmpty
        ? PromptBlock.fromDraw(wire, draw, expand, recoverWith: parts)
        : _expandedSpans(wire, saved, expand);
  }
  return agentResultFromDraw(
    namesInOcReply(remote.replyText, context.ocPlan),
    draw,
    reasoning: remote.reasoning,
    resources: resources,
    blocks: blocks,
  );
}

/// Saved server annotations use offsets before token expansion. Translate
/// each prefix and body in its own field, then validate on the final draw.
List<PromptBlock> _expandedSpans(
  Map<String, dynamic> wire,
  List<PromptBlock> saved,
  String Function(String) expand,
) {
  final chars = wire['characters'];
  final result = <PromptBlock>[];
  for (final block in saved) {
    final owner = block.character < 0
        ? wire
        : chars is List && block.character < chars.length
        ? chars[block.character]
        : null;
    if (owner is! Map) continue;
    final source = owner[block.negative ? 'negative' : 'positive'];
    if (source is! String ||
        block.start > source.length ||
        !source.startsWith(block.text, block.start)) {
      continue;
    }
    final body = expand(block.text);
    if (body.isNotEmpty) {
      result.add(
        block.atSpan(expand(source.substring(0, block.start)).length, body),
      );
    }
  }
  return result;
}

Map<String, String> _referenced(
  Map<String, dynamic>? source,
  RegExp pattern,
  ArtistResolver lookup,
) => {
  if (source != null)
    for (final text in drawTexts(source))
      for (final token in pattern.allMatches(text))
        if (lookup(token[1]!) case final hit?) hit.name: hit.content,
};

// Legacy NAI 5 presets sometimes place an OC token inside a sentence.
// Only a token we actually expanded can own an inline span in that field.
Map<int, Set<String>> _insertedCopies(
  Map<String, dynamic>? source,
  OcPlan ocs, [
  ArtistResolver? artist,
]) {
  if (source == null) return const {};
  Set<String> inField(Object? text) => {
    if (text is String)
      for (final (pattern, lookup) in [
        (ocTokenRe, ocs.get),
        if (artist != null) (artistTokenRe, artist),
      ])
        for (final token in pattern.allMatches(text))
          if (lookup(token[1]!) case final hit?)
            if (!text.contains(hit.content)) hit.content,
  };
  final chars = source['characters'];
  return {
    -1: inField(source['positive']),
    if (chars is List)
      for (final (i, c) in chars.indexed)
        if (c is Map) i: inField(c['positive']),
  };
}

/// Expand library references before calculating semantic block offsets.
AgentResult libraryReply(
  ParsedReply parsed,
  ToolContext context,
  Map<String, Map<String, String>> matches, {
  required bool useBlocks,
  AgentTrace? trace,
}) {
  final resolve = artistResolver(context.artistPlan, context.artists);
  // Previous proposals can contain an alias from an older client.
  final source = parsed.draw;
  if (source != null &&
      context.settings.toolOn('search_oc') &&
      drawTexts(source).any(ocTokenRe.hasMatch)) {
    for (final oc in context.ocs) {
      context.ocPlan.addOc(oc);
    }
  }
  final draw = expandOcDraw(expandDraw(parsed.draw, resolve), context.ocPlan);
  final reply = namesInOcReply(
    namesInReply(parsed.reply, resolve),
    context.ocPlan,
  );
  // A model can reuse a token from the canvas without a lookup this turn.
  final used = {
    for (final (kind, pattern, lookup) in [
      ('artist', artistTokenRe, resolve),
      ('oc', ocTokenRe, context.ocPlan.get),
    ])
      kind: {...?matches[kind], ..._referenced(parsed.draw, pattern, lookup)},
  };
  final ledger = mergeLedger(
    context.remembered,
    used,
    draw,
    rememberOcs: context.settings.ocPlaceholders,
  );
  trace?.event('final', {
    'reply': reply,
    'draw': parsed.draw,
    if (draw != parsed.draw) 'draw_expanded': draw,
    'resources': ledger,
    if (parsed.repairs.isNotEmpty) 'repairs': parsed.repairs,
  });
  final parts = {
    ...ledger,
    'oc': {...?context.remembered['oc'], ...?used['oc']},
  };
  final blocks = useBlocks
      ? PromptBlock.fromDraw(parsed.draw, draw, (line) {
          final text = expandArtistText(line, resolve).text;
          return expandOcText(text, context.ocPlan);
        }, recoverWith: parts)
      : PromptBlock.fromLibraryParts(
          draw,
          parts,
          insertedCopies: _insertedCopies(source, context.ocPlan, resolve),
        );
  return agentResultFromDraw(reply, draw, resources: ledger, blocks: blocks);
}
