import 'package:flutter/material.dart' show Icons, IconData;

import '../../../l10n/l10n.dart';
import 'agent_tool.dart';
import 'my_library.dart';
import 'tool_context.dart';

const kOcBlock = '[OC 角色]';
const _ocCopyNote =
    '原样导入指定的库内角色时，在对应的正向提示词中使用提供的占位符，客户端会还原整段原文和权重。新增动作、表情和场景写在占位符外。需要修改原设时可编辑原词，保留其余特征的原始权重。';

/// 使用角色库:用户 OC 库里的角色,按名字 / 别名关键词匹配。开着 OC 占位符时只给模型占位符。
class SearchOcTool extends AgentTool {
  const SearchOcTool();

  @override
  String get name => 'search_oc';

  @override
  String get label => l10nNow.toolSearchOc;

  @override
  IconData get icon => Icons.person_outline;

  @override
  List<ToolParam> get params => const [
    ToolParam('query', 'string', required: true),
  ];

  @override
  List<ToolOption> get options => [
    ToolOption(
      'placeholders',
      () => l10nNow.ocPlaceholder,
      () => l10nNow.ocPlaceholderDesc,
    ),
  ];

  @override
  Future<String> systemNote(ToolContext ctx) async =>
      ctx.settings.ocPlaceholders
      ? ctx.texts.get('oc_placeholder_mode')
      : _ocCopyNote;

  /// 原话里点到的 OC → [OC 角色] 块。OC 默认只活在点到它的那一轮;开着占位符时同画师串,
  /// 这轮没点到就补账本里记着的。
  @override
  Future<ToolBlock?> prefetch(ToolContext ctx) async {
    final placeholders = ctx.settings.ocPlaceholders;
    if (placeholders) {
      // 库里的 OC 都进映射:模型写了哪个占位符都认得出来
      for (final oc in ctx.ocs) {
        ctx.ocPlan.addOc(oc);
      }
    }
    final hits = matchOcs(ctx.userText, ctx.ocs);
    final shown = placeholders && hits.isEmpty
        ? [
            for (final e in (ctx.remembered['oc'] ?? const {}).entries)
              (e.key, e.value),
          ]
        : hits;
    final lines = [
      for (final (name, tags) in shown)
        if (name.isNotEmpty && tags.isNotEmpty) ...[
          '$name → ${ctx.ocPlan.add(name, tags)}',
          if (!placeholders) '参考原词：$tags',
        ],
    ];
    for (final e in (ctx.remembered['oc'] ?? const {}).entries) {
      ctx.ocPlan.add(e.key, e.value);
    }
    if (lines.isEmpty) return null;
    return ToolBlock(
      [
        kOcBlock,
        if (placeholders) ctx.texts.get('oc_block_note'),
        ...lines,
      ].join('\n'),
      resources: {
        'oc': {for (final (name, tags) in hits) name: tags},
      },
    );
  }

  @override
  Future<ToolOutcome> call(ToolContext ctx, Map<String, dynamic> args) async {
    final placeholders = ctx.settings.ocPlaceholders;
    final query = '${args['query'] ?? ''}';
    final entries = await ctx.searchOcLibrary?.call(query) ?? ctx.ocs;
    final found = searchOcs(entries, query);
    return ToolOutcome(
      [
        for (final oc in found)
          {
            'name': oc.label,
            'aliases': [
              for (final a in [oc.zhName, ...oc.aliases])
                if (a.isNotEmpty && a != oc.label) a,
            ],
            'tags': placeholders ? ctx.ocPlan.addOc(oc) : oc.tagGroup,
            if (!placeholders) 'placeholder': ctx.ocPlan.addOc(oc),
          },
      ],
      resources: {
        'oc': {for (final oc in found) oc.label: oc.tagGroup},
      },
    );
  }
}
