import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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
        final width = math.min(260.0, box.maxWidth - 36);
        final reserved = widget.embedded ? 24.0 : 0.0;
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
              if (!widget.embedded && nav.entries.isNotEmpty)
                Positioned.fill(
                  left: null,
                  right: 0,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _FisheyeOutline(
                      controller: nav,
                      maxHeight: math.max(40, box.maxHeight - 32),
                      maxWidth: math.min(320, box.maxWidth - 32),
                      onSelect: _reveal,
                    ),
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
                        tooltip: '回到底部',
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

/// A quiet edge index. A sliding window keeps individual ticks usable even in
/// very long chats; the wheel, keyboard and dragging past either edge reveal
/// the remaining turns without mounting all of their message widgets.
class _FisheyeOutline extends StatefulWidget {
  const _FisheyeOutline({
    required this.controller,
    required this.maxHeight,
    required this.maxWidth,
    required this.onSelect,
  });
  final ConversationNavigationController controller;
  final double maxHeight, maxWidth;
  final ValueChanged<String> onSelect;

  @override
  State<_FisheyeOutline> createState() => _FisheyeOutlineState();
}

class _FisheyeOutlineState extends State<_FisheyeOutline> {
  final _focus = FocusNode(debugLabel: 'Conversation tick navigation');
  double? _pointerY;
  bool _keyboard = false;
  bool _dragging = false;
  bool _inside = false;
  int _first = 0, _count = 1, _cursor = 0;
  double _pitch = 12, _height = 80, _margin = 32;
  String? _conversation, _lastSelected;
  Timer? _edgeScroll;

  List<ConversationEntry> get _entries => widget.controller.entries;
  bool get _expanded => _pointerY != null || _keyboard || _dragging;
  int get _active => math.max(
    0,
    _entries.indexWhere((e) => e.id == widget.controller.activeId),
  );
  int _indexAt(double y) => (_first + ((y - _margin) / _pitch).round()).clamp(
    _first,
    math.min(_entries.length - 1, _first + _count - 1),
  );

  void _select(int index) {
    if (_entries.isEmpty) return;
    final target = index.clamp(0, _entries.length - 1);
    _cursor = target;
    final id = _entries[target].id;
    if (_lastSelected == id && widget.controller.activeId == id) return;
    _lastSelected = id;
    widget.onSelect(id);
  }

  void _step(int index) {
    if (_entries.isEmpty) return;
    setState(() {
      _cursor = index.clamp(0, _entries.length - 1);
      _first = (_cursor - _count ~/ 2).clamp(
        0,
        math.max(0, _entries.length - _count),
      );
      _pointerY = null;
      _keyboard = true;
    });
    _select(_cursor);
  }

  void _point(double y, {bool select = false}) {
    if (_entries.isEmpty) return;
    setState(() {
      _pointerY = y.clamp(0, _height);
      _keyboard = false;
      _cursor = _indexAt(_pointerY!);
    });
    if (select) _select(_cursor);
  }

  void _stopDrag() {
    _edgeScroll?.cancel();
    _edgeScroll = null;
    if (mounted) {
      setState(() {
        _dragging = false;
        if (!_inside) _pointerY = null;
      });
    }
  }

  void _startDrag(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    _focus.requestFocus();
    _dragging = true;
    _point(event.localPosition.dy, select: true);
    _edgeScroll?.cancel();
    _edgeScroll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final y = _pointerY;
      if (!mounted || !_dragging || y == null || _entries.isEmpty) return;
      final delta = y < _margin / 2
          ? -1
          : y > _height - _margin / 2
          ? 1
          : 0;
      final next = (_first + delta).clamp(
        0,
        math.max(0, _entries.length - _count),
      );
      if (delta == 0 || next == _first) return;
      setState(() => _first = next.toInt());
      _point(y, select: true);
    });
  }

  @override
  void dispose() {
    _edgeScroll?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries.isEmpty) return const SizedBox.shrink();
    if (_conversation != entries.first.id) {
      _conversation = entries.first.id;
      _pointerY = null;
      _keyboard = _dragging = false;
      _edgeScroll?.cancel();
      _lastSelected = null;
    }
    final scheme = context.scheme;
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final lensScale = math.max(1.0, scale);
    _pitch = 12 * lensScale;
    _margin = math.min(44 * lensScale, widget.maxHeight / 4);
    _count = math.min(
      entries.length,
      math.max(
        1,
        ((math.min(420, widget.maxHeight) - _margin * 2) / _pitch).floor() + 1,
      ),
    );
    _height = (_count - 1) * _pitch + _margin * 2;
    if (!_expanded) {
      _cursor = _active;
      _first = (_cursor - _count ~/ 2).clamp(
        0,
        math.max(0, entries.length - _count),
      );
    }
    _first = _first.clamp(0, math.max(0, entries.length - _count));
    _cursor = _cursor.clamp(0, entries.length - 1);
    final focusY = _pointerY ?? _margin + (_cursor - _first) * _pitch;
    final expanded = _expanded;
    return Focus(
      focusNode: _focus,
      onFocusChange: (focused) {
        if (!mounted) return;
        setState(() => _keyboard = focused && _pointerY == null);
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowUp:
            _step(_cursor - 1);
          case LogicalKeyboardKey.arrowDown:
            _step(_cursor + 1);
          case LogicalKeyboardKey.home:
            _step(0);
          case LogicalKeyboardKey.end:
            _step(entries.length - 1);
          case LogicalKeyboardKey.escape:
            _focus.unfocus();
            setState(() {
              _pointerY = null;
              _keyboard = false;
            });
          default:
            return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: '对话导航',
        value: '第 ${_active + 1} 轮，共 ${entries.length} 轮',
        increasedValue:
            '第 ${math.min(entries.length, _active + 2)} 轮，共 ${entries.length} 轮',
        decreasedValue: '第 ${math.max(1, _active)} 轮，共 ${entries.length} 轮',
        hint: '点击或按住滑动定位；滚轮和上下键逐轮切换，Home 和 End 跳到首尾',
        onIncrease: () => _step(_active + 1),
        onDecrease: () => _step(_active - 1),
        child: MouseRegion(
          key: const ValueKey('assistant-tick-navigation'),
          cursor: _dragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.click,
          onEnter: (e) {
            _inside = true;
            _point(e.localPosition.dy);
          },
          onHover: (e) => _point(e.localPosition.dy),
          onExit: (_) {
            _inside = false;
            if (!_dragging) {
              setState(() {
                _pointerY = null;
                _keyboard = false;
              });
            }
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _startDrag,
            onPointerMove: (e) {
              if (_dragging) _point(e.localPosition.dy, select: true);
            },
            onPointerUp: (e) {
              if (_dragging) {
                _point(e.localPosition.dy, select: true);
                _stopDrag();
              }
            },
            onPointerCancel: (_) {
              _stopDrag();
              setState(() => _pointerY = null);
            },
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
                GestureBinding.instance.pointerSignalResolver.register(
                  e,
                  (_) => _step(_cursor + (e.scrollDelta.dy > 0 ? 1 : -1)),
                );
              }
            },
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: expanded ? 1 : 0),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : Motion.fast,
              curve: Motion.standard,
              builder: (context, open, _) => SizedBox(
                width: open > 0 ? widget.maxWidth : 44,
                height: _height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < _count; i++) ...[
                      Builder(
                        builder: (context) {
                          final index = _first + i;
                          final entry = entries[index];
                          final baseY = _margin + i * _pitch;
                          final distance = baseY - focusY;
                          final influence = math.exp(
                            -math.pow(distance / (_pitch * 2.2), 2) / 2,
                          );
                          // Stretch the nearest tick spacing smoothly, keeping both
                          // ends in the margin so the lens never clips the window.
                          final bend =
                              (2 /
                                      (1 +
                                          math.exp(
                                            -distance / (12 * lensScale),
                                          )) -
                                  1) *
                              math.min(36 * lensScale, _margin - 4) *
                              open;
                          final y = baseY + bend;
                          final active = widget.controller.activeId == entry.id;
                          final length =
                              (active ? 20.0 : 12.0) + 24 * influence * open;
                          final showLabel =
                              (_cursor - index).abs() <= 2 && open > 0;
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                key: ValueKey('assistant-tick-${entry.id}'),
                                right: 12,
                                top: y - 1.5,
                                width: length,
                                height: 3,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(3),
                                    color: active
                                        ? scheme.onSurface
                                        : Color.lerp(
                                            scheme.outlineVariant,
                                            scheme.onSurface,
                                            influence * open * .75,
                                          ),
                                  ),
                                ),
                              ),
                              if (showLabel)
                                Positioned(
                                  right: 64,
                                  left: 0,
                                  top: y - 12 * scale,
                                  child: IgnorePointer(
                                    child: Opacity(
                                      opacity: open * (.25 + .75 * influence),
                                      child: Transform.scale(
                                        scale: .9 + .1 * influence,
                                        alignment: Alignment.centerRight,
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          child: Container(
                                            key: ValueKey(
                                              'assistant-tick-label-${entry.id}',
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: scheme.surfaceContainerLow,
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: scheme.shadow
                                                      .withValues(alpha: .08),
                                                  blurRadius: 8,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            child: Text(
                                              '${index + 1} · ${entry.queued ? '待发送 · ' : ''}${entry.label}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: context.texts.bodySmall
                                                  ?.copyWith(
                                                    fontSize: 13,
                                                    height: 1.35,
                                                    color: scheme.onSurface,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
