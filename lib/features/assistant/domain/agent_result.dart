import '../../../core/net/backend_client.dart' show AgentCharacter, AgentResult;
import '../../../core/util/prompt_block.dart';
import '../semantic_blocks.dart' show completePromptBlocks;

export '../../../core/net/backend_client.dart' show AgentResult, AgentCharacter;

AgentResult agentResultFromDraw(
  String reply,
  Map<String, dynamic>? draw, {
  List<PromptBlock> blocks = const [],
  Map<String, Map<String, String>> resources = const {},
  String reasoning = '',
}) {
  final d = draw ?? const <String, dynamic>{};
  return AgentResult(
    replyText: reply,
    reasoning: reasoning,
    section: assistantSectionName(d['section']),
    blocks: completePromptBlocks(blocks, draw),
    positive: d['positive']?.toString() ?? '',
    negative: d['negative']?.toString() ?? '',
    specifiedNegative: d['negative'] is String,
    characters: [
      for (final c in (d['characters'] as List? ?? const []))
        if (c is Map<String, dynamic>) AgentCharacter.fromJson(c),
    ],
    resources: resources,
  );
}
