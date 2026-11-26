import '../../../l10n/l10n.dart';
import 'canvas_history_sheet.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../canvas_state.dart';
import 'common.dart';

/// A compact canvas switcher above the desktop prompt controls.
class DesktopCanvasTabs extends ConsumerStatefulWidget {
  const DesktopCanvasTabs({super.key, this.trailing});
  final Widget? trailing;

  @override
  ConsumerState<DesktopCanvasTabs> createState() => _DesktopCanvasTabsState();
}

class _DesktopCanvasTabsState extends ConsumerState<DesktopCanvasTabs> {
  final _scroll = ScrollController(debugLabel: 'Desktop canvas tabs');
  List<double> _extents = const [];
  int _activeIndex = 0;
  double? _viewportWidth;
  bool _revealScheduled = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(String id) {
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(canvasWorkspaceProvider.notifier).select(id);
    _scheduleReveal();
  }

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scroll.hasClients || _extents.isEmpty) return;
      final position = _scroll.position;
      final left =
          10.0 + _extents.take(_activeIndex).fold(0.0, (a, b) => a + b);
      final right = left + _extents[_activeIndex];
      final target = left < position.pixels
          ? left
          : right > position.pixels + position.viewportDimension
          ? right - position.viewportDimension
          : position.pixels;
      if ((target - position.pixels).abs() < .5) return;
      _scroll.animateTo(
        target.clamp(0.0, _maxOffset),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  double get _maxOffset =>
      (20.0 +
              _extents.fold(0.0, (a, b) => a + b) -
              _scroll.position.viewportDimension)
          .clamp(0.0, double.infinity);

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final target = (_scroll.offset + delta).clamp(0.0, _maxOffset);
    if (target == _scroll.offset) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _scroll.jumpTo(target),
    );
  }

  Future<void> _handleAction(
    String action,
    CanvasDraft target,
    CanvasWorkspace workspace,
    CanvasWorkspaceNotifier canvases,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    switch (action) {
      case 'new':
        canvases.create();
      case 'duplicate':
        canvases.create(duplicate: true);
      case 'rename':
        if (target.id == workspace.defaultId) return;
        final name = await showDialog<String>(
          context: context,
          builder: (_) => _CanvasNameDialog(name: target.name),
        );
        if (name != null && mounted) {
          canvases.rename(target.id, name);
        }
      case 'remove':
        if (target.id == workspace.defaultId) return;
        final ok = await confirmDialog(
          context,
          title: '删除「${target.name}」？',
          message: l10nNow.desktopRemoveThisCanvasAndItsSettingsGeneratedImages,
          confirmLabel: '删除',
        );
        if (!ok || !mounted) return;
        final removed = canvases.remove(target.id);
        if (removed == null) return;
        hintSnack(
          context,
          l10nNow.desktopCanvasDeleted,
          actionLabel: '撤销',
          onAction: () => canvases.restore(
            removed.canvas,
            removed.index,
            activate: removed.wasActive,
          ),
        );
      case 'history':
        await showCanvasHistory(context, target);
      case 'shared':
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10nNow.desktopCanvasesAndReferences),
            content: Text(
              l10nNow.desktopEachCanvasKeepsItsOwnPromptsCharactersPresets,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10nNow.desktopGotIt),
              ),
            ],
          ),
        );
    }
  }

  List<PopupMenuEntry<String>> _menuItems(
    CanvasWorkspace workspace,
    CanvasDraft target,
  ) => [
    PopupMenuItem(value: 'new', child: Text(l10nNow.newCanvas)),
    PopupMenuItem(
      value: 'duplicate',
      child: Text(l10nNow.desktopDuplicateCurrentCanvas),
    ),
    PopupMenuItem(
      value: 'rename',
      enabled: target.id != workspace.defaultId,
      child: Text(l10nNow.rename),
    ),
    PopupMenuItem(
      value: 'remove',
      enabled: target.id != workspace.defaultId,
      child: Text(l10nNow.desktopDeleteCurrentCanvas),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(value: 'history', child: Text(l10nNow.desktopCanvasHistory)),
    PopupMenuItem(
      value: 'shared',
      child: Text(l10nNow.desktopCanvasesAndReferences),
    ),
  ];

  Future<void> _showContextMenu(
    Offset globalPosition,
    CanvasDraft target,
    CanvasWorkspace workspace,
    CanvasWorkspaceNotifier canvases,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _menuItems(workspace, target),
    );
    if (action != null && mounted) {
      await _handleAction(action, target, workspace, canvases);
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(canvasWorkspaceProvider);
    final canvases = ref.read(canvasWorkspaceProvider.notifier);
    final labelStyle = context.texts.labelLarge!;
    // Use the same measured widths for layout and revealing offscreen tabs.
    final extents = [
      for (final (index, canvas) in workspace.canvases.indexed)
        _tabExtent(context, canvas.name, labelStyle, draggable: index != 0),
    ];
    final activeIndex = workspace.canvases.indexWhere(
      (canvas) => canvas.id == workspace.activeId,
    );
    if (activeIndex != _activeIndex || !listEquals(extents, _extents)) {
      _activeIndex = activeIndex;
      _extents = extents;
      _scheduleReveal();
    }
    return DecoratedBox(
      key: const ValueKey('desktop-canvas-tabs'),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(
            color: context.scheme.outlineVariant.withValues(alpha: .7),
          ),
        ),
      ),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (_viewportWidth !=
                      notification.metrics.viewportDimension) {
                    _viewportWidth = notification.metrics.viewportDimension;
                    _scheduleReveal();
                  }
                  return false;
                },
                child: Listener(
                  onPointerSignal: _wheel,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      scrollbars: false,
                      dragDevices: {
                        ...ScrollConfiguration.of(context).dragDevices,
                        PointerDeviceKind.mouse,
                      },
                    ),
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      interactive: true,
                      thickness: 3,
                      radius: const Radius.circular(2),
                      scrollbarOrientation: ScrollbarOrientation.bottom,
                      child: ReorderableListView.builder(
                        scrollController: _scroll,
                        scrollDirection: Axis.horizontal,
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        itemExtentBuilder: (index, _) => extents[index],
                        // Build an inert preview: moving a visible Tooltip's
                        // OverlayPortal into the drag overlay can mutate layout.
                        proxyDecorator: (_, index, animation) => dragProxy(
                          IgnorePointer(
                            key: const ValueKey('desktop-canvas-drag-preview'),
                            child: _CanvasTab(
                              name: workspace.canvases[index].name,
                              selected:
                                  workspace.canvases[index].id ==
                                  workspace.activeId,
                              index: index,
                              labelStyle: labelStyle,
                              onSelect: () {},
                              preview: true,
                            ),
                          ),
                          index,
                          animation,
                        ),
                        onReorderItem: canvases.reorder,
                        itemCount: workspace.canvases.length,
                        itemBuilder: (context, index) {
                          final canvas = workspace.canvases[index];
                          return _CanvasTab(
                            key: ValueKey('desktop-canvas-${canvas.id}'),
                            name: canvas.name,
                            selected: canvas.id == workspace.activeId,
                            index: index,
                            labelStyle: labelStyle,
                            onSelect: () => _select(canvas.id),
                            onSecondaryTap: (pos) => _showContextMenu(
                              pos,
                              canvas,
                              workspace,
                              canvases,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (workspace.canvases.length > 1)
              SizedBox(
                width: 36,
                child: PopupMenuButton<String>(
                  key: const ValueKey('desktop-canvas-picker'),
                  tooltip: l10nNow.switchCanvas,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.expand_more, size: 20),
                  initialValue: workspace.activeId,
                  onSelected: _select,
                  itemBuilder: (_) => [
                    for (final canvas in workspace.canvases)
                      CheckedPopupMenuItem(
                        value: canvas.id,
                        checked: canvas.id == workspace.activeId,
                        child: Text(
                          canvas.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            SizedBox(
              width: 36,
              child: PopupMenuButton<String>(
                key: const ValueKey('desktop-canvas-actions'),
                tooltip: '画布操作',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.add, size: 20),
                onSelected: (action) => _handleAction(
                  action,
                  workspace.active,
                  workspace,
                  canvases,
                ),
                itemBuilder: (_) => _menuItems(workspace, workspace.active),
              ),
            ),
            if (widget.trailing != null) widget.trailing!,
          ],
        ),
      ),
    );
  }
}

class _CanvasTab extends StatelessWidget {
  const _CanvasTab({
    super.key,
    required this.name,
    required this.selected,
    required this.index,
    required this.labelStyle,
    required this.onSelect,
    this.onSecondaryTap,
    this.preview = false,
  });

  final String name;
  final bool selected;
  final int index;
  final TextStyle labelStyle;
  final VoidCallback onSelect;
  final ValueChanged<Offset>? onSecondaryTap;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final label = TextButton(
      onPressed: onSelect,
      style: TextButton.styleFrom(
        textStyle: labelStyle.copyWith(
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        foregroundColor: selected
            ? context.scheme.primary
            : context.scheme.onSurfaceVariant,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final handle = SizedBox(
      width: 22,
      height: 32,
      child: Icon(
        Icons.drag_indicator,
        size: 15,
        color: context.scheme.outline,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: onSecondaryTap == null
            ? null
            : (details) => onSecondaryTap!(details.globalPosition),
        child: Material(
          color: selected
              ? context.scheme.surfaceContainerLowest
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected
                  ? context.scheme.outlineVariant.withValues(alpha: .85)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: preview ? label : Tooltip(message: name, child: label),
              ),
              if (index != 0)
                preview
                    ? handle
                    : ReorderableDragStartListener(
                        index: index,
                        child: Tooltip(
                          message: '拖动画布排序',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: handle,
                          ),
                        ),
                      ),
            ],
          ),
        ),
      ),
    );
  }
}

double _tabExtent(
  BuildContext context,
  String name,
  TextStyle style, {
  required bool draggable,
}) {
  final text = TextPainter(
    text: TextSpan(text: name, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = text.width.clamp(36.0, 130.0) + 20 + (draggable ? 24 : 0) + 4;
  text.dispose();
  return width;
}

class _CanvasNameDialog extends StatefulWidget {
  const _CanvasNameDialog({required this.name});
  final String name;

  @override
  State<_CanvasNameDialog> createState() => _CanvasNameDialogState();
}

class _CanvasNameDialogState extends State<_CanvasNameDialog> {
  late final _text = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (_text.text.trim().isNotEmpty) Navigator.pop(context, _text.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名画布'),
    content: TextField(
      controller: _text,
      autofocus: true,
      maxLength: kCanvasNameMax,
      decoration: const InputDecoration(labelText: '画布名称'),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _text.text.trim().isEmpty ? null : _submit,
        child: const Text('保存'),
      ),
    ],
  );
}
