import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../assistant_models.dart';
import '../assistant_state.dart';

typedef ConversationEntry = ({String id, String label, bool queued});

/// Keeps the existing reversed, lazy chat list. Off-screen destinations are
/// sought using mounted rows, then aligned using their actual rendered bounds.
class ConversationNavigationController extends ChangeNotifier {
  ConversationNavigationController(this.scroll) {
    scroll.addListener(refresh);
  }

  final ScrollController scroll;
  final viewportKey = GlobalKey();
  final _keys = <String, GlobalKey>{};
  final _turnFor = <String, String>{};
  List<String> _ids = const [];
  List<ConversationEntry> entries = const [];
  String? activeId;
  bool awayFromBottom = false;
  bool seeking = false;
  bool _disposed = false;
  bool _refreshPending = false;
  int _request = 0;
  String? _conversation;

  GlobalKey keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  void update(AssistantState state, String liveKey) {
    final conversation =
        state.msgs.firstOrNull?.id ?? state.queue.firstOrNull?.id;
    final changed = conversation != _conversation;
    _conversation = conversation;
    if (changed) {
      cancel();
      activeId = null;
    }
    _ids = [
      for (final q in state.queue.reversed) q.id,
      if (state.running) liveKey,
      for (final m in state.msgs.reversed) m.id,
    ];
    _keys.removeWhere((id, _) => !_ids.contains(id));
    _turnFor.clear();
    final next = <ConversationEntry>[];
    String? turn;
    for (final msg in state.msgs) {
      if (msg.role == MsgRole.user) {
        turn = msg.id;
        next.add((id: msg.id, label: _label(msg.text), queued: false));
      }
      if (turn != null) _turnFor[msg.id] = turn;
    }
    if (turn != null) _turnFor[liveKey] = turn;
    for (final q in state.queue) {
      next.add((id: q.id, label: _label(q.text), queued: true));
      _turnFor[q.id] = q.id;
    }
    entries = next;
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && _ready) scroll.jumpTo(0);
      });
    }
    refresh();
  }

  static String _label(String text) {
    final compact = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return compact.isEmpty ? '图片提问' : compact;
  }

  bool get _ready =>
      scroll.hasClients &&
      scroll.positions.length == 1 &&
      scroll.position.hasContentDimensions;

  void cancel() {
    _request++;
    seeking = false;
  }

  void refresh() {
    if (_disposed || _refreshPending) return;
    _refreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshPending = false;
      if (_disposed) return;
      final away = _ready && scroll.offset > 64;
      String? visible;
      final viewport = viewportKey.currentContext?.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        var top = double.infinity;
        for (final item in _keys.entries) {
          final box = item.value.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) continue;
          final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
          if (y + box.size.height > 1 && y < viewport.size.height && y < top) {
            top = y;
            visible = _turnFor[item.key];
          }
        }
      }
      final next = !away ? entries.lastOrNull?.id : visible ?? activeId;
      if (away != awayFromBottom || (!seeking && activeId != next)) {
        awayFromBottom = away;
        if (!seeking) activeId = next;
        notifyListeners();
      }
    });
  }

  Future<void> toBottom() async {
    cancel();
    if (!_ready) return;
    await scroll.animateTo(0, duration: Motion.fast, curve: Motion.standard);
    refresh();
  }

  Future<bool> reveal(String id) async {
    final request = ++_request;
    seeking = true;
    activeId = id;
    notifyListeners();
    try {
      double? lower, upper;
      for (var attempt = 0; attempt < 80; attempt++) {
        if (_disposed || request != _request || !_ready) return false;
        final index = _ids.indexOf(id);
        if (index < 0) return false;
        final target = _keys[id]?.currentContext?.findRenderObject();
        if (target is RenderBox && target.attached && target.hasSize) {
          await scroll.position.ensureVisible(
            target,
            alignment: 1,
            duration: Motion.fast,
            curve: Motion.standard,
          );
          return !_disposed && request == _request;
        }
        final rows = <({int index, double offset})>[];
        for (final item in _keys.entries) {
          final box = item.value.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) continue;
          final at = _ids.indexOf(item.key);
          if (at < 0) continue;
          rows.add((
            index: at,
            offset: RenderAbstractViewport.of(
              box,
            ).getOffsetToReveal(box, 1).offset,
          ));
        }
        rows.sort((a, b) => a.index.compareTo(b.index));
        double destination;
        if (rows.isEmpty) {
          destination =
              scroll.position.maxScrollExtent *
              index /
              math.max(1, _ids.length - 1);
        } else {
          final nearest = rows.reduce(
            (a, b) => (a.index - index).abs() < (b.index - index).abs() ? a : b,
          );
          final span = rows.last.index - rows.first.index;
          final average = span > 0
              ? ((rows.last.offset - rows.first.offset) / span).abs().clamp(
                  48.0,
                  10000.0,
                )
              : 200.0;
          if (rows.last.index < index) lower = scroll.offset;
          if (rows.first.index > index) upper = scroll.offset;
          destination = lower != null && upper != null && upper > lower
              ? (lower + upper) / 2
              : nearest.offset + (index - nearest.index) * average;
        }
        destination = destination.clamp(0.0, scroll.position.maxScrollExtent);
        scroll.jumpTo(destination);
        // Explicitly schedule a frame even when clamped to an unchanged extent.
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
      }
      return false;
    } finally {
      if (!_disposed && request == _request) {
        seeking = false;
        refresh();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    scroll.removeListener(refresh);
    super.dispose();
  }
}

class ConversationNavigation extends StatefulWidget {
  const ConversationNavigation({
    super.key,
    required this.controller,
    required this.embedded,
    required this.child,
  });
  final ConversationNavigationController controller;
  final bool embedded;
  final Widget child;

  @override
  State<ConversationNavigation> createState() => _ConversationNavigationState();
}

class _ConversationNavigationState extends State<ConversationNavigation> {
  bool _open = false;

  Future<void> _reveal(String id) async {
    if (widget.embedded) setState(() => _open = false);
    final found = await widget.controller.reveal(id);
    if (!found && mounted && widget.controller.activeId == id) {
      // No dialog is needed when a conversation changed or the user cancelled.
      widget.controller.refresh();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final nav = widget.controller;
        final scheme = context.scheme;
        final width = widget.embedded
            ? math.min(260.0, box.maxWidth - 36)
            : (box.maxWidth * .22).clamp(128.0, 224.0);
        final reserved = widget.embedded ? 24.0 : width + 24;
        final panel = ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(120, box.maxHeight - 40),
          ),
          child: Material(
            key: ValueKey(
              widget.embedded
                  ? 'assistant-outline-drawer'
                  : 'assistant-outline',
            ),
            elevation: widget.embedded ? 6 : 2,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('对话目录', style: context.texts.titleSmall),
                      ),
                      if (widget.embedded)
                        IconButton(
                          tooltip: '收起目录',
                          onPressed: () => setState(() => _open = false),
                          icon: const Icon(Icons.chevron_right, size: 20),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
                if (nav.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('开始对话后显示提问', style: context.texts.bodySmall),
                  ),
                if (nav.entries.isNotEmpty)
                  Flexible(
                    child: ListView.builder(
                      key: const ValueKey('assistant-outline-list'),
                      primary: false,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                      itemCount: nav.entries.length,
                      itemBuilder: (context, i) {
                        final entry = nav.entries[i];
                        final selected = nav.activeId == entry.id;
                        return Tooltip(
                          message: entry.label,
                          child: Material(
                            color: selected
                                ? scheme.primaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              key: ValueKey('assistant-outline-${entry.id}'),
                              onTap: () => _reveal(entry.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 10,
                                ),
                                child: Text(
                                  '${i + 1}. ${entry.queued ? '待发送 · ' : ''}${entry.label}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.bodySmall?.copyWith(
                                    color: selected
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_open) setState(() => _open = false);
              nav.cancel();
            },
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                right: reserved,
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    nav.refresh();
                    return false;
                  },
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: (n) {
                      if (n.direction != ScrollDirection.idle) nav.cancel();
                      return false;
                    },
                    child: Listener(
                      onPointerDown: (_) => nav.cancel(),
                      onPointerSignal: (_) => nav.cancel(),
                      child: ClipRect(
                        key: nav.viewportKey,
                        child: widget.child,
                      ),
                    ),
                  ),
                ),
              ),
              if (!widget.embedded)
                Positioned.fill(
                  left: null,
                  right: 12,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(width: width, child: panel),
                  ),
                ),
              if (widget.embedded && !_open)
                Positioned.fill(
                  left: null,
                  right: 0,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Material(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(10),
                      ),
                      child: InkWell(
                        key: const ValueKey('assistant-outline-toggle'),
                        onTap: () => setState(() => _open = true),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 12,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.chevron_left, size: 18),
                              SizedBox(height: 6),
                              RotatedBox(quarterTurns: 1, child: Text('目录')),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (nav.awayFromBottom)
                Positioned(
                  right: reserved + 12,
                  bottom: 12,
                  child: Material(
                    elevation: 3,
                    color: scheme.primaryContainer,
                    shape: const CircleBorder(),
                    child: IconButton(
                      key: const ValueKey('assistant-to-bottom'),
                      tooltip: '回到底部',
                      onPressed: nav.toBottom,
                      icon: Icon(
                        Icons.vertical_align_bottom,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
              if (widget.embedded && _open)
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('assistant-outline-dismiss'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _open = false),
                  ),
                ),
              if (widget.embedded)
                Positioned.fill(
                  left: null,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_open,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: AnimatedSlide(
                        offset: _open ? Offset.zero : const Offset(1.1, 0),
                        duration: Motion.fast,
                        curve: Motion.standard,
                        child: ExcludeFocus(
                          excluding: !_open,
                          child: ExcludeSemantics(
                            excluding: !_open,
                            child: SizedBox(width: width, child: panel),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
