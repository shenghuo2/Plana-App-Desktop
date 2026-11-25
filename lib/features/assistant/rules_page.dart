/// 规则预设页:一张卡一份预设。
///
/// 默认规则按模型分两张(v4.5 版、v5 版),名称、作者、版本读内置那份的 meta。
/// 点卡进预设页([RulesPresetDetailPage]);卡上直接摆副本、导出、删除。
/// 支持的模型列在标题旁，启用的模型在预设详情页里改。
/// 每个模型恰好有一份在用,默认规则兜底。
library;

import 'widgets/assistant_tag.dart';

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../core/theme/app_skin.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/image_drop.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'presets/default_rules.dart';
import 'presets/preset_rule.dart';
import 'presets/rules_file.dart';
import 'presets/rules_library.dart';
import 'rules_preset_detail_page.dart';
import 'widgets/rule_card_drag_target.dart';
import '../../l10n/l10n.dart';

class RulesPresetPage extends ConsumerWidget {
  const RulesPresetPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(rulesLibraryProvider).value;
    final presets = library?.all;
    return ImageDropRegion.files(
      label: context.l10n.importRulePreset,
      enabled: presets != null,
      onFiles: (files) => _importDropped(context, ref, files),
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.rulePresets),
          actions: [
            IconButton(
              tooltip: context.l10n.importLabel,
              onPressed: () => _import(context, ref),
              icon: const Icon(Icons.file_open_outlined),
            ),
            IconButton(
              tooltip: context.l10n.newPreset,
              onPressed: presets == null ? null : () => _create(context, ref),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        body: presets == null
            ? const Center(child: CircularProgressIndicator())
            : ReorderableListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                buildDefaultDragHandles: false,
                onReorderItem: (from, to) => ref
                    .read(rulesLibraryProvider.notifier)
                    .move(presets[from].id, presets[to].id),
                proxyDecorator: (child, _, _) => Material(
                  color: Colors.transparent,
                  elevation: 3,
                  borderRadius: BorderRadius.circular(16),
                  child: child,
                ),
                children: [
                  for (final (index, p) in presets.indexed)
                    Padding(
                      key: ValueKey(p.id),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _card(
                        context,
                        ref,
                        p,
                        index,
                        library!.enabledFor(p.id),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _card(
    BuildContext context,
    WidgetRef ref,
    RulesPreset p,
    int index,
    Set<RulesFamily> enabled,
  ) {
    void toggle() => ref.read(rulesLibraryProvider.notifier).togglePreset(p.id);
    void open() => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => p.kind == RulesPresetKind.standard
            ? RulesPresetDetailPage(family: p.models.single)
            : RulesPresetDetailPage(presetId: p.id),
      ),
    );

    if (p.kind == RulesPresetKind.standard) {
      // 默认规则只支持一个模型;名称(带版本)、作者读内置那份,没读到时用占位值
      final f = p.models.single;
      final info = ref.watch(defaultRulesProvider(f)).value;
      return _PresetCard(
        index: index,
        title: info?.displayName ?? defaultRulesFallbackName(f),
        subtitle: [
          info?.author ?? p.author,
          if (info != null) l10nNow.sectionsN(info.rules.length),
        ].where((s) => s.isNotEmpty).join(' · '),
        isDefault: true,
        models: p.models,
        onOpen: open,
        enabled: enabled,
        onToggle: toggle,
        onCopy: () => _duplicate(context, ref, p),
        onExport: () => _exportDefault(context, ref, f),
      );
    }
    return _PresetCard(
      index: index,
      title: p.name,
      onEditYaml: p.isDefault ? null : () => _edit(context, ref, p),
      subtitle: [
        if (p.author.isNotEmpty) p.author,
        l10nNow.sectionsN(p.rules.length),
      ].join(' · '),
      isDefault: p.isDefault,
      models: p.models,
      onOpen: open,
      enabled: enabled,
      onToggle: toggle,
      onCopy: () => _duplicate(context, ref, p),
      onExport: () => _save(
        context,
        name: p.name,
        author: p.author,
        models: p.models,
        rules: p.rules,
        fileName: 'plana-rules-${_safe(p.name)}.yaml',
      ),
      onDelete: p.isDefault ? null : () => _delete(context, ref, p),
    );
  }

  /// 副本:段落、作者、支持的模型照抄,名字后面加「(副本)」,不自动启用。
  Future<void> _duplicate(
    BuildContext context,
    WidgetRef ref,
    RulesPreset p,
  ) async {
    final String base;
    final String author;
    final Set<RulesFamily> models;
    final List<PresetRule> rules;
    if (p.kind == RulesPresetKind.standard) {
      final f = p.models.single;
      final d = await bundledDefaultRules(f);
      base = d.displayName;
      author = d.author;
      models = {f};
      rules = d.rules;
    } else {
      base = p.name;
      author = p.author;
      models = p.models;
      rules = p.rules;
    }
    final name = (ref.read(rulesLibraryProvider).value ?? const RulesLibrary())
        .copyNameOf(base);
    await ref
        .read(rulesLibraryProvider.notifier)
        .add(name: name, author: author, models: models, rules: rules);
    if (context.mounted) {
      hintSnack(
        context,
        context.l10n.savedAsNamed(name),
        icon: Icons.check_circle_outline,
      );
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    final picked = res?.files.firstOrNull;
    final bytes = picked?.bytes;
    if (picked == null || bytes == null || !context.mounted) return;
    await _importFile(context, ref, bytes, picked.name);
  }

  Future<void> _importDropped(
    BuildContext context,
    WidgetRef ref,
    List<String> files,
  ) async {
    for (final name in files) {
      if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final file = File(name);
      final base = path.basename(name);
      try {
        if (!{
          '.yaml',
          '.yml',
          '.json',
        }.contains(path.extension(base).toLowerCase())) {
          throw FormatException(context.l10n.rulesDropUnsupported(base));
        }
        final bytes = await file.readAsBytes();
        if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        await _importFile(context, ref, bytes, base);
      } on FileSystemException {
        if (context.mounted) {
          hintSnack(
            context,
            context.l10n.rulesDropUnreadable(base),
            icon: Icons.error_outline,
          );
        }
      } on FormatException catch (e) {
        if (context.mounted) {
          hintSnack(context, e.message, icon: Icons.error_outline);
        }
      }
    }
  }

  Future<void> _importFile(
    BuildContext context,
    WidgetRef ref,
    List<int> bytes,
    String name,
  ) async {
    final RulesFile file;
    try {
      file = decodeRulesFile(utf8.decode(bytes), fileName: name);
    } on FormatException catch (e) {
      hintSnack(context, e.message, icon: Icons.error_outline);
      return;
    } catch (_) {
      hintSnack(context, context.l10n.notUtf8, icon: Icons.error_outline);
      return;
    }

    // 名字、作者、模型让用户过一眼:服务端预设文件里压根没写这几样,
    // 文件里写了的也可能想改个自己认得出的名字
    final conditional = file.rules.any((r) => r.when.isNotEmpty);
    final meta = await showModalBottomSheet<_PresetMeta>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PresetMetaSheet(
        title: context.l10n.importRulePreset,
        subtitle: [
          context.l10n.totalSectionsN(file.rules.length),
          if (conditional) context.l10n.hasConditional,
        ].join(' · '),
        action: context.l10n.importLabel,
        name: file.name,
        author: file.author,
        models: file.models,
      ),
    );
    if (meta == null || !context.mounted) return;
    await ref
        .read(rulesLibraryProvider.notifier)
        .add(
          name: meta.name,
          author: meta.author,
          models: meta.models,
          rules: file.rules,
        );
    if (context.mounted) {
      hintSnack(
        context,
        context.l10n.importedNamed(meta.name),
        icon: Icons.check_circle_outline,
      );
    }
  }

  Future<void> _create(BuildContext context, WidgetRef ref) {
    final draft = ref
        .read(rulesLibraryProvider.notifier)
        .newDraft(context.l10n.newPreset);
    return Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RulesPresetDetailPage.newPreset(draft: draft),
      ),
    );
  }

  /// 默认规则导出时名字用显示名(「Nyako v5」),两份导进来才分得开。
  Future<void> _exportDefault(
    BuildContext context,
    WidgetRef ref,
    RulesFamily f,
  ) async {
    try {
      final d = await bundledDefaultRules(f);
      if (!context.mounted) return;
      await _save(
        context,
        name: d.displayName,
        author: d.author,
        models: {f},
        rules: d.rules,
        fileName: 'plana-rules-${_safe(d.displayName)}.yaml',
      );
    } catch (e) {
      if (context.mounted) {
        hintSnack(
          context,
          context.l10n.exportFailed('$e'),
          icon: Icons.error_outline,
        );
      }
    }
  }

  Future<RulesFile?> _openEditor(
    BuildContext context, {
    required String title,
    required String text,
  }) => Navigator.push<RulesFile>(
    context,
    MaterialPageRoute(
      builder: (_) => _RulesEditorPage(title: title, text: text),
    ),
  );

  /// 全文编辑导入的预设,存回原处。
  Future<void> _edit(BuildContext context, WidgetRef ref, RulesPreset p) async {
    final file = await _openEditor(
      context,
      title: p.name,
      text: encodeRulesFile(
        name: p.name,
        author: p.author,
        models: p.models,
        rules: p.rules,
      ),
    );
    if (file == null) return;
    await ref
        .read(rulesLibraryProvider.notifier)
        .replace(
          p.id,
          name: file.name,
          author: file.author,
          models: file.models,
          rules: file.rules,
        );
    if (context.mounted) {
      hintSnack(
        context,
        l10nNow.savedNamed(file.name),
        icon: Icons.check_circle_outline,
      );
    }
  }

  Future<void> _save(
    BuildContext context, {
    required String name,
    required String author,
    required Set<RulesFamily> models,
    required List<PresetRule> rules,
    required String fileName,
  }) async {
    try {
      final path = await FilePicker.platform.saveFile(
        fileName: fileName,
        bytes: utf8.encode(
          encodeRulesFile(
            name: name,
            author: author,
            models: models,
            rules: rules,
          ),
        ),
      );
      if (path != null && context.mounted) {
        hintSnack(
          context,
          context.l10n.exportedNamed(name),
          icon: Icons.check_circle_outline,
        );
      }
    } catch (e) {
      if (context.mounted) {
        hintSnack(
          context,
          context.l10n.exportFailed('$e'),
          icon: Icons.error_outline,
        );
      }
    }
  }

  /// 文件名里别带路径分隔符和系统不认的字符。
  String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    RulesPreset p,
  ) async {
    final ok = await confirmDialog(
      context,
      title: context.l10n.deletePresetQ,
      message: context.l10n.deleteRulePresetBody(p.name),
      confirmLabel: context.l10n.delete,
    );
    if (!ok) return;
    await ref.read(rulesLibraryProvider.notifier).remove(p.id);
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.isDefault,
    required this.models,
    required this.onOpen,
    required this.enabled,
    required this.onToggle,
    required this.onCopy,
    required this.onExport,
    this.onDelete,
    this.onEditYaml,
  });

  final int index;
  final String title;
  final String subtitle;
  final bool isDefault;

  /// 这份支持的模型。
  final Set<RulesFamily> models;

  final VoidCallback onOpen;
  final Set<RulesFamily> enabled;
  final VoidCallback onToggle;
  final VoidCallback onCopy;
  final VoidCallback onExport;

  /// 默认规则删不了,传 null。
  final VoidCallback? onDelete;
  final VoidCallback? onEditYaml;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    Widget btn(IconData icon, String tip, VoidCallback onTap, Color color) =>
        IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon, size: 19, color: color),
        );
    return Lifted(
      radius: BorderRadius.circular(16),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          mouseCursor: SystemMouseCursors.grab,
          child: Stack(
            children: [
              // 空白处从底层开始拖动，内容和操作按钮在前面各自响应。
              Positioned.fill(
                child: RuleCardDragTarget(
                  index: index,
                  child: const SizedBox.expand(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 6, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: RuleCardDragTarget(
                        index: index,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 6,
                              runSpacing: 3,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.bodyLarge!.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (isDefault)
                                  AssistantTag(context.l10n.presetGroupDefault),
                                for (final model in RulesFamily.values)
                                  if (models.contains(model))
                                    AssistantTag(
                                      rulesFamilyLabel(model),
                                      active: enabled.contains(model),
                                    ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              style: context.texts.labelSmall!.copyWith(
                                color: scheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 副本、导出、删除直接摆出来,不收进菜单
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: enabled.isEmpty
                          ? context.l10n.enable
                          : context.l10n.disableKeepConfig,
                      visualDensity: VisualDensity.compact,
                      isSelected: enabled.isNotEmpty,
                      onPressed: onToggle,
                      icon: Icon(
                        Icons.power_settings_new,
                        size: 19,
                        color: scheme.outline,
                      ),
                      selectedIcon: Icon(
                        Icons.power_settings_new,
                        size: 19,
                        color: scheme.primary,
                      ),
                    ),
                    if (onEditYaml != null)
                      btn(
                        Icons.code,
                        context.l10n.edit,
                        onEditYaml!,
                        scheme.onSurfaceVariant,
                      ),
                    btn(
                      Icons.copy_all_outlined,
                      context.l10n.duplicatePreset,
                      onCopy,
                      scheme.onSurfaceVariant,
                    ),
                    btn(
                      Icons.ios_share,
                      context.l10n.export,
                      onExport,
                      scheme.onSurfaceVariant,
                    ),
                    if (onDelete != null)
                      btn(
                        Icons.delete_outline,
                        context.l10n.delete,
                        onDelete!,
                        scheme.error.withValues(alpha: .85),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题后面那几枚小标签:默认、支持的模型。
typedef _PresetMeta = ({String name, String author, Set<RulesFamily> models});

/// 导入前核对文件里的名字、作者和支持的模型。
class _PresetMetaSheet extends StatefulWidget {
  const _PresetMetaSheet({
    required this.title,
    required this.action,
    this.subtitle,
    required this.name,
    required this.author,
    required this.models,
  });

  final String title;

  /// 底下那颗按钮的字。
  final String action;
  final String? subtitle;
  final String name;
  final String author;
  final Set<RulesFamily> models;

  @override
  State<_PresetMetaSheet> createState() => _PresetMetaSheetState();
}

class _PresetMetaSheetState extends State<_PresetMetaSheet> {
  late final _name = TextEditingController(text: widget.name);
  late final _author = TextEditingController(text: widget.author);
  late final Set<RulesFamily> _models = {...widget.models};

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    super.dispose();
  }

  bool get _ok => _name.text.trim().isNotEmpty && _models.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: context.texts.titleMedium!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (widget.subtitle case final s?) ...[
            const SizedBox(height: 4),
            Text(
              s,
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.l10n.presetName,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _author,
            decoration: InputDecoration(
              labelText: context.l10n.author,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.supportedModels,
            style: context.texts.labelLarge!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final f in RulesFamily.values)
                FilterChip(
                  label: Text(rulesFamilyLabel(f)),
                  selected: _models.contains(f),
                  onSelected: (v) =>
                      setState(() => v ? _models.add(f) : _models.remove(f)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _ok
                ? () => Navigator.pop(context, (
                    name: _name.text.trim(),
                    author: _author.text.trim(),
                    models: {..._models},
                  ))
                : null,
            child: Text(widget.action),
          ),
        ],
      ),
    );
  }
}

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
        ? l10nNow.missingPresetName
        : file.models.isEmpty
        ? l10nNow.missingModels
        : null;
    if (missing != null) {
      hintSnack(context, missing, icon: Icons.error_outline);
      return;
    }
    Navigator.pop(context, file);
  }

  Future<void> _confirmLeave() async {
    final ok = await confirmDialog(
      context,
      title: l10nNow.discardChangesQ,
      message: l10nNow.unsavedLost2,
      confirmLabel: l10nNow.discardAction,
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: l10nNow.save,
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
            // YAML 靠缩进和原样的键名,输入法的自动更正只会帮倒忙
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
