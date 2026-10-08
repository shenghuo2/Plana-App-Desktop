import '../../core/util/prompt_tokens.dart' show cleanPromptToken, tokenizeSet;
import '../editor/editor_models.dart'
    show
        PromptFoldLink,
        draftOf,
        outputOf,
        pickEditorText,
        parseFolds,
        parseToks,
        deleteTok,
        validPromptFoldLinks;
import '../inspiration/tag_models.dart' show TagCategory, TagEntry;
import 'models.dart';

/// 主提示词分区的纯函数:拼接、计数口径、列表整理。状态写入在 GenerateNotifier
/// 与 CanvasWorkspaceNotifier.updatePrompts。

/// 分区头尾的空白与逗号:拼接时去掉,免得出现 `a,, b`。
String _clean(String s) =>
    s.trim().replaceAll(RegExp(r'^[,，\s]+|[,，\s]+$'), '');

/// 按行序把主体和启用的分区拼成一整串。[main] 是主体那一侧的词(正或负)。
///
/// 前面几格已经有的普通词,后面的格子里不再重复 —— 画风条目自带的负面常和
/// 主体负面撞(lowres、blurry),以前追加进同一串时就是去重的。
String joinSections(
  List<PromptSection> sections,
  String main, {
  required bool positive,
}) {
  if (sections.isEmpty) return main;
  final seen = <String>{};
  return [
    for (final s in sections)
      if (s.isMain || s.enabled)
        _dropSeen(
          _clean(s.isMain ? main : (positive ? s.positive : s.negative)),
          seen,
        ),
  ].where((p) => p.isNotEmpty).join(', ');
}

/// 带记号(权重、折叠、禁用、换行)的词不参与去重:拆开比对会拆坏它们。
final _syntax = RegExp(r'[{}\[\]:~<>#|\n]');

/// 去掉 [text] 里 [seen] 已有的普通词,再把这一格的普通词记进 [seen]。
/// 同一格里自己重复的照原样留着。
String _dropSeen(String text, Set<String> seen) {
  if (text.isEmpty) return text;
  final own = <String>{};
  final kept = <String>[];
  for (final piece in text.split(RegExp(r'[,，]'))) {
    final key = _syntax.hasMatch(piece) ? '' : cleanPromptToken(piece);
    if (key.isNotEmpty) {
      if (seen.contains(key)) continue;
      own.add(key);
    }
    kept.add(piece);
  }
  seen.addAll(own);
  return _clean(kept.join(','));
}

/// Compose raw drafts as well as their paired-fold provenance. Fold names and
/// link IDs are local to an editor, so separate sections may reuse both.
(String, String, List<PromptFoldLink>) _composeDrafts(GenerateState state) {
  final parts = [
    for (final section in state.sections)
      if (section.isMain || section.enabled)
        (
          positive: pickEditorText(
            section.isMain ? state.promptRaw : section.positiveRaw,
            section.isMain ? state.prompt : section.positive,
          ),
          negative: pickEditorText(
            section.isMain ? state.negativePromptRaw : section.negativeRaw,
            section.isMain ? state.negativePrompt : section.negative,
          ),
          links: section.isMain ? state.promptFoldLinks : section.foldLinks,
        ),
  ];
  final reservedPos = {
    for (final p in parts)
      for (final f in parseFolds(p.positive)) f.name,
  };
  final reservedNeg = {
    for (final p in parts)
      for (final f in parseFolds(p.negative)) f.name,
  };
  final usedPos = <String>{}, usedNeg = <String>{}, ids = <String>{};
  final seenPos = <String>{}, seenNeg = <String>{};
  final positives = <String>[], negatives = <String>[];
  final links = <PromptFoldLink>[];
  for (final part in parts) {
    final valid = validPromptFoldLinks(
      part.positive,
      part.negative,
      part.links,
    );
    final (positive, posNames) = _uniqueFoldNames(
      part.positive,
      usedPos,
      reservedPos,
    );
    final (negative, negNames) = _uniqueFoldNames(
      part.negative,
      usedNeg,
      reservedNeg,
    );
    final pos = _dropSeenDraft(positive, seenPos);
    final neg = _dropSeenDraft(negative, seenNeg);
    if (_clean(pos).isNotEmpty) positives.add(_clean(pos));
    if (_clean(neg).isNotEmpty) negatives.add(_clean(neg));
    final posFolds = parseFolds(pos), negFolds = parseFolds(neg);
    for (final link in valid) {
      final pn = posNames[link.positiveName]!,
          nn = negNames[link.negativeName]!;
      final pf = posFolds.where((f) => f.name == pn).firstOrNull;
      final nf = negFolds.where((f) => f.name == nn).firstOrNull;
      if (pf == null || nf == null) continue;
      var id = link.id;
      for (var suffix = 2; !ids.add(id); suffix++) {
        id = '${link.id}:$suffix';
      }
      links.add(
        PromptFoldLink(
          id: id,
          positiveName: pn,
          positiveBody: pos.substring(pf.bodyStart, pf.bodyEnd).trim(),
          negativeName: nn,
          negativeBody: neg.substring(nf.bodyStart, nf.bodyEnd).trim(),
        ),
      );
    }
  }
  return (positives.join(', '), negatives.join(', '), links);
}

(String, Map<String, String>) _uniqueFoldNames(
  String raw,
  Set<String> used,
  Set<String> reserved,
) {
  final names = <String, String>{};
  final edits = <(int, int, String)>[];
  for (final fold in parseFolds(raw)) {
    var name = fold.name;
    if (used.contains(name)) {
      for (var suffix = 2; ; suffix++) {
        name = '${fold.name} · $suffix';
        if (!used.contains(name) && !reserved.contains(name)) break;
      }
    }
    used.add(name);
    names[fold.name] = name;
    if (name != fold.name) edits.add((fold.nameStart, fold.nameEnd, name));
  }
  for (final (start, end, name) in edits.reversed) {
    raw = raw.replaceRange(start, end, name);
  }
  return (raw, names);
}

/// Remove the same ordinary duplicates as joinSections, preserving disabled
/// tokens, weights and fold structure. Unusual syntax falls back per section.
String _dropSeenDraft(String raw, Set<String> seen) {
  final previous = {...seen};
  final expected = _dropSeen(_clean(outputOf(raw)), seen);
  var draft = raw;
  final tokens = parseToks(draft);
  for (final original in tokens.reversed) {
    if (original.disabled || original.groupMult != 1) continue;
    final piece = draft.substring(original.coreStart, original.coreEnd);
    if (_syntax.hasMatch(piece) ||
        !previous.contains(cleanPromptToken(piece))) {
      continue;
    }
    draft = deleteTok(draft, original).$1;
  }
  return _clean(outputOf(draft)) == expected ? draft : expected;
}

/// 生成快照:分区拼进主提示词,快照里不再带分区。
///
/// 入库、「重新生成」、图库搜索、图片元数据都按这一整串走,和发给 NAI 的一致;
/// 草稿也照样拼一份,导回创作页时折叠还在。没有分区原样返回。
GenerateState composeSections(GenerateState s) {
  if (s.sections.isEmpty) return s;
  final pos = joinSections(s.sections, s.prompt, positive: true);
  final neg = joinSections(s.sections, s.negativePrompt, positive: false);
  final (posDraft, negDraft, links) = _composeDrafts(s);
  // 跨格去重删过词时草稿对不上定稿,不带(读取侧也会这么判,这里先省一份)
  String draft(String d, String out) =>
      outputOf(d) == out ? draftOf(d, out) : '';
  return s.copyWith(
    prompt: pos,
    negativePrompt: neg,
    promptRaw: draft(posDraft, pos),
    negativePromptRaw: draft(negDraft, neg),
    promptFoldLinks: validPromptFoldLinks(
      draft(posDraft, pos),
      draft(negDraft, neg),
      links,
    ),
    sections: const [],
  );
}

/// token 读数要算进去的分区词(启用、不含主体),[except] 那一格除外
/// (编辑器里正开着它,读数用编辑器里的实时文本)。
List<String> sectionTexts(
  List<PromptSection> sections, {
  required bool positive,
  String? except,
}) => [
  for (final s in sections)
    if (!s.isMain && s.enabled && s.id != except)
      positive ? s.positive : s.negative,
];

/// 有分区时恰好一个主体;只剩主体(或什么都没有)就整列清空,卡片回到原来的样子。
List<PromptSection> normalizeSections(List<PromptSection> list) {
  if (!list.any((s) => !s.isMain)) return const [];
  final out = <PromptSection>[];
  var hasMain = false;
  for (final s in list) {
    if (s.isMain) {
      if (hasMain) continue;
      hasMain = true;
    }
    out.add(s);
  }
  if (!hasMain) out.insert(0, const PromptSection.main());
  return out;
}

/// 新画布沿用的骨架:名字、顺序、开关留着,词清空。
List<PromptSection> sectionSkeleton(List<PromptSection> list) => [
  for (final s in list)
    s.isMain
        ? s
        : PromptSection(
            id: s.id,
            name: s.name,
            enabled: s.enabled,
            artist: s.artist,
          ),
];

/// 新分区的默认名「分区 N」,N 取第一个没被占用的序号。
String nextSectionName(List<PromptSection> list) {
  final used = {for (final s in list) s.name};
  var n = 1;
  while (used.contains('分区 $n')) {
    n++;
  }
  return '分区 $n';
}

/// 删掉的分区放回原位。删的是最后一格时主体也跟着没了,[main] 是当时的主体。
List<PromptSection> restoreSection(
  List<PromptSection> list,
  PromptSection removed,
  int index, {
  PromptSection main = const PromptSection.main(),
}) {
  final out = list.isEmpty ? [main] : [...list];
  out.insert(index.clamp(0, out.length), removed);
  return normalizeSections(out);
}

/// 灵感库条目各自成一格,不折叠:名字取条目名(调用方换成分类名),正负向原样
/// 放进这一格。新格子一律接在最后,按加进来的先后往下排 —— 别按分类插到
/// 主体前后,那样主体看着像在跳。
///
/// 去重同以前追加时:词已经全在提示词里的跳过;同名同词的格子已经在
/// (多半是停用了)就打开它,不另建。没分区时连主体一起建出来。
List<PromptSection> withEntrySections(
  List<PromptSection> list,
  String mainPrompt,
  Iterable<TagEntry> entries, {
  required String Function() newId,
}) {
  final out = list.isEmpty ? [const PromptSection.main()] : [...list];
  final have = tokenizeSet(joinSections(out, mainPrompt, positive: true));
  for (final e in entries) {
    final rawPos = e.positive.trim(), rawNeg = e.negative.trim();
    if (rawPos.isEmpty && rawNeg.isEmpty) continue;
    final pos = outputOf(rawPos), neg = outputOf(rawNeg);
    final name = e.name.trim();
    final same = out.indexWhere(
      (s) => !s.isMain && s.name.trim() == name && s.positive.trim() == pos,
    );
    if (same >= 0) {
      out[same] = out[same].copyWith(enabled: true);
      continue;
    }
    final toks = tokenizeSet(pos);
    if (toks.isNotEmpty && have.containsAll(toks)) continue;
    have.addAll(toks);
    final sec = PromptSection(
      id: newId(),
      name: name.isEmpty ? nextSectionName(out) : name,
      positive: pos,
      positiveRaw: draftOf(rawPos, pos),
      negative: neg,
      negativeRaw: draftOf(rawNeg, neg),
      artist: e.category == TagCategory.artist,
    );
    out.add(sec);
  }
  return normalizeSections(out);
}
