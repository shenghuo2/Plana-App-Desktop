import '../../../l10n/l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/section_navigation.dart';
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
      // Scrubbing can replace several destinations in one frame. Let pending
      // jumps lay out before trusting a mounted row from the previous viewport.
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
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
  Future<void> _reveal(String id) async {
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
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              nav.cancel();
            },
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
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
                        child: widget.embedded
                            ? widget.child
                            : Align(
                                alignment: Alignment.topCenter,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 960,
                                  ),
                                  child: widget.child,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              if (nav.entries.isNotEmpty)
                Positioned.fill(
                  left: null,
                  right: 0,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SectionNavigation<ConversationEntry>(
                      entries: nav.entries,
                      activeIndex: nav.entries.indexWhere(
                        (e) => e.id == nav.activeId,
                      ),
                      idOf: (e) => e.id,
                      labelOf: (e) => e.queued ? '待发送 · ${e.label}' : e.label,
                      keyPrefix: 'assistant',
                      semanticLabel: l10nNow.desktopChatNavigation,
                      describePosition: (n) =>
                          '第 $n 轮，共 ${nav.entries.length} 轮',
                      hint: '点击或按住滑动定位；滚轮和上下键逐轮切换，Home 和 End 跳到首尾',
                      maxHeight: math.max(40, box.maxHeight - 32),
                      maxWidth: math.min(320, box.maxWidth - 32),
                      onSelect: (index) => _reveal(nav.entries[index].id),
                    ),
                  ),
                ),
              if (nav.awayFromBottom)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Center(
                    child: Material(
                      elevation: 1,
                      color: scheme.surfaceContainerLow,
                      shape: CircleBorder(
                        side: BorderSide(color: scheme.outlineVariant),
                      ),
                      child: IconButton(
                        key: const ValueKey('assistant-to-bottom'),
                        tooltip: l10nNow.desktopScrollToBottom,
                        onPressed: nav.toBottom,
                        icon: Icon(
                          Icons.arrow_downward,
                          color: scheme.onSurface,
                          size: 20,
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
