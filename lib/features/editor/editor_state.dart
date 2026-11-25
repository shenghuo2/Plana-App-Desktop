import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/generate_state.dart';
import '../generate/canvas_state.dart';
import '../generate/models.dart' show PromptSection;
import '../generate/prompt_sections.dart' show normalizeSections;
import 'editor_models.dart';

final editorProvider = NotifierProvider<EditorNotifier, EditorState>(
  EditorNotifier.new,
);

/// Shared by every inline ProviderScope, so switching canvases can flush all
/// mounted editors and undo survives remounting a role or section editor.
final editorSessionsProvider = Provider((ref) => EditorSessions());

class EditorSessions {
  final Map<String, _UndoArchive> _archives = {};
  final Set<EditorNotifier> _editors = {};
  final Set<void Function()> prepareInputs = {};

  void flushPending() {
    for (final prepare in prepareInputs.toList()) {
      prepare();
    }
    for (final editor in _editors.toList()) {
      editor.flushPendingWriteBack();
    }
  }
}

typedef PlacedPromptFold = ({
  FoldRef? positive,
  FoldRef? negative,
  PromptFoldLink? link,
});

/// 光标驱动定稿:字符串就是真相,正/负各一条(含原样权重语法)。
/// 折叠体不在正文里(正文只有 `<#名字>` 占位符),存 [foldBodies];
/// 每次改动创建新表，撤销档连同正文保存对应版本；解散／删除不破坏旧快照。
/// 定稿与草稿都经 [expandFolds] 拼回完整语法后再算。
/// 撤销栈按编辑目标跨会话长效(见 [_UndoArchive]),退出编辑器不重置。
class EditorState {
  const EditorState({
    this.positiveText = '',
    this.negativeText = '',
    this.activePositive = true,
    this.canUndo = false,
    this.foldBodies = const {},
    this.foldLinks = const [],
  });

  final String positiveText;
  final String negativeText;
  final bool activePositive;
  final bool canUndo;

  /// 折叠表:占位符名字 → 折叠体(正/负两侧共用,载入时已跨侧去重)。
  final Map<String, String> foldBodies;
  final List<PromptFoldLink> foldLinks;

  String get activeText => activePositive ? positiveText : negativeText;

  PlacedPromptFold? placementOf(String name) {
    final link = foldLinks
        .where((l) => l.positiveName == name || l.negativeName == name)
        .firstOrNull;
    FoldRef? find(String text, String name) => parseFoldRefs(
      text,
      foldBodies,
    ).where((fold) => fold.name == name).singleOrNull;
    final pos = find(positiveText, link?.positiveName ?? name);
    final neg = find(negativeText, link?.negativeName ?? name);
    if (pos == null && neg == null ||
        link == null && pos != null && neg != null) {
      return null;
    }
    return (positive: pos, negative: neg, link: link);
  }

  /// 当前段定稿(占位符展开 + 剔除编辑期语法)。token 读数用。
  String get activeOutput => outputOf(expandFolds(activeText, foldBodies));

  EditorState copyWith({
    String? positiveText,
    String? negativeText,
    bool? activePositive,
    bool? canUndo,
    Map<String, String>? foldBodies,
    List<PromptFoldLink>? foldLinks,
  }) => EditorState(
    positiveText: positiveText ?? this.positiveText,
    negativeText: negativeText ?? this.negativeText,
    activePositive: activePositive ?? this.activePositive,
    canUndo: canUndo ?? this.canUndo,
    foldBodies: foldBodies ?? this.foldBodies,
    foldLinks: foldLinks ?? this.foldLinks,
  );
}

typedef _Snap = (
  String pos,
  String neg,
  List<PromptFoldLink> links,
  PromptSection? extracted,
  Map<String, String> bodies,
);

/// 单个编辑目标(主提示词/某角色)的撤销档。**进程级长效**:退出编辑器
/// 不清空,重进接着撤,只在进程结束或角色被删时消亡。每份历史快照保存
/// 自己的折叠表，确保块内改字、解散和删除都可以还原。
class _UndoArchive {
  final List<_Snap> snaps = [];
  Map<String, String> folds = const {};
}

class EditorNotifier extends Notifier<EditorState> {
  EditorNotifier({this.immediateWriteBack = false});

  /// Inline editors stay open while Generate and other editors are used.
  final bool immediateWriteBack;
  bool isWritingBack = false;

  /// 画布和编辑目标共同隔离撤销记录。
  Map<String, _UndoArchive> get _archives =>
      ref.read(editorSessionsProvider)._archives;
  static const _maxHistory = 60;
  int _lastPushMs = 0;

  _UndoArchive get _arc =>
      _archives.putIfAbsent('$_canvasId/$_targetKey', _UndoArchive.new);

  /// 撤销档里的目标名:主提示词 '',角色是它的 id,分区加 `s:` 前缀(两边的
  /// id 出自同一个发号器,前缀只是让人一眼分得清)。
  String get _targetKey =>
      _charId ?? (_sectionId == null ? '' : 's:$_sectionId');

  /// 本次会话的编辑目标:都为 null = 创作页主提示词;[_charId] = 该角色;
  /// [_sectionId] = 主提示词的该分区。进页面时由 [load] 钉死,中途不变。
  /// 用 id 不用名字——角色自动编号(「角色 N」)在删掉中间一个再新增时
  /// 会重名,名字不是稳定句柄。
  String? _charId;
  String? _sectionId;
  String? _canvasId;

  /// 编辑中实时回写创作页的防抖(编辑器内容不再只活在内存:
  /// 回写进 generateProvider 后由工作台持久化链自动落盘,
  /// 中途被杀最多丢一个防抖窗口的字)。
  Timer? _writeBack;

  @override
  EditorState build() {
    final sessions = ref.read(editorSessionsProvider);
    sessions._editors.add(this);
    ref.onDispose(() {
      _writeBack?.cancel();
      sessions._editors.remove(this);
    });
    return const EditorState();
  }

  void load({
    required String positive,
    required String negative,
    required bool startPositive,
    String? charId,
    String? sectionId,
  }) {
    _writeBack?.cancel(); // 新会话,作废上一会话可能挂着的回写
    _lastPushMs = 0;
    _charId = charId;
    _sectionId = charId == null ? sectionId : null;
    _canvasId = ref.read(canvasWorkspaceProvider).activeId;
    // 角色 / 分区已删,其撤销档随之作废(主档 '' 恒保留)
    final gen = ref.read(generateProvider);
    final live = <String>{
      '',
      for (final c in gen.characters) c.id,
      for (final s in gen.sections) 's:${s.id}',
    };
    _archives.removeWhere(
      (k, _) =>
          k.startsWith('$_canvasId/') &&
          !live.contains(k.substring('$_canvasId/'.length)),
    );
    final arc = _arc;
    final input = ref.read(generateProvider);
    final links = validPromptFoldLinks(
      positive,
      negative,
      charId == null
          ? sectionId == null
                ? input.promptFoldLinks
                : [
                    for (final s in input.sections)
                      if (s.id == sectionId) ...s.foldLinks,
                  ]
          : [
              for (final character in input.characters)
                if (character.id == charId) ...character.foldLinks,
            ],
    );
    final posNames = <String, String>{}, negNames = <String, String>{};
    // 草稿(完整折叠语法)→ 正文占位符 + 折叠表。负面侧避开正面已占的
    // 名字。同名的在用块各自分配名字，避免在检视器编辑一块时影响另一块；
    // 历史表中的同名同体仍可复用，保证重进会话时名字稳定。
    final (posText, posBodies) = collapseFolds(
      positive,
      seed: arc.folds,
      independent: true,
      onCollapsed: (fold, name) => posNames[fold.name] = name,
    );
    final (negText, negBodies) = collapseFolds(
      negative,
      seed: {...arc.folds, ...posBodies},
      independent: true,
      reservedNames: posBodies.keys.toSet(),
      onCollapsed: (fold, name) => negNames[fold.name] = name,
    );
    arc.folds = {...arc.folds, ...posBodies, ...negBodies};
    state = EditorState(
      positiveText: posText,
      negativeText: negText,
      activePositive: startPositive,
      canUndo: arc.snaps.isNotEmpty,
      foldBodies: arc.folds,
      foldLinks: [
        for (final link in links)
          link.copyWith(
            positiveName: posNames[link.positiveName] ?? '',
            negativeName: negNames[link.negativeName] ?? '',
          ),
      ],
    );
  }

  /// 注册一个折叠体(补全插入画师串 / OC 标签组时),返回占位符该用的名字
  /// (重名且内容不同时自动加序号)。表只增不删——撤销回带占位符的旧文本时
  /// 仍能解析。
  String registerFold(String name, String body) {
    final referencedNames = {
      for (final text in [state.positiveText, state.negativeText])
        for (final fold in parseFoldRefs(text, state.foldBodies)) fold.name,
      for (final link in state.foldLinks) ...[
        link.positiveName,
        link.negativeName,
      ],
    };
    // Every live reference needs its own editable body, even for identical
    // names/content. Reusing archived, currently absent bodies remains safe.
    final lookup = {
      ...state.foldBodies,
      for (final name in referencedNames)
        name: '${state.foldBodies[name]}\u0000',
    };
    final n = uniqueFoldName(name, body, lookup);
    final next = {...state.foldBodies, n: body};
    _arc.folds = next; // 撤销档同步留存:快照回带占位符时仍解析得回
    state = state.copyWith(foldBodies: next);
    return n;
  }

  /// Commits an explicit library save as one undo step for this editor target.
  /// A null body retains the placed side, which may have been deduplicated on import.
  void applySavedInspiration({
    required String entryId,
    required String title,
    required String? positiveBody,
    required String? negativeBody,
    PromptFoldSlot? selection,
    PlacedPromptFold? editing,
    bool rename = true,
  }) => _applyInspiration(
    entryId: entryId,
    title: title,
    positiveBody: positiveBody,
    negativeBody: negativeBody,
    selection: selection,
    editing: editing,
    rename: rename,
  );

  /// Typing the first tag on an absent side creates that side on this canvas.
  String? addTemporaryFoldSide(
    String anchor, {
    required bool positive,
    required String body,
  }) {
    final editing = state.placementOf(anchor);
    final link = editing?.link;
    if (link == null ||
        link.temporaryCategory == null ||
        body.trim().isEmpty ||
        (positive ? link.positiveName : link.negativeName).isNotEmpty) {
      return null;
    }
    final title = link.positiveName.isNotEmpty
        ? link.positiveName
        : link.negativeName.replaceFirst(RegExp(r'·排除$'), '');
    final placed = _applyInspiration(
      title: title,
      positiveBody: positive ? body : null,
      negativeBody: positive ? null : body,
      editing: editing,
      rename: false,
    );
    return positive ? placed.positiveName : placed.negativeName;
  }

  PromptFoldLink _applyInspiration({
    String? entryId,
    required String title,
    required String? positiveBody,
    required String? negativeBody,
    PromptFoldSlot? selection,
    PlacedPromptFold? editing,
    required bool rename,
  }) {
    assert((selection == null) != (editing == null));
    final bodies = {...state.foldBodies};
    final used = {
      for (final text in [state.positiveText, state.negativeText])
        for (final fold in parseFoldRefs(text, bodies)) fold.name,
    };
    ({String text, String name, String body}) place(
      bool positive,
      FoldRef? previous,
      String? savedBody,
    ) {
      final text = positive ? state.positiveText : state.negativeText;
      final body = stripFolds(savedBody ?? bodies[previous?.name] ?? '').trim();
      final slot = previous != null
          ? PromptFoldSlot(text, previous.start, previous.end)
          : positive == state.activePositive
          ? selection
          : null;
      if (body.isEmpty && (savedBody != null || previous == null)) {
        return (text: slot?.replace('') ?? text, name: '', body: '');
      }
      final base = sanitizeFoldName(positive ? title : '$title·排除');
      var name = !rename && previous != null ? previous.name : base;
      for (
        var suffix = 2;
        used.contains(name) && name != previous?.name;
        suffix++
      ) {
        name = '$base $suffix';
      }
      used.add(name);
      bodies[name] = body;
      final reference = foldRefLiteral(name);
      return (
        text: slot?.replace(reference) ?? appendUnit(text, reference),
        name: name,
        body: body,
      );
    }

    final pos = place(true, editing?.positive, positiveBody);
    final neg = place(false, editing?.negative, negativeBody);
    final oldLink = editing?.link;
    final link = (oldLink ?? PromptFoldLink.forEntry(entryId!)).copyWith(
      sourceEntryId: entryId,
      positiveName: pos.name,
      positiveBody: pos.body,
      negativeName: neg.name,
      negativeBody: neg.body,
    );
    final links = validPromptFoldLinks(
      expandFolds(pos.text, bodies),
      expandFolds(neg.text, bodies),
      [
        for (final existing in state.foldLinks)
          if (existing != oldLink) existing,
        link,
      ],
    );
    if (pos.text == state.positiveText &&
        neg.text == state.negativeText &&
        oldLink == link &&
        state.foldBodies[pos.name] == bodies[pos.name] &&
        state.foldBodies[neg.name] == bodies[neg.name]) {
      return link;
    }
    _remember();
    _lastPushMs = DateTime.now().millisecondsSinceEpoch;
    _arc.folds = bodies;
    state = state.copyWith(
      positiveText: pos.text,
      negativeText: neg.text,
      foldLinks: links,
      foldBodies: bodies,
      canUndo: true,
    );
    flushWriteBack();
    return link;
  }

  /// Edit a block in place. Its placeholder and the opposite prompt remain
  /// intact; body maps are immutable snapshots so undo restores their content.
  void editFoldBody(String name, String body, {bool structural = false}) {
    if (!state.foldBodies.containsKey(name) || state.foldBodies[name] == body) {
      return;
    }
    if (![state.positiveText, state.negativeText].any(
      (text) =>
          parseFoldRefs(text, state.foldBodies).any((r) => r.name == name),
    )) {
      return; // A dismissed/deleted block must not be revived by a late edit.
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (structural || now - _lastPushMs > 700) {
      _remember();
      _lastPushMs = now;
    }
    final links = validPromptFoldLinks(
      expandFolds(state.positiveText, state.foldBodies),
      expandFolds(state.negativeText, state.foldBodies),
      state.foldLinks,
    );
    final bodies = {...state.foldBodies, name: body};
    _arc.folds = bodies;
    state = state.copyWith(
      foldBodies: bodies,
      foldLinks: [
        for (final link in links)
          link.copyWith(
            positiveBody: link.positiveName == name
                ? body.trim()
                : link.positiveBody,
            negativeBody: link.negativeName == name
                ? body.trim()
                : link.negativeBody,
          ),
      ],
      canUndo: true,
    );
    _scheduleWriteBack();
  }

  void _remember([PromptSection? extracted]) {
    final snaps = _arc.snaps;
    snaps.add((
      state.positiveText,
      state.negativeText,
      state.foldLinks,
      extracted,
      state.foldBodies,
    ));
    if (snaps.length > _maxHistory) snaps.removeAt(0);
  }

  void _scheduleWriteBack() {
    _writeBack?.cancel();
    if (immediateWriteBack) {
      flushWriteBack();
      return;
    }
    _writeBack = Timer(const Duration(milliseconds: 400), flushWriteBack);
  }

  /// 立即把当前定稿回写(防抖到点/离开编辑器/退后台共用)。
  /// 目标由 [load] 钉死的 [_charId] 决定:角色会话绝不写主提示词
  /// ——从前这里写死了 setPrompts,点角色卡进来编辑会静默覆盖主提示词。
  void flushWriteBack() {
    _writeBack?.cancel();
    _writeBack = null;
    isWritingBack = true;
    try {
      _writeToGenerate();
    } finally {
      isWritingBack = false;
    }
  }

  void _writeToGenerate() {
    final canvasId = _canvasId;
    if (canvasId == null) return;
    final id = _charId;
    final sectionId = _sectionId;
    // 草稿 = 占位符展开回完整折叠语法(下次载入原样收回);定稿再剔编辑期语法
    final posDraft = expandFolds(state.positiveText, state.foldBodies);
    final negDraft = expandFolds(state.negativeText, state.foldBodies);
    final pos = outputOf(posDraft);
    final neg = outputOf(negDraft);
    final posRaw = draftOf(posDraft, pos);
    final negRaw = draftOf(negDraft, neg);
    final links = validPromptFoldLinks(posDraft, negDraft, state.foldLinks);
    // 按进编辑器时的画布回写:编辑中途切了画布,写的也还是原来那张
    ref.read(canvasWorkspaceProvider.notifier).updatePrompts(canvasId, (p) {
      if (sectionId != null) {
        // 这一格已经删了就不写(同角色会话:绝不改写到别处)
        final cur = p.sections.where((x) => x.id == sectionId).firstOrNull;
        if (cur == null ||
            (cur.positive == pos &&
                cur.negative == neg &&
                cur.positiveRaw == posRaw &&
                cur.negativeRaw == negRaw &&
                listEquals(cur.foldLinks, links))) {
          return p;
        }
        return p.copyWith(
          sections: [
            for (final s in p.sections)
              if (s.id == sectionId)
                s.copyWith(
                  positive: pos,
                  negative: neg,
                  positiveRaw: posRaw,
                  negativeRaw: negRaw,
                  foldLinks: links,
                )
              else
                s,
          ],
        );
      }
      if (id == null) {
        if (p.prompt == pos &&
            p.negativePrompt == neg &&
            p.promptRaw == posRaw &&
            p.negativePromptRaw == negRaw &&
            listEquals(p.promptFoldLinks, links)) {
          return p;
        }
        return p.copyWith(
          prompt: pos,
          negativePrompt: neg,
          promptRaw: posRaw,
          negativePromptRaw: negRaw,
          promptFoldLinks: links,
          sections: p.prompt != pos && pos.trim().isNotEmpty
              ? normalizeSections([
                  for (final section in p.sections)
                    section.isMain ? section.copyWith(enabled: true) : section,
                ])
              : null,
        );
      }
      final c = p.characters.where((c) => c.id == id).firstOrNull;
      if (c == null ||
          (c.positive == pos &&
              c.negative == neg &&
              c.positiveRaw == posRaw &&
              c.negativeRaw == negRaw &&
              listEquals(c.foldLinks, links))) {
        return p;
      }
      return p.copyWith(
        characters: [
          for (final c in p.characters)
            if (c.id == id)
              c.copyWith(
                positive: pos,
                negative: neg,
                positiveRaw: posRaw,
                negativeRaw: negRaw,
                foldLinks: links,
              )
            else
              c,
        ],
      );
    });
  }

  void flushPendingWriteBack() {
    if (_writeBack?.isActive ?? false) flushWriteBack();
  }

  /// 写入当前段。structural=true(删/插/改权重等)必入撤销栈,打字按 700ms 合并。
  void editActive(
    String text, {
    bool structural = false,
    bool detachRemovedFolds = false,
    PromptSection? extracted,
  }) {
    if (text == state.activeText && extracted == null) return;
    final bodies = state.foldBodies;
    final existingLinks = validPromptFoldLinks(
      expandFolds(state.positiveText, bodies),
      expandFolds(state.negativeText, bodies),
      state.foldLinks,
    );
    var opposite = state.activePositive
        ? state.negativeText
        : state.positiveText;
    final oldRefs = parseFoldRefs(state.activeText, bodies);
    final newRefs = parseFoldRefs(text, bodies);
    final replacesFold = newRefs.any(
      (next) =>
          newRefs.where((ref) => ref.name == next.name).length >
          oldRefs.where((ref) => ref.name == next.name).length,
    );
    var removedLinkedFold = false;
    for (final link in existingLinks) {
      if (!link.paired) continue;
      final name = state.activePositive ? link.positiveName : link.negativeName;
      if (newRefs.any((ref) => ref.name == name)) continue;
      final old = oldRefs.where((ref) => ref.name == name).toList();
      if (old.length != 1) continue;
      removedLinkedFold = true;
      // The editor's explicit unfold action replaces a reference with its body
      // in place (also within weight/disabled wrappers). It detaches the pair;
      // it never means deleting its counterpart.
      if (detachRemovedFolds ||
          replacesFold ||
          unfoldRef(state.activeText, old.single, bodies) == text) {
        continue;
      }
      final otherName = state.activePositive
          ? link.negativeName
          : link.positiveName;
      final other = parseFoldRefs(
        opposite,
        bodies,
      ).where((ref) => ref.name == otherName).toList();
      if (other.length == 1) {
        opposite = deleteFoldRef(opposite, other.single).$1;
      }
    }
    final positive = state.activePositive ? text : opposite;
    final negative = state.activePositive ? opposite : text;
    final nextLinks = validPromptFoldLinks(
      expandFolds(positive, bodies),
      expandFolds(negative, bodies),
      existingLinks,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (structural ||
        extracted != null ||
        removedLinkedFold ||
        now - _lastPushMs > 700) {
      _remember(extracted);
      _lastPushMs = now;
    }
    state = state.copyWith(
      positiveText: positive,
      negativeText: negative,
      foldLinks: nextLinks,
      canUndo: true,
    );
    _scheduleWriteBack();
  }

  void setActivePositive(bool v) {
    if (v == state.activePositive) return;
    state = state.copyWith(activePositive: v);
  }

  void undo() {
    final snaps = _arc.snaps;
    if (snaps.isEmpty) return;
    final s = snaps.removeLast();
    _lastPushMs = 0;
    state = state.copyWith(
      positiveText: s.$1,
      negativeText: s.$2,
      foldLinks: s.$3,
      foldBodies: s.$5,
      canUndo: snaps.isNotEmpty,
    );
    _arc.folds = state.foldBodies;
    if (s.$4 case final extracted?) _dropExtracted(extracted);
    _scheduleWriteBack();
  }

  /// 撤回一次「提取为新分区」:那一格还在、词也没改过,就从它所在的画布
  /// 拿掉;改过的留着 —— 那是之后另写的东西,撤销不该替人扔掉。
  void _dropExtracted(PromptSection section) {
    final canvasId = _canvasId;
    if (canvasId == null) return;
    ref.read(canvasWorkspaceProvider.notifier).updatePrompts(canvasId, (p) {
      final cur = p.sections.where((x) => x.id == section.id).firstOrNull;
      if (cur == null ||
          cur.positive != section.positive ||
          cur.negative != section.negative ||
          cur.positiveRaw != section.positiveRaw ||
          cur.negativeRaw != section.negativeRaw) {
        return p;
      }
      return p.copyWith(
        sections: normalizeSections([
          for (final x in p.sections)
            if (x.id != section.id) x,
        ]),
      );
    });
  }

  String outputPositive() =>
      outputOf(expandFolds(state.positiveText, state.foldBodies));
  String outputNegative() =>
      outputOf(expandFolds(state.negativeText, state.foldBodies));
}
