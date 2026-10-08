import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../canvas_state.dart';
import 'common.dart';

/// A compact canvas switcher above the desktop prompt controls.
class DesktopCanvasTabs extends ConsumerWidget {
  const DesktopCanvasTabs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(canvasWorkspaceProvider);
    final canvases = ref.read(canvasWorkspaceProvider.notifier);
    return SizedBox(
      key: const ValueKey('desktop-canvas-tabs'),
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(left: 10),
              onReorderItem: canvases.reorder,
              itemCount: workspace.canvases.length,
              itemBuilder: (context, index) {
                final canvas = workspace.canvases[index];
                final selected = canvas.id == workspace.activeId;
                return Padding(
                  key: ValueKey('desktop-canvas-${canvas.id}'),
                  padding: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
                  child: Material(
                    color: selected
                        ? context.scheme.primaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: TextButton(
                            onPressed: () {
                              FocusManager.instance.primaryFocus?.unfocus();
                              canvases.select(canvas.id);
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: selected
                                  ? context.scheme.primary
                                  : context.scheme.onSurfaceVariant,
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            child: Text(
                              canvas.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        if (index != 0)
                          ReorderableDragStartListener(
                            index: index,
                            child: Tooltip(
                              message: '拖动画布排序',
                              child: Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 17,
                                  color: context.scheme.outline,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('desktop-canvas-actions'),
            tooltip: '画布操作',
            icon: const Icon(Icons.add, size: 20),
            onSelected: (action) async {
              FocusManager.instance.primaryFocus?.unfocus();
              final active = workspace.active;
              switch (action) {
                case 'new':
                  canvases.create();
                case 'duplicate':
                  canvases.create(duplicate: true);
                case 'rename':
                  final name = await showDialog<String>(
                    context: context,
                    builder: (_) => _CanvasNameDialog(name: active.name),
                  );
                  if (name != null && context.mounted) {
                    canvases.rename(active.id, name);
                  }
                case 'remove':
                  final ok = await confirmDialog(
                    context,
                    title: '删除「${active.name}」？',
                    message: '移除这张画布的提示词和参数，已生成的图片会保留。',
                    confirmLabel: '删除',
                  );
                  if (!ok || !context.mounted) return;
                  final removed = canvases.remove(active.id);
                  if (removed == null) return;
                  hintSnack(
                    context,
                    '已删除画布',
                    actionLabel: '撤销',
                    onAction: () => canvases.restore(
                      removed.canvas,
                      removed.index,
                      activate: removed.wasActive,
                    ),
                  );
                case 'shared':
                  await showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('画布与参考图'),
                      content: const Text(
                        '每张画布分别保存提示词、角色、预设和采样参数。\n\nVibe、角色参考、图生图、重绘和 LoRA 在画布之间共享。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'new', child: Text('新建画布')),
              const PopupMenuItem(value: 'duplicate', child: Text('复制当前画布')),
              PopupMenuItem(
                value: 'rename',
                enabled: workspace.activeId != workspace.defaultId,
                child: const Text('重命名'),
              ),
              PopupMenuItem(
                value: 'remove',
                enabled: workspace.activeId != workspace.defaultId,
                child: const Text('删除当前画布'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'shared', child: Text('画布与参考图')),
            ],
          ),
        ],
      ),
    );
  }
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
