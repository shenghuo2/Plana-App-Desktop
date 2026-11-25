/// 预设页:上面是这份预设的名称、作者、支持的模型和启用的模型,下面是段落。
///
/// 段落一段一张卡:点卡进编辑页改内容,点名字改名,⏻ 停用、🗑 删除、长按拖动排序。
///
/// 默认规则的原件在包里,改不了:名称、作者、支持的模型只读,段落第一次保存时另存为
/// 「原名 (副本)」,这个模型原先用默认规则的就改用这份副本,之后在这页接着改的都是它。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_skin.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/haptics.dart';
import '../../l10n/l10n.dart';
import '../generate/widgets/common.dart'
    show RoundIconBtn, confirmDialog, hintSnack;
import '../profile/widgets/settings_ui.dart';
import 'presets/default_rules.dart';
import 'presets/preset_rule.dart';
import 'presets/rules_file.dart';
import 'presets/rules_library.dart';
import 'widgets/rule_card_drag_target.dart';

class RulesPresetDetailPage extends ConsumerStatefulWidget {
  /// [family] 给了就是那个模型的默认规则,否则是 [presetId] 那份预设。
  const RulesPresetDetailPage({super.key, this.family, this.presetId})
    : draft = null,
      assert((family == null) != (presetId == null));

  const RulesPresetDetailPage.newPreset({
    super.key,
    required RulesPreset this.draft,
  }) : family = null,
       presetId = null;

  final RulesFamily? family;
  final String? presetId;
  final RulesPreset? draft;

  @override
  ConsumerState<RulesPresetDetailPage> createState() =>
      _RulesPresetDetailPageState();
}

class _RulesPresetDetailPageState extends ConsumerState<RulesPresetDetailPage> {
  /// 在改的那份预设;默认规则还没另存时是 null。
  late String? _id = widget.presetId ?? widget.draft?.id;

  /// 默认规则正在另存,这期间的操作不接,免得存出两份。
  var _copying = false;

  RulesPreset? _preset(RulesLibrary? lib) =>
      lib?.all.where((p) => p.id == _id).firstOrNull ?? widget.draft;

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(rulesLibraryProvider).value;
    final p = _id == null ? null : _preset(lib);
    final d = _id == null
        ? ref.watch(defaultRulesProvider(widget.family!)).value
        : null;
    final rules = p?.rules ?? d?.rules;
    final title = p?.name ?? d?.displayName ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: context.l10n.fullTextEdit,
            onPressed: rules == null ? null : () => _editFullText(rules),
            icon: const Icon(Icons.notes),
          ),
        ],
      ),
      body: lib == null || rules == null
          ? const Center(child: CircularProgressIndicator())
          : _body(lib, p, d, rules),
    );
  }

  Widget _body(
    RulesLibrary lib,
    RulesPreset? p,
    DefaultRules? d,
    List<PresetRule> rules,
  ) {
    final l = context.l10n;
    final models = p?.models ?? {widget.family!};
    final selfId = p?.id ?? defaultPresetOf(widget.family!).id;
    final enabled = lib.enabledFor(selfId);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              icon: Icons.drive_file_rename_outline,
              title: l.presetName,
              value: p?.name ?? d?.displayName ?? '',
              onTap: p == null || p.isDefault ? null : () => _editName(p),
            ),
            SettingsRow(
              icon: Icons.person_outline,
              title: l.author,
              value: p?.author ?? d?.author ?? '',
              onTap: p == null || p.isDefault ? null : () => _editAuthor(p),
            ),
            _ModelMenuRow(
              icon: Icons.memory_outlined,
              title: l.supportedModels,
              options: RulesFamily.values,
              selected: models,
              locked: models.length == 1 ? models : const {},
              onToggle: p == null || p.isDefault
                  ? null
                  : (f, checked) {
                      final current = _preset(
                        ref.read(rulesLibraryProvider).value,
                      )!;
                      final next = checked
                          ? {...current.models, f}
                          : ({...current.models}..remove(f));
                      if (next.isNotEmpty) _replace(current, models: next);
                    },
            ),
            _ModelMenuRow(
              icon: Icons.check_circle_outline,
              title: l.enabledModels,
              options: RulesFamily.values.where(models.contains),
              selected: enabled,
              locked: const {},
              onToggle: (f, checked) {
                final currentLib = ref.read(rulesLibraryProvider).requireValue;
                if (checked &&
                    widget.draft?.id == selfId &&
                    !currentLib.presets.any((p) => p.id == selfId)) {
                  _replace(widget.draft!, enableFor: f);
                } else {
                  ref
                      .read(rulesLibraryProvider.notifier)
                      .use(f, checked ? selfId : null);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsLabel(l.ruleSectionsLabel),
        // 首尾各一颗:顶上这颗加在最前;一段都没有时只留底下那颗
        if (rules.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _addButton(() => _add(rules, atStart: true)),
          ),
      ],
    );
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      header: header,
      footer: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: _addButton(() => _add(rules)),
      ),
      itemCount: rules.length,
      proxyDecorator: (child, _, _) => Material(
        color: Colors.transparent,
        elevation: 3,
        borderRadius: BorderRadius.circular(16),
        child: child,
      ),
      onReorderItem: (from, to) {
        final next = [...rules];
        next.insert(to, next.removeAt(from));
        _commit(next);
      },
      itemBuilder: (context, i) => Padding(
        key: ObjectKey(rules[i]),
        padding: const EdgeInsets.only(bottom: 10),
        child: _RuleCardView(
          index: i,
          rule: rules[i],
          onEdit: () => _edit(rules, i),
          onRename: () => _rename(rules, i),
          onToggle: () => _commit(
            [...rules]..[i] = rules[i].copyWith(enabled: !rules[i].enabled),
          ),
          onDelete: () => _delete(rules, i),
        ),
      ),
    );
  }

  Future<void> _replace(
    RulesPreset p, {
    String? name,
    String? author,
    Set<RulesFamily>? models,
    List<PresetRule>? rules,
    RulesFamily? enableFor,
  }) => ref
      .read(rulesLibraryProvider.notifier)
      .replace(
        p.id,
        name: name ?? p.name,
        author: author ?? p.author,
        models: models ?? p.models,
        rules: rules ?? p.rules,
        insertIfMissing: p.id == widget.draft?.id,
        enableFor: enableFor,
      );

  Future<void> _editName(RulesPreset p) async {
    final v = await _askText(context.l10n.presetName, p.name, selectAll: true);
    if (v == null || v.isEmpty || v == p.name) return;
    await _replace(p, name: v);
  }

  Future<void> _editAuthor(RulesPreset p) async {
    final v = await _askText(context.l10n.author, p.author);
    if (v == null || v == p.author) return;
    await _replace(p, author: v);
  }

  /// 存段落。默认规则第一次存是另存为一份新预设。
  Future<void> _commit(
    List<PresetRule> rules, {
    String? name,
    String? author,
    Set<RulesFamily>? models,
  }) async {
    if (_copying) return;
    final err = rulesEditLimitError(rules);
    if (err != null) {
      hintSnack(context, err, icon: Icons.error_outline);
      return;
    }
    final n = ref.read(rulesLibraryProvider.notifier);
    final p = _preset(ref.read(rulesLibraryProvider).value);
    if (_id != null && p == null) return;
    if (p != null && !p.isDefault) {
      await _replace(
        p,
        name: name,
        author: author,
        models: models,
        rules: rules,
      );
      return;
    }
    final f = p?.models.single ?? widget.family!;
    _copying = true;
    try {
      final d = p == null ? await bundledDefaultRules(f) : null;
      if (!mounted) return;
      final originalName = p?.name ?? d!.displayName;
      final lib = ref.read(rulesLibraryProvider).requireValue;
      final copyName = name == null || name == originalName
          ? lib.copyNameOf(originalName)
          : name;
      final copyModels = models ?? {f};
      final originalId = p?.id ?? defaultPresetOf(f).id;
      final newId = await n.add(
        name: copyName,
        author: author ?? p?.author ?? d!.author,
        models: copyModels,
        rules: rules,
        enableFor: lib.activeFor(f)?.id == originalId ? f : null,
      );
      if (!mounted) return;
      setState(() => _id = newId);
      hintSnack(
        context,
        context.l10n.savedAsNamed(copyName),
        icon: Icons.check_circle_outline,
      );
    } finally {
      _copying = false;
    }
  }

  Future<void> _edit(List<PresetRule> rules, int i) async {
    final edited = await Navigator.push<PresetRule>(
      context,
      MaterialPageRoute(builder: (_) => _SectionEditorPage(rule: rules[i])),
    );
    if (edited == null) return;
    await _commit([...rules]..[i] = edited);
  }

  Widget _addButton(VoidCallback onPressed) => FilledButton.tonalIcon(
    onPressed: onPressed,
    icon: const Icon(Icons.add, size: 18),
    label: Text(context.l10n.addRuleSection),
    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
  );

  /// 新加一段:先起名再写内容;[atStart] = 加在最前,否则接在最后。
  Future<void> _add(List<PresetRule> rules, {bool atStart = false}) async {
    final name = await _askSectionName('');
    if (name == null || !mounted) return;
    final edited = await Navigator.push<PresetRule>(
      context,
      MaterialPageRoute(
        builder: (_) => _SectionEditorPage(
          rule: PresetRule(name: name, content: ''),
        ),
      ),
    );
    if (edited == null) return;
    await _commit(atStart ? [edited, ...rules] : [...rules, edited]);
  }

  /// 点名字改名。框里是显示名,没改就不动(内置段名不会被换成中文)。
  Future<void> _rename(List<PresetRule> rules, int i) async {
    final shown = ruleSectionLabel(rules[i].name);
    final name = await _askSectionName(shown);
    if (name == null || name == shown) return;
    await _commit([...rules]..[i] = rules[i].copyWith(name: name));
  }

  /// 问一行字,取消返回 null,其余去掉首尾空白返回。
  Future<String?> _askText(
    String title,
    String initial, {
    String? label,
    bool selectAll = false,
  }) async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => _RuleTextDialog(
        title: title,
        initial: initial,
        label: label,
        selectAll: selectAll,
      ),
    );
    return v?.trim();
  }

  /// 问段名,取消或留空返回 null。
  Future<String?> _askSectionName(String initial) async {
    final l = context.l10n;
    final v = await _askText(
      initial.isEmpty ? l.addRuleSection : l.rename,
      initial,
      label: l.ruleSectionName,
    );
    if (v == null || v.isEmpty) return null;
    // 和工具层同名的段读回来会被当成旧货丢掉
    if (v == kToolLayerName) {
      if (mounted) {
        hintSnack(
          context,
          l.ruleSectionNameReserved,
          icon: Icons.error_outline,
        );
      }
      return null;
    }
    return v;
  }

  Future<void> _delete(List<PresetRule> rules, int i) async {
    final ok = await confirmDialog(
      context,
      title: context.l10n.deleteRuleSectionQ,
      message: context.l10n.deleteRuleSectionBody(
        ruleSectionLabel(rules[i].name),
      ),
      confirmLabel: context.l10n.delete,
    );
    if (!ok) return;
    await _commit([...rules]..removeAt(i));
  }

  /// 全文编辑:摊开的就是导出的那份文本,电脑上改好的能整段贴进来。
  Future<void> _editFullText(List<PresetRule> rules) async {
    final p = _preset(ref.read(rulesLibraryProvider).value);
    final RulesFamily? f = widget.family;
    final DefaultRules? d = p == null && f != null
        ? await bundledDefaultRules(f)
        : null;
    if (!mounted) return;
    final name = p?.name ?? d?.displayName ?? '';
    final file = await Navigator.push<RulesFile>(
      context,
      MaterialPageRoute(
        builder: (_) => _RulesEditorPage(
          title: name,
          text: encodeRulesFile(
            name: name,
            author: p?.author ?? d?.author ?? '',
            models: p?.models ?? {?f},
            rules: rules,
          ),
        ),
      ),
    );
    if (file == null) return;
    await _commit(
      file.rules,
      name: file.name,
      author: file.author,
      models: file.models,
    );
  }
}

class _RuleTextDialog extends StatefulWidget {
  const _RuleTextDialog({
    required this.title,
    required this.initial,
    this.label,
    required this.selectAll,
  });

  final String title;
  final String initial;
  final String? label;
  final bool selectAll;

  @override
  State<_RuleTextDialog> createState() => _RuleTextDialogState();
}

class _RuleTextDialogState extends State<_RuleTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    if (widget.selectAll) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initial.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      selectAllOnFocus: widget.selectAll ? false : null,
      decoration: InputDecoration(isDense: true, labelText: widget.label),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(context.l10n.confirm),
      ),
    ],
  );
}

class _ModelMenuRow extends StatefulWidget {
  const _ModelMenuRow({
    required this.icon,
    required this.title,
    required this.options,
    required this.selected,
    required this.locked,
    required this.onToggle,
  });

  final IconData icon;
  final String title;
  final Iterable<RulesFamily> options;
  final Set<RulesFamily> selected;
  final Set<RulesFamily> locked;
  final void Function(RulesFamily, bool)? onToggle;

  @override
  State<_ModelMenuRow> createState() => _ModelMenuRowState();
}

class _ModelMenuRowState extends State<_ModelMenuRow> {
  static const _width = 184.0;
  static const _gap = 4.0;
  static const _edge = 8.0;
  double _menuHeight = double.infinity;

  double _spaceBelow(BuildContext anchor) {
    final overlay =
        Overlay.of(anchor, rootOverlay: true).context.findRenderObject()!
            as RenderBox;
    final row = anchor.findRenderObject()! as RenderBox;
    final bottom = row
        .localToGlobal(Offset(0, row.size.height), ancestor: overlay)
        .dy;
    return (overlay.size.height -
            MediaQuery.paddingOf(anchor).bottom -
            bottom -
            _gap -
            _edge)
        .clamp(1.0, double.infinity);
  }

  Future<void> _toggleMenu(
    BuildContext anchor,
    MenuController controller,
  ) async {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    if (_spaceBelow(anchor) < widget.options.length * 48 + 8) {
      await Scrollable.ensureVisible(anchor, alignment: 0);
      if (!anchor.mounted) return;
    }
    setState(() => _menuHeight = _spaceBelow(anchor));
    controller.open();
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.selected.isEmpty
        ? context.l10n.notEnabled
        : RulesFamily.values
              .where(widget.selected.contains)
              .map(rulesFamilyLabel)
              .join(context.l10n.listSep);
    if (widget.onToggle == null) {
      return SettingsRow(
        icon: widget.icon,
        title: widget.title,
        value: summary,
      );
    }
    final scheme = context.scheme;
    return MenuAnchor(
      useRootOverlay: true,
      consumeOutsideTap: true,
      alignmentOffset: const Offset(-_width, _gap),
      reservedPadding: const EdgeInsets.all(_edge),
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        minimumSize: const WidgetStatePropertyAll(Size(_width, 0)),
        maximumSize: WidgetStatePropertyAll(Size(_width, _menuHeight)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4),
        ),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      menuChildren: [
        FocusScope(
          autofocus: true,
          child: SizedBox(
            width: _width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final model in widget.options)
                  CheckboxMenuButton(
                    value: widget.selected.contains(model),
                    closeOnActivate: false,
                    onChanged: widget.locked.contains(model)
                        ? null
                        : (value) => widget.onToggle!(model, value == true),
                    child: Text(rulesFamilyLabel(model)),
                  ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => SettingsRow(
        icon: widget.icon,
        title: widget.title,
        value: summary,
        dropdown: true,
        onTap: () => _toggleMenu(context, controller),
      ),
    );
  }
}

class _RuleCardView extends StatelessWidget {
  const _RuleCardView({
    required this.index,
    required this.rule,
    required this.onEdit,
    required this.onRename,
    required this.onToggle,
    required this.onDelete,
  });

  final int index;
  final PresetRule rule;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final meta = [
      ?whenTag(rule.when),
      context.l10n.charsN(rule.content.length),
    ].join(' · ');
    final btnSize = MediaQuery.sizeOf(context).width < 350 ? 32.0 : 36.0;
    final body = InkWell(
      onTap: onEdit,
      mouseCursor: SystemMouseCursors.grab,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 10 + btnSize * 2 + 12, 12),
        child: AnimatedOpacity(
          duration: Motion.fast,
          opacity: rule.enabled ? 1 : .45,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: onRename,
                child: Text(
                  ruleSectionLabel(rule.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                meta,
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Lifted(
      radius: BorderRadius.circular(16),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            RuleCardDragTarget(index: index, child: body),
            // 按钮独立命中，按住按钮不会启动拖动。
            Positioned(
              top: 0,
              bottom: 0,
              right: 10,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RoundIconBtn(
                    Icons.power_settings_new,
                    size: btnSize,
                    color: rule.enabled ? scheme.primary : scheme.outline,
                    tooltip: rule.enabled
                        ? context.l10n.disableKeepConfig
                        : context.l10n.enable,
                    onTap: () {
                      Haptics.selection();
                      onToggle();
                    },
                  ),
                  const SizedBox(width: 6),
                  RoundIconBtn(
                    Icons.delete_outline,
                    size: btnSize,
                    color: scheme.error,
                    tooltip: context.l10n.delete,
                    onTap: onDelete,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 去掉开头的空行和末尾空白,不动第一行的缩进。
String _tidy(String s) =>
    s.replaceFirst(RegExp(r'^(?:[ \t]*\r?\n)+'), '').trimRight();

/// 条件段卡头的小标签(如「漫画模式」),样式同预设卡标题后的标签。
class _CondTag extends StatelessWidget {
  const _CondTag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: context.texts.labelSmall!.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Future<void> _confirmLeave(BuildContext context) async {
  final ok = await confirmDialog(
    context,
    title: context.l10n.discardChangesQ,
    message: context.l10n.unsavedLost2,
    confirmLabel: context.l10n.discardAction,
  );
  if (ok && context.mounted) Navigator.pop(context);
}

/// 段落编辑页显示段名、条件标签和可编辑的正文。
/// 顶栏保存,没保存就返回要确认一下。
class _SectionEditorPage extends StatefulWidget {
  const _SectionEditorPage({required this.rule});

  final PresetRule rule;

  @override
  State<_SectionEditorPage> createState() => _SectionEditorPageState();
}

class _SectionEditorPageState extends State<_SectionEditorPage> {
  late final _ctl = TextEditingController(text: widget.rule.content);
  var _dirty = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save() {
    final content = _tidy(_ctl.text);
    if (content.trim().isEmpty) {
      hintSnack(
        context,
        context.l10n.ruleSectionEmpty,
        icon: Icons.error_outline,
      );
      return;
    }
    Navigator.pop(context, widget.rule.copyWith(content: content));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(ruleSectionLabel(widget.rule.name)),
          actions: [
            IconButton(
              tooltip: context.l10n.save,
              onPressed: _save,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            14,
            4,
            14,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [_block(context)],
        ),
      ),
    );
  }

  Widget _block(BuildContext context) {
    final scheme = context.scheme;
    final rule = widget.rule;
    return Lifted(
      radius: BorderRadius.circular(16),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      ruleSectionLabel(rule.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // 触发条件只显示,要改去全文编辑
                  if (whenTag(rule.when) case final tag?) _CondTag(tag),
                ],
              ),
            ),
            TextField(
              controller: _ctl,
              autofocus: rule.content.isEmpty,
              maxLines: null,
              minLines: 3,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              style: mono(context, size: 13, weight: FontWeight.w400),
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.fromLTRB(16, 4, 16, 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全文编辑:摊开的是导出的那份文本。保存时按导入同一套规矩读回来,读不通就
/// 原地报错、不关页面;没保存就返回要确认一下,几万字的规则丢了找不回来。
class _RulesEditorPage extends StatefulWidget {
  const _RulesEditorPage({required this.title, required this.text});

  final String title;
  final String text;

  @override
  State<_RulesEditorPage> createState() => _RulesEditorPageState();
}

class _RulesEditorPageState extends State<_RulesEditorPage> {
  late final _ctl = TextEditingController(text: widget.text);
  var _dirty = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save() {
    final RulesFile file;
    try {
      file = decodeRulesFile(_ctl.text);
    } on FormatException catch (e) {
      hintSnack(context, e.message, icon: Icons.error_outline);
      return;
    }
    // 导入时这两样能在弹层里补,这里没有弹层,文本里就得写全
    final missing = file.name.isEmpty
        ? context.l10n.missingPresetName
        : file.models.isEmpty
        ? context.l10n.missingModels
        : null;
    if (missing != null) {
      hintSnack(context, missing, icon: Icons.error_outline);
      return;
    }
    Navigator.pop(context, file);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: context.l10n.save,
              onPressed: _save,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        // 文本直接铺在页面上,不再套一层底色框:整页就是编辑区
        body: SafeArea(
          top: false,
          child: TextField(
            controller: _ctl,
            expands: true,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            autocorrect: false,
            enableSuggestions: false,
            style: mono(context, size: 13, weight: FontWeight.w400),
            onChanged: (_) {
              if (!_dirty) setState(() => _dirty = true);
            },
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            ),
          ),
        ),
      ),
    );
  }
}
