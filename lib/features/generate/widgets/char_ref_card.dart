import '../../../l10n/l10n.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/platform/desktop.dart';
import '../../../core/ui/image_drop.dart';
import '../../../core/util/image_pick.dart';
import '../../char_library/char_library.dart';
import '../../char_library/char_library_page.dart';
import '../canvas_state.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import '../display_names.dart';
import 'section_card.dart';
import 'reference_strip.dart';

/// 后台 isolate 算图片内容哈希(sha256 hex)。
String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

/// 角色参考卡:缩略图横条 + 选中详情(迁移模式 · Strength · Fidelity)。
/// 支持 4.5 角色参考与 V5 精确参考。
class CharRefCard extends ConsumerStatefulWidget {
  const CharRefCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  ConsumerState<CharRefCard> createState() => _CharRefCardState();
}

class _CharRefCardState extends ConsumerState<CharRefCard> {
  String? _selectedId;

  Future<void> _onAdd() async {
    final canvasId = ref.read(canvasWorkspaceProvider).activeId;
    final files = await pickImageFiles(context);
    if (files.isEmpty || !mounted) return;
    await _addImages(files, canvasId);
  }

  Future<void> _addImages(List<PickedImage> files, String canvasId) async {
    bool left() => ref.read(canvasWorkspaceProvider).activeId != canvasId;
    // 互斥态在加图前取一次:加角色参考会顺手停掉 Vibe
    final previous = ref.read(generateProvider);
    String? lastId;
    for (final f in files) {
      final bytes = f.bytes;
      final hash = await compute(_sha256Hex, bytes); // 后台算内容哈希
      if (!mounted || left()) return;
      // 顺手入库(同图去重;下次可从角色参考图库找回)
      try {
        await ref
            .read(charLibraryProvider.notifier)
            .importImageBytes(bytes, f.baseName, knownHash: hash);
      } catch (_) {
        // 入库失败不影响本次使用
      }
      if (!mounted || left()) return;
      lastId = ref
          .read(generateProvider.notifier)
          .addCharRef(image: bytes, name: f.baseName, imageHash: hash);
    }
    if (lastId == null) return;
    _mutexHint(previous); // 整批只提示一次
    setState(() => _selectedId = lastId);
  }

  void _toggle(String id, bool currentlyEnabled) {
    final previous = ref.read(generateProvider);
    ref
        .read(generateProvider.notifier)
        .setCharRefEnabled(id, !currentlyEnabled);
    if (!currentlyEnabled) _mutexHint(previous);
  }

  /// 互斥切换提示:启用/加入角色参考导致 Vibe 被暂停时,弹一次 toast。
  void _mutexHint(GenerateState previous) {
    final message = previous.params.isNaiMedium
        ? context.l10n.preciseRefUsesHigh
        : previous.enabledVibes > 0
        ? context.l10n.refMutexVibePaused
        : null;
    if (message != null) hintSnack(context, message, icon: Icons.swap_horiz);
  }

  void _remove(String id) {
    final refs = ref.read(generateProvider).charRefs;
    final idx = refs.indexWhere((r) => r.id == id);
    ref.read(generateProvider.notifier).removeCharRef(id);
    final rest = ref.read(generateProvider).charRefs;
    setState(() {
      if (rest.isEmpty) {
        _selectedId = null;
      } else if (id == _selectedId) {
        _selectedId = rest[idx.clamp(0, rest.length - 1)].id;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final refs = state.charRefs;
    final v5 = isNai5Model(state.params.model);
    // 无内容时恒收起;头部「+」导入后(addCharRef 会 openPanel)自动展开。
    final expanded =
        state.openPanels.contains(Panel.charRef) && refs.isNotEmpty;

    CharRefItem? selected;
    for (final r in refs) {
      if (r.id == _selectedId) {
        selected = r;
        break;
      }
    }
    selected ??= refs.isNotEmpty ? refs.first : null;

    final card = SectionCard(
      icon: Icons.face_retouching_natural,
      title: v5
          ? context.l10n.v5PreciseReference
          : context.l10n.preciseReference,
      reorderIndex: widget.reorderIndex,
      badge: refs.isEmpty ? null : CountBadge('${refs.length}'),
      actions: [
        RoundIconBtn(
          Icons.grid_view,
          tooltip: context.l10n.refLibrary,
          color: scheme.onSurfaceVariant,
          onTap: () => Navigator.of(
            context,
          ).push(sharedAxisRoute(const CharLibraryPage())),
        ),
        RoundIconBtn(
          Icons.add,
          // 与 Vibe 卡的同位按钮区分:两者互斥,tooltip 一样会让人分不清点了哪个
          tooltip: context.l10n.importCharRef,
          color: scheme.primary,
          onTap: _onAdd,
        ),
      ],
      expanded: expanded,
      onHeaderTap: () => notifier.togglePanel(Panel.charRef),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (v5 && state.inpaint != null) ...[
            InfoNote(context.l10n.v5ReferenceInpaint, icon: Icons.info_outline),
            const SizedBox(height: 12),
          ],
          ReferenceStrip(
            previewTitle: v5 ? context.l10n.v5PreciseReference : '角色参考图',
            items: [
              for (final r in refs)
                (id: r.id, image: r.image, enabled: r.enabled),
            ],
            selectedId: selected?.id,
            onSelect: (id) => setState(() => _selectedId = id),
            onReorder: notifier.reorderCharRefs,
          ),
          if (selected != null) ...[
            const SizedBox(height: 14),
            _CharRefDetail(
              item: selected,
              model: state.params.model,
              index: refs.indexOf(selected) + 1,
              onRemove: () => _remove(selected!.id),
              onToggle: () => _toggle(selected!.id, selected.enabled),
            ),
          ],
        ],
      ),
    );
    return ref.watch(desktopModeProvider)
        ? ImageDropRegion(
            key: ValueKey(
              ref.watch(canvasWorkspaceProvider.select((w) => w.activeId)),
            ),
            label: l10nNow.desktopAddCharacterReference,
            multiple: true,
            acceptPaste: true,
            onDrop: (images, _) =>
                _addImages(images, ref.read(canvasWorkspaceProvider).activeId),
            child: card,
          )
        : card;
  }
}

class _CharRefDetail extends ConsumerWidget {
  const _CharRefDetail({
    required this.item,
    required this.model,
    required this.index,
    required this.onRemove,
    required this.onToggle,
  });

  final CharRefItem item;
  final String model;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(generateProvider.notifier);
    final v5 = isNai5Model(model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RefDetailHeader(
          index: index,
          name: refDisplayName(context.l10n, item.name),
          onRemove: onRemove,
          enableToggle: RefEnableToggle(enabled: item.enabled, onTap: onToggle),
          leadingAction: _ReferenceModeMenu(
            value: item.mode,
            v5: v5,
            onChanged: (mode) => notifier.updateCharRef(item.id, mode: mode),
          ),
          leadingActionWidth: 100,
        ),
        const SizedBox(height: 14),
        if (!v5 && item.mode == CharRefMode.outfit)
          InfoNote(context.l10n.outfitNeedsV5, icon: Icons.info_outline),
        if (v5 && item.mode.hasOutfitPreference)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(context.l10n.refPreferSameOutfit),
            value: item.preferSameOutfit,
            onChanged: (checked) =>
                notifier.updateCharRef(item.id, preferSameOutfit: checked),
          ),
        LiveParamSlider(
          label: context.l10n.referenceStrength,
          help: Help.charRefStrength,
          value: item.strengthFor(model),
          max: v5 ? 5 : 1,
          divisions: 100,
          onCommit: (v) => notifier.updateCharRef(item.id, strength: v),
        ),
        if (!v5) ...[
          const SizedBox(height: 6),
          LiveParamSlider(
            label: context.l10n.fidelity,
            help: Help.fidelity,
            value: item.infoExtracted,
            divisions: 100,
            onCommit: (v) => notifier.updateCharRef(item.id, infoExtracted: v),
          ),
        ],
      ],
    );
  }
}

class _ReferenceModeMenu extends StatefulWidget {
  const _ReferenceModeMenu({
    required this.value,
    required this.v5,
    required this.onChanged,
  });

  final CharRefMode value;
  final bool v5;
  final ValueChanged<CharRefMode> onChanged;

  @override
  State<_ReferenceModeMenu> createState() => _ReferenceModeMenuState();
}

class _ReferenceModeMenuState extends State<_ReferenceModeMenu> {
  static const _gap = 3.0, _margin = 8.0;
  double _maxHeight = 240;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  double _room(BuildContext anchor) {
    final overlay =
        Overlay.of(anchor, rootOverlay: true).context.findRenderObject()!
            as RenderBox;
    final box = anchor.findRenderObject()! as RenderBox;
    final bottom = box
        .localToGlobal(Offset(0, box.size.height), ancestor: overlay)
        .dy;
    final media = MediaQuery.of(anchor);
    return (overlay.size.height -
            bottom -
            media.viewPadding.bottom -
            media.viewInsets.bottom -
            _gap -
            _margin)
        .clamp(1.0, 240.0);
  }

  Future<void> _toggle(
    BuildContext anchor,
    MenuController menu,
    int count,
  ) async {
    if (menu.isOpen) {
      menu.close();
      return;
    }
    if (_room(anchor) < count * 40 + 8) {
      await Scrollable.ensureVisible(anchor, alignment: .15);
      if (!anchor.mounted) return;
    }
    setState(() => _maxHeight = _room(anchor));
    menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final labels = {
      CharRefMode.both: l.refCharacterStyle,
      CharRefMode.character: l.refCharacter,
      CharRefMode.style: l.refStyle,
      CharRefMode.outfit: l.refOutfit,
    };
    final modes = (widget.v5 ? labels.keys : CharRefMode.values)
        .where((m) => widget.v5 || m != CharRefMode.outfit || m == widget.value)
        .toList();
    final scheme = context.scheme;
    return MenuAnchor(
      childFocusNode: _focus,
      useRootOverlay: true,
      consumeOutsideTap: true,
      reservedPadding: const EdgeInsets.all(_margin),
      alignmentOffset: const Offset(0, _gap),
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomStart,
        maximumSize: WidgetStatePropertyAll(Size(double.infinity, _maxHeight)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4),
        ),
      ),
      menuChildren: [
        for (final mode in modes)
          MenuItemButton(
            key: ValueKey(mode),
            onPressed: widget.v5 || mode != CharRefMode.outfit
                ? () => widget.onChanged(mode)
                : null,
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(136, 40)),
            ),
            trailingIcon: mode == widget.value
                ? Icon(Icons.check, size: 16, color: scheme.primary)
                : const SizedBox(width: 16),
            child: Text(labels[mode]!),
          ),
      ],
      builder: (anchor, menu, _) => TextButton(
        key: const ValueKey('reference-mode-menu'),
        focusNode: _focus,
        onPressed: () => _toggle(anchor, menu, modes.length),
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          textStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 13,
              decoration: states.contains(WidgetState.focused)
                  ? TextDecoration.underline
                  : null,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(labels[widget.value]!),
            Icon(
              Icons.arrow_drop_down,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
