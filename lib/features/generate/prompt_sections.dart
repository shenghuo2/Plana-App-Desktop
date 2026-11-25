import '../../core/util/prompt_tokens.dart' show cleanPromptToken;
import '../editor/editor_models.dart'
    show
        PromptFoldLink,
        draftOf,
        outputOf,
        pickEditorText,
        parseFolds,
        parseToks,
        deleteTok,
        setUnitsDisabled,
        stripFolds,
        topLevelUnits,
        validPromptFoldLinks;
import '../inspiration/tag_models.dart'
    show TagCategory, TagEntry, foldTagEntry;
import 'models.dart';
import 'prompt_import_binding.dart';

/// 主提示词分区的纯函数:拼接、计数口径、列表整理。状态写入在 GenerateNotifier
/// 与 CanvasWorkspaceNotifier.updatePrompts。

/// 分区头尾的空白与逗号:拼接时去掉,免得出现 `a,, b`。
String _clean(String s) =>
    s.trim().replaceAll(RegExp(r'^[,，\s]+|[,，\s]+$'), '');

/// 这一格的这一侧进不进载荷。主体的负面一直进:卡上负面那行是整张卡的,
/// 停用 / 删掉主体那一行只管它的正向。
bool _on(PromptSection s, {required bool positive}) =>
    (s.isMain && !positive) || s.enabled;

/// 主体那一行删掉了,主体的词还在(负面一直在;正向是之后又被写进来的),
/// 按排在最上面算 —— 卡上也是补在最上面(见 [withMainRow])。
List<PromptSection> _withMain(List<PromptSection> list) =>
    list.any((x) => x.isMain) ? list : [const PromptSection.main(), ...list];

/// 卡上和改分区时用的那份行:主体那一行删掉之后主体又被写进了正向(读图导入、
/// AI 助手…),主体回到最上面。
List<PromptSection> withMainRow(List<PromptSection> list, String mainPrompt) =>
    list.isEmpty || list.any((x) => x.isMain) || mainPrompt.trim().isEmpty
    ? list
    : [const PromptSection.main(), ...list];

/// 主体的正向进不进载荷。没分区、主体那一行删掉了都算进:那时它要么就是
/// 全部的词,要么是空的。
bool mainEnabled(List<PromptSection> list) => list
    .firstWhere((x) => x.isMain, orElse: () => const PromptSection.main())
    .enabled;

/// 按行序把主体和启用的分区拼成一整串。[main] 是主体那一侧的词(正或负)。
///
/// 正向按分区完整拼接,不同画师串／角色中的相同词也保留。
/// 负面仍合并重复的普通词,不改动任何分区保存的原文。
String joinSections(
  List<PromptSection> sections,
  String main, {
  required bool positive,
}) {
  if (sections.isEmpty) return main;
  final seen = <String>{};
  return [
    for (final s in _withMain(sections))
      if (_on(s, positive: positive))
        if (positive)
          _clean(s.isMain ? main : s.positive)
        else
          _dropSeen(_clean(s.isMain ? main : s.negative), seen),
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

/// 去重比对用的键:普通词按 [cleanPromptToken],带记号的按原样(空白归一)。
String _wordKey(String piece) {
  final t = piece.trim();
  if (!_syntax.hasMatch(t)) return 'p:${cleanPromptToken(t)}';
  return 's:${t.replaceAll(RegExp(r'\s+'), ' ').toLowerCase()}';
}

/// 逗号切开,标出哪几段是能整段拿掉的顶层词:不在 `{}` `[]` `::` 组里,
/// 自身记号也收了口。
List<(String, bool)> _topPieces(String text) {
  final out = <(String, bool)>[];
  var depth = 0;
  var inWeight = false;
  var inDisabled = false;
  var foldDepth = 0;
  for (final piece in text.split(RegExp(r'[,，]'))) {
    final top = depth == 0 && !inWeight && !inDisabled && foldDepth == 0;
    var d = 0;
    var tildes = 0;
    for (final c in piece.split('')) {
      if (c == '{' || c == '[') d++;
      if (c == '}' || c == ']') d--;
      if (c == '~') tildes++;
    }
    final weights = '::'.allMatches(piece).length;
    depth += d;
    foldDepth += '<#'.allMatches(piece).length - '#>'.allMatches(piece).length;
    if (weights.isOdd) inWeight = !inWeight;
    if (tildes.isOdd) inDisabled = !inDisabled;
    out.add((
      piece,
      top &&
          d == 0 &&
          foldDepth == 0 &&
          !inDisabled &&
          weights.isEven &&
          tildes.isEven &&
          piece.trim().isNotEmpty,
    ));
  }
  return out;
}

/// 从 [text] 里拿掉启用的格子里已有的顶层词。[main] 是主体那一侧的词,
/// [withMain] 为 false 时主体不算。
String dropSectionWords(
  String text,
  List<PromptSection> sections,
  String main, {
  required bool positive,
  bool withMain = false,
}) {
  if (text.trim().isEmpty) return text;
  final have = <String>{
    for (final s in _withMain(sections))
      if ((withMain || !s.isMain) && _on(s, positive: positive))
        for (final (p, top) in _topPieces(
          s.isMain ? main : (positive ? s.positive : s.negative),
        ))
          if (top) _wordKey(p),
  };
  if (have.isEmpty) return text;
  return _clean(
    [
      for (final (p, top) in _topPieces(text))
        if (!top || !have.contains(_wordKey(p))) p,
    ].join(','),
  );
}

/// AI 助手的提议写进创作页的方式。存档用枚举名。
enum SectionImport { aiSection, appendMain, main, newSection, clear }

typedef ImportBlockDecorator =
    PromptSection Function(
      PromptSection row,
      String Function(String, bool) retained,
      Set<String> reservedNames,
    );

/// Decorate the actual destination before merging it into the canvas. Both
/// generation and import use this projection; only committing an import saves
/// the returned ownership in the conversation.
GenerateState importPromptsInto(
  GenerateState s,
  String positive,
  String negative,
  SectionImport mode, {
  required String Function() newId,
  String sectionName = '',
  String fallbackName = 'AI',
  bool allowEditNegative = true,
  bool clearNegative = false,
  PromptImportBinding binding = const PromptImportBinding(),
  void Function(PromptImportBinding)? onBinding,
  ImportBlockDecorator? decorate,
}) {
  final dedicated = mode == SectionImport.aiSection;
  final append = mode == SectionImport.appendMain;
  final section = dedicated || mode == SectionImport.newSection;
  final target = dedicated
      ? s.sections
            .where((r) => !r.isMain && r.id == binding.sectionId)
            .firstOrNull
      : null;
  final others = target == null
      ? s.sections
      : s.sections.where((r) => r.id != target.id).toList();
  final writeNeg =
      allowEditNegative &&
      (negative.trim().isNotEmpty ||
          clearNegative ||
          mode == SectionImport.clear);
  final mainPos = pickEditorText(s.promptRaw, s.prompt);
  final mainNeg = pickEditorText(s.negativePromptRaw, s.negativePrompt);
  final posSlot = append
      ? PromptInsertSlot.locate(
          mainPos,
          binding.positive,
          s.promptFoldLinks,
          negative: false,
        )
      : null;
  final negSlot = append && writeNeg
      ? PromptInsertSlot.locate(
          mainNeg,
          binding.negative,
          s.promptFoldLinks,
          negative: true,
        )
      : null;
  final basePos = posSlot == null ? s.prompt : outputOf(posSlot.remainder);
  final baseNeg = negSlot == null
      ? s.negativePrompt
      : outputOf(negSlot.remainder);
  String retained(String text, bool neg) {
    if (neg && !writeNeg) return '';
    if (mode == SectionImport.clear) return text;
    return dropSectionWords(
      text,
      others,
      neg ? baseNeg : basePos,
      positive: !neg,
      withMain: section || append,
    );
  }

  final pos = retained(positive, false);
  final neg = retained(negative, true);
  if (section && target == null && pos.trim().isEmpty && neg.trim().isEmpty) {
    return s;
  }
  final old =
      target ??
      (append || section
          ? null
          : PromptSection(
              id: kMainSectionId,
              name: '',
              positive: s.prompt,
              negative: s.negativePrompt,
              positiveRaw: s.promptRaw,
              negativeRaw: s.negativePromptRaw,
              foldLinks: s.promptFoldLinks,
            ));
  final oldLinks = old?.foldLinks ?? const <PromptFoldLink>[];
  final preservePos = !dedicated && old?.positive == pos;
  final preserveNeg = !writeNeg || !dedicated && old?.negative == neg;
  var row = PromptSection(
    id: target?.id ?? (section ? newId() : kMainSectionId),
    name: sectionName.isNotEmpty ? sectionName : target?.name ?? fallbackName,
    enabled: target?.enabled ?? true,
    artist: target?.artist ?? false,
    sources: target?.sources ?? const [],
    positive: pos,
    negative: writeNeg ? neg : old?.negative ?? '',
    positiveRaw: preservePos ? old!.positiveRaw : '',
    negativeRaw: preserveNeg ? old?.negativeRaw ?? '' : '',
    foldLinks: [
      for (final link in oldLinks)
        if (preservePos && preserveNeg)
          link
        else if (preserveNeg && link.negativeName.isNotEmpty)
          link.copyWith(positiveName: '', positiveBody: '')
        else if (preservePos && link.positiveName.isNotEmpty)
          link.copyWith(negativeName: '', negativeBody: ''),
    ],
  );
  if (decorate != null) {
    final reserved = <String>{
      if (posSlot != null)
        for (final f in parseFolds(posSlot.remainder)) f.name,
      if (append)
        for (final f in parseFolds(negSlot?.remainder ?? mainNeg)) f.name,
    };
    row = decorate(row, retained, reserved);
  }
  if (section) {
    if (dedicated) {
      onBinding?.call(
        PromptImportBinding(
          sectionId: row.id,
          positive: binding.positive,
          negative: binding.negative,
        ),
      );
    }
    if (target != null) {
      return s.copyWith(
        sections: [for (final r in s.sections) r.id == target.id ? row : r],
      );
    }
    final rows = s.sections.isEmpty
        ? const [PromptSection.main()]
        : withMainRow(s.sections, s.prompt);
    return s.copyWith(sections: [...rows, row]);
  }
  if (append) {
    return _appendMainImport(s, row, posSlot!, negSlot, binding, onBinding);
  }
  onBinding?.call(
    PromptImportBinding(
      sectionId: binding.sectionId,
      negative: writeNeg ? null : binding.negative,
    ),
  );
  return s.copyWith(
    prompt: pos,
    promptRaw: row.positiveRaw,
    negativePrompt: row.negative,
    negativePromptRaw: row.negativeRaw,
    promptFoldLinks: row.foldLinks,
    sections: _sectionsAfterMainImport(s.sections, pos, mode, writeNeg),
  );
}

GenerateState _appendMainImport(
  GenerateState state,
  PromptSection row,
  PromptInsertSlot positiveSlot,
  PromptInsertSlot? negativeSlot,
  PromptImportBinding binding,
  void Function(PromptImportBinding)? onBinding,
) {
  final mainNeg = pickEditorText(state.negativePromptRaw, state.negativePrompt);
  final (rawNeg, nextNeg) =
      negativeSlot?.insert(pickEditorText(row.negativeRaw, row.negative), [
        for (final link in row.foldLinks)
          if (link.negativeName.isNotEmpty) link.id,
      ]) ??
      (mainNeg, binding.negative);
  final posRest = positiveSlot.remainder,
      negRest = negativeSlot?.remainder ?? mainNeg;
  final surviving = validPromptFoldLinks(
    posRest,
    negRest,
    state.promptFoldLinks,
  );
  final survivingIds = surviving.map((link) => link.id).toSet();
  // When one side of a pair was replaced, the untouched side keeps its identity.
  final singles = validPromptFoldLinks(posRest, negRest, [
    for (final link in state.promptFoldLinks)
      if (link.paired && !survivingIds.contains(link.id)) ...[
        link.copyWith(positiveName: '', positiveBody: ''),
        link.copyWith(negativeName: '', negativeBody: ''),
      ],
  ]);
  final placed = [...row.foldLinks];
  if (negativeSlot == null && singles.isNotEmpty) {
    // The canvas negative was omitted. Keep its link ID when the same
    // conversation replaces the other half of this exact named pair.
    final ownedPairs = state.promptFoldLinks.where(
      (l) =>
          l.paired &&
          binding.positive?.linkIds.contains(l.id) == true &&
          binding.negative?.linkIds.contains(l.id) == true,
    );
    for (var i = 0; i < placed.length; i++) {
      final fresh = placed[i];
      if (fresh.paired || fresh.temporaryCategory == null) continue;
      final old = ownedPairs
          .where(
            (l) =>
                l.positiveName == fresh.positiveName &&
                l.temporaryCategory == fresh.temporaryCategory,
          )
          .singleOrNull;
      final kept = singles
          .where((s) => s.id == old?.id && s.negativeName.isNotEmpty)
          .singleOrNull;
      if (kept == null) continue;
      placed[i] = kept.copyWith(
        positiveName: fresh.positiveName,
        positiveBody: fresh.positiveBody,
      );
      singles.remove(kept);
    }
  }
  final (rawPos, nextPos) = positiveSlot.insert(
    pickEditorText(row.positiveRaw, row.positive),
    [
      for (final link in placed)
        if (link.positiveName.isNotEmpty) link.id,
    ],
  );
  onBinding?.call(
    PromptImportBinding(
      sectionId: binding.sectionId,
      positive: nextPos,
      negative: nextNeg,
    ),
  );
  final samePos = rawPos == pickEditorText(state.promptRaw, state.prompt);
  final pos = samePos ? state.prompt : outputOf(rawPos);
  final neg = rawNeg == mainNeg ? state.negativePrompt : outputOf(rawNeg);
  return state.copyWith(
    prompt: pos,
    promptRaw: samePos ? state.promptRaw : draftOf(rawPos, pos),
    negativePrompt: neg,
    negativePromptRaw: rawNeg == mainNeg
        ? state.negativePromptRaw
        : draftOf(rawNeg, neg),
    promptFoldLinks: [...surviving, ...singles, ...placed],
    sections: withMainRow(state.sections, pos),
  );
}

List<PromptSection> _sectionsAfterMainImport(
  List<PromptSection> sections,
  String positive,
  SectionImport mode,
  bool writeNegative,
) {
  final rows = withMainRow(sections, positive);
  if (mode != SectionImport.clear) {
    return [
      for (final row in rows)
        row.isMain && positive.trim().isNotEmpty
            ? row.copyWith(enabled: true)
            : row,
    ];
  }
  // Clearing positives must keep each locked exclusion in its original row.
  bool hasNegative(PromptSection row) =>
      row.negative.isNotEmpty || row.negativeRaw.isNotEmpty;
  if (writeNegative || !rows.any((row) => !row.isMain && hasNegative(row))) {
    return const [];
  }
  return [
    for (final row in rows)
      if (row.isMain)
        row.copyWith(enabled: true)
      else if (hasNegative(row))
        row.copyWith(
          positive: '',
          positiveRaw: '',
          foldLinks: [
            for (final link in row.foldLinks)
              if (link.negativeName.isNotEmpty)
                link.copyWith(positiveName: '', positiveBody: ''),
          ],
        ),
  ];
}

/// Compose raw drafts as well as their paired-fold provenance. Fold names and
/// link IDs are local to an editor, so separate sections may reuse both.
(String, String, List<PromptFoldLink>) _composeDrafts(GenerateState state) {
  final parts = [
    for (final section in _withMain(state.sections))
      (
        positive: _on(section, positive: true)
            ? pickEditorText(
                section.isMain ? state.promptRaw : section.positiveRaw,
                section.isMain ? state.prompt : section.positive,
              )
            : '',
        negative: _on(section, positive: false)
            ? pickEditorText(
                section.isMain ? state.negativePromptRaw : section.negativeRaw,
                section.isMain ? state.negativePrompt : section.negative,
              )
            : '',
        links: section.isMain ? state.promptFoldLinks : section.foldLinks,
      ),
  ];
  return _mergeDraftParts(parts);
}

(String, String, List<PromptFoldLink>) _mergeDraftParts(
  List<({String positive, String negative, List<PromptFoldLink> links})>
  parts, {
  bool deduplicate = true,
}) {
  final reservedPos = {
    for (final p in parts)
      for (final f in parseFolds(p.positive)) f.name,
  };
  final reservedNeg = {
    for (final p in parts)
      for (final f in parseFolds(p.negative)) f.name,
  };
  final usedPos = <String>{}, usedNeg = <String>{}, ids = <String>{};
  final seenNeg = <String>{};
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
    final pos = positive;
    final neg = deduplicate ? _dropSeenDraft(negative, seenNeg) : negative;
    if (_clean(pos).isNotEmpty) positives.add(_clean(pos));
    if (_clean(neg).isNotEmpty) negatives.add(_clean(neg));
    final posFolds = parseFolds(pos), negFolds = parseFolds(neg);
    for (final link in valid) {
      final pn = posNames[link.positiveName] ?? '',
          nn = negNames[link.negativeName] ?? '';
      final pf = posFolds.where((f) => f.name == pn).firstOrNull;
      final nf = negFolds.where((f) => f.name == nn).firstOrNull;
      final pb = pf == null
          ? ''
          : pos.substring(pf.bodyStart, pf.bodyEnd).trim();
      final nb = nf == null
          ? ''
          : neg.substring(nf.bodyStart, nf.bodyEnd).trim();
      if ((link.positiveName.isNotEmpty && pb.isEmpty) ||
          (link.negativeName.isNotEmpty && nb.isEmpty)) {
        continue;
      }
      var id = link.id;
      for (var suffix = 2; !ids.add(id); suffix++) {
        id = '${link.id}:$suffix';
      }
      links.add(
        link.copyWith(
          id: id,
          positiveName: pn,
          positiveBody: pb,
          negativeName: nn,
          negativeBody: nb,
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
/// 草稿也照样拼一份,导回创作页时折叠还在。拼进去的那几格记在
/// [GenerateState.composedSections],它们来自的灵感库条目记在
/// [GenerateState.usedEntries]。没有分区原样返回。
GenerateState composeSections(GenerateState s) {
  if (s.sections.isEmpty) {
    return s.composedSections.isEmpty && s.usedEntries.isEmpty
        ? s
        : s.copyWith(composedSections: const [], usedEntries: const []);
  }
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
    usedEntries: {
      for (final x in s.sections)
        if (!x.isMain && x.enabled && _clean(x.positive).isNotEmpty)
          ...x.sources,
    }.toList(),
    composedSections: [
      for (final x in _withMain(s.sections))
        if (x.isMain)
          PromptSection(
            id: kMainSectionId,
            name: x.name,
            positive: x.enabled ? _clean(s.prompt) : '',
            negative: _clean(s.negativePrompt),
          )
        else if (x.enabled)
          PromptSection(
            id: x.id,
            name: x.name,
            positive: _clean(x.positive),
            negative: _clean(x.negative),
            artist: x.artist,
          ),
    ],
  );
}

/// 读图导入的分区按 [append] 写进 [s]。[rows] 是图里存的那几格(主体的词写在
/// 主体行里);[mainNegative] 为 null 时负面不动。
///
/// 完全覆盖:主提示词换成这几格,主体没选就空着。新建分区:每格接在最后,
/// 主体那格叫「分区 N」,已有的词不再写进去(同 [importPromptsInto]);
/// [mainNegative] 跟着主体那格走,主体没选就跟第一格。
GenerateState importSectionsInto(
  GenerateState s,
  List<PromptSection> rows, {
  String? mainNegative,
  required bool append,
  required String Function() newId,
}) {
  if (!append) {
    final main = rows.where((x) => x.isMain).firstOrNull;
    return s.copyWith(
      prompt: main?.positive ?? '',
      promptRaw: '',
      negativePrompt: mainNegative,
      negativePromptRaw: mainNegative == null ? null : '',
      sections: normalizeSections([
        for (final x in rows)
          x.isMain
              ? PromptSection.main(name: x.name)
              : PromptSection(
                  id: newId(),
                  name: x.name,
                  positive: x.positive,
                  negative: x.negative,
                  artist: x.artist,
                ),
      ]),
    );
  }
  final hasMain = rows.any((x) => x.isMain);
  var out = s;
  for (var i = 0; i < rows.length; i++) {
    final x = rows[i];
    final neg = x.isMain
        ? mainNegative ?? ''
        : !hasMain && i == 0 && mainNegative != null
        ? [
            mainNegative,
            x.negative,
          ].map(_clean).where((p) => p.isNotEmpty).join(', ')
        : x.negative;
    final next = importPromptsInto(
      out,
      x.positive,
      neg,
      SectionImport.newSection,
      newId: newId,
      sectionName: x.isMain
          ? nextSectionName(
              out.sections.isEmpty
                  ? const [PromptSection.main()]
                  : withMainRow(out.sections, out.prompt),
            )
          : x.name,
    );
    if (identical(next, out)) continue;
    out = x.artist
        ? next.copyWith(
            sections: [
              ...next.sections.take(next.sections.length - 1),
              PromptSection(
                id: next.sections.last.id,
                name: next.sections.last.name,
                positive: next.sections.last.positive,
                negative: next.sections.last.negative,
                artist: true,
              ),
            ],
          )
        : next;
  }
  return out;
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

/// 主体最多一行(可以没有:那一行删掉了)。只剩主体(或什么都没有)就整列清空,
/// 卡片回到原来的样子 —— 剩下的主体是停用着的除外:回到原样就没处看出它停着,
/// 正向会悄悄又进载荷。
List<PromptSection> normalizeSections(List<PromptSection> list) {
  if (!list.any((s) => !s.isMain)) {
    final main = list.where((s) => s.isMain).firstOrNull;
    return main != null && !main.enabled ? [main] : const [];
  }
  final out = <PromptSection>[];
  var hasMain = false;
  for (final s in list) {
    if (s.isMain) {
      if (hasMain) continue;
      hasMain = true;
    }
    out.add(s);
  }
  return out;
}

/// 整段的词都标成禁用(`~tag~`)。折叠先摊开:折叠单元套不了禁用。
String disableAllTags(String draft) {
  final plain = stripFolds(draft);
  final n = topLevelUnits(plain, const {}).length;
  if (n == 0) return plain;
  return setUnitsDisabled(plain, const {}, [
    for (var i = 0; i < n; i++) i,
  ], true);
}

/// 多选「合并」:勾的几格合成一格。留下的是勾选里的主体(勾了的话,主体删不掉),
/// 否则最上面那格,名字、位置不变;各格的词按行序从上往下接,挨着的几格合完
/// 拼出来的串一字不差。有一格开着合完就开着,停用那几格的词带着禁用标记进来:
/// 原来不出图的合完也不出图。不到两格返回 null。
GenerateState? mergeSectionsIn(GenerateState s, Set<String> ids) {
  final picked = [
    for (final x in s.sections)
      if (ids.contains(x.id)) x,
  ];
  if (picked.length < 2) return null;
  final target = picked.firstWhere((x) => x.isMain, orElse: () => picked.first);
  String pos(PromptSection x) => x.isMain
      ? pickEditorText(s.promptRaw, s.prompt)
      : pickEditorText(x.positiveRaw, x.positive);
  String neg(PromptSection x) => x.isMain
      ? pickEditorText(s.negativePromptRaw, s.negativePrompt)
      : pickEditorText(x.negativeRaw, x.negative);
  final on = picked.any((x) => x.enabled);
  // 合完那一格(那一侧)开着,才需要给停用那几段打禁用标记;主体的负面
  // 一直开着(见 _on),合进主体时负面那侧也就一直开着
  final negOn = target.isMain || on;
  String side(PromptSection x, String d, {required bool positive}) =>
      (positive ? on : negOn) &&
          !_on(x, positive: positive) &&
          d.trim().isNotEmpty
      ? disableAllTags(d)
      : d;
  final (pDraft, nDraft, links) = _mergeDraftParts([
    for (final x in picked)
      (
        positive: side(x, pos(x), positive: true),
        negative: side(x, neg(x), positive: false),
        links: x.isMain ? s.promptFoldLinks : x.foldLinks,
      ),
  ], deduplicate: false);
  final p = outputOf(pDraft), n = outputOf(nDraft);
  final rest = [
    for (final x in s.sections)
      if (!ids.contains(x.id) || x.id == target.id) x,
  ];
  if (target.isMain) {
    return s.copyWith(
      prompt: p,
      promptRaw: draftOf(pDraft, p),
      negativePrompt: n,
      negativePromptRaw: draftOf(nDraft, n),
      promptFoldLinks: links,
      sections: normalizeSections([
        for (final x in rest) x.isMain ? x.copyWith(enabled: on) : x,
      ]),
    );
  }
  return s.copyWith(
    sections: normalizeSections([
      for (final x in rest)
        x.id == target.id
            ? x.copyWith(
                positive: p,
                positiveRaw: draftOf(pDraft, p),
                negative: n,
                negativeRaw: draftOf(nDraft, n),
                foldLinks: links,
                enabled: on,
                sources: {for (final y in picked) ...y.sources}.toList(),
              )
            : x,
    ]),
  );
}

/// 新分区的默认名「分区 N」,N 取第一个没被占用的序号。
String nextSectionName(List<PromptSection> list) {
  final used = {for (final s in list) s.name};
  var n = 1;
  while (used.contains('分区 $n')) {
    n++;
  }
  return '分区 $n';
}

/// 删掉的分区放回原位。删的是最后一格时主体也跟着没了,[main] 是当时的主体
/// (那时本来就没有主体那一行就是 null)。
List<PromptSection> restoreSection(
  List<PromptSection> list,
  PromptSection removed,
  int index, {
  PromptSection? main = const PromptSection.main(),
}) {
  final out = list.isEmpty && main != null && !removed.isMain
      ? [main]
      : [...list];
  out.insert(index.clamp(0, out.length), removed);
  return normalizeSections(out);
}

/// 灵感库条目各自成一格,不折叠:名字取条目编号／名称,正负向原样
/// 放进这一格。新格子一律接在最后,按加进来的先后往下排 —— 别按分类插到
/// 主体前后,那样主体看着像在跳。
///
/// 每次导入都建立独立分区,不按已有词或同名分区去重,也不修改旧分区的开关。
/// 没分区时连主体一起建出来。
List<PromptSection> withEntrySections(
  List<PromptSection> list,
  String mainPrompt,
  Iterable<TagEntry> entries, {
  required String Function() newId,
}) {
  final rows = withMainRow(list, mainPrompt);
  final out = rows.isEmpty ? [const PromptSection.main()] : [...rows];
  for (final e in entries) {
    final rawPos = e.positive.trim(), rawNeg = e.negative.trim();
    if (rawPos.isEmpty && rawNeg.isEmpty) continue;
    final folded = foldTagEntry(e);
    final pos = outputOf(folded.positiveDraft),
        neg = outputOf(folded.negativeDraft);
    final name = e.name.trim();
    final sec = PromptSection(
      id: newId(),
      name: name.isEmpty ? nextSectionName(out) : name,
      positive: pos,
      positiveRaw: draftOf(folded.positiveDraft, pos),
      negative: neg,
      negativeRaw: draftOf(folded.negativeDraft, neg),
      foldLinks: folded.links,
      artist: e.category == TagCategory.artist,
      sources: [e.id],
    );
    out.add(sec);
  }
  return normalizeSections(out);
}
