import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// A window of edge markers for jumping between sections of a long scrollable.
class SectionNavigation<T> extends StatefulWidget {
  const SectionNavigation({
    super.key,
    required this.entries,
    required this.activeIndex,
    required this.idOf,
    required this.labelOf,
    required this.onSelect,
    required this.maxHeight,
    required this.maxWidth,
    required this.keyPrefix,
    required this.semanticLabel,
    required this.describePosition,
    required this.hint,
    this.ticksOnly = false,
  });

  final List<T> entries;
  final int activeIndex;
  final String Function(T) idOf, labelOf;
  final ValueChanged<int> onSelect;
  final double maxHeight, maxWidth;
  final String keyPrefix, semanticLabel, hint;
  final String Function(int position) describePosition;

  /// Let content under the floating labels receive clicks and wheel events.
  final bool ticksOnly;

  @override
  State<SectionNavigation<T>> createState() => _SectionNavigationState<T>();
}

class _SectionNavigationState<T> extends State<SectionNavigation<T>> {
  static const _maxTickLength = 40.0;
  static const _rightInset = 12.0;
  final _focus = FocusNode(debugLabel: 'Section navigation');
  double? _pointerY;
  bool _keyboard = false;
  bool _dragging = false;
  bool _inside = false;
  int _first = 0, _count = 1, _cursor = 0;
  double _pitch = 12, _height = 80, _margin = 32;
  String? _firstId, _lastSelected;
  Timer? _edgeScroll;

  List<T> get _entries => widget.entries;
  bool get _expanded => _pointerY != null || _keyboard || _dragging;
  int get _active => math.max(0, widget.activeIndex);
  int _indexAt(double y) => (_first + ((y - _margin) / _pitch).round()).clamp(
    _first,
    math.min(_entries.length - 1, _first + _count - 1),
  );

  void _select(int index) {
    if (_entries.isEmpty) return;
    final target = index.clamp(0, _entries.length - 1);
    _cursor = target;
    final id = widget.idOf(_entries[target]);
    if (_lastSelected == id && (_dragging || target == widget.activeIndex)) {
      return;
    }
    _lastSelected = id;
    widget.onSelect(target);
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

  void _leaveRail() {
    _inside = false;
    if (_dragging && !widget.ticksOnly) return;
    _edgeScroll?.cancel();
    _edgeScroll = null;
    setState(() {
      _dragging = false;
      _pointerY = null;
      _keyboard = false;
    });
  }

  void _startDrag(PointerDownEvent event, double yInset) {
    if (event.buttons != kPrimaryButton) return;
    _focus.requestFocus();
    _lastSelected = null;
    _dragging = true;
    _point(event.localPosition.dy + yInset, select: true);
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
    if (_firstId != widget.idOf(entries.first)) {
      _firstId = widget.idOf(entries.first);
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
    final pointerY = _pointerY ?? _margin + (_cursor - _first) * _pitch;
    final expanded = _expanded;
    // Paint labels outside the physical mouse region. Keep the rightmost end
    // fixed while the lens expands, including when a mouse button is held.
    final rightInset = widget.ticksOnly ? _rightInset : 0.0;
    final paintWidth = widget.maxWidth - rightInset;
    final maxBend = math.max(0.0, math.min(36 * lensScale, _margin - 4));
    final furthestTick = (_count - 1) * _pitch;
    final focusY = widget.ticksOnly
        ? pointerY.clamp(_margin, _margin + furthestTick)
        : pointerY;
    double lensOffset(double distance) =>
        maxBend * (2 / (1 + math.exp(-distance / (12 * lensScale))) - 1);
    final yInset = widget.ticksOnly
        ? math.max(0.0, _margin - lensOffset(furthestTick) - _pitch / 2)
        : 0.0;
    final railSize = Size(
      math.min(_maxTickLength, paintWidth),
      _height - 2 * yInset,
    );

    Widget fitTicks(Widget ticks) => widget.ticksOnly
        ? SizedBox.fromSize(
            size: railSize,
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: 0,
              maxWidth: paintWidth,
              minHeight: _height,
              maxHeight: _height,
              child: ticks,
            ),
          )
        : ticks;

    void dragPoint(Offset position, {bool release = false}) {
      if (!_dragging) return;
      if (widget.ticksOnly && !(Offset.zero & railSize).contains(position)) {
        _leaveRail();
        return;
      }
      _point(position.dy + yInset, select: true);
      if (release) _stopDrag();
    }

    final region = Focus(
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
        label: widget.semanticLabel,
        value: widget.describePosition(_active + 1),
        increasedValue: widget.describePosition(
          math.min(entries.length, _active + 2),
        ),
        decreasedValue: widget.describePosition(math.max(1, _active)),
        hint: widget.hint,
        onIncrease: () => _step(_active + 1),
        onDecrease: () => _step(_active - 1),
        child: MouseRegion(
          key: ValueKey('${widget.keyPrefix}-tick-navigation'),
          cursor: _dragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.click,
          onEnter: (e) {
            _inside = true;
            _point(e.localPosition.dy + yInset);
          },
          onHover: (e) => _point(e.localPosition.dy + yInset),
          onExit: (_) => _leaveRail(),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _startDrag(e, yInset),
            onPointerMove: (e) => dragPoint(e.localPosition),
            onPointerUp: (e) => dragPoint(e.localPosition, release: true),
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
            child: fitTicks(
              TweenAnimationBuilder<double>(
                tween: Tween(end: expanded ? 1 : 0),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Motion.fast,
                curve: Motion.standard,
                builder: (context, open, _) => SizedBox(
                  width: open > 0 ? paintWidth : 44 - rightInset,
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
                            final y = baseY + lensOffset(distance) * open;
                            final active = widget.activeIndex == index;
                            // A narrow peak with a visible taper: approximately
                            // 40, 28, 20, 16, 13 px, then the quiet 8 px baseline.
                            // Selection changes color, not the hover length curve.
                            final taper = math.pow(
                              .62,
                              distance.abs() / _pitch,
                            );
                            final restLength = active ? 20.0 : 8.0;
                            final length =
                                restLength +
                                (8 +
                                        (_maxTickLength - 8) * taper -
                                        restLength) *
                                    open;
                            final showLabel =
                                (_cursor - index).abs() <= 2 && open > 0;
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  key: ValueKey(
                                    '${widget.keyPrefix}-tick-${widget.idOf(entry)}',
                                  ),
                                  right: _rightInset - rightInset,
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
                                    right: 64 - rightInset,
                                    left: 0,
                                    top: y - 12 * scale,
                                    child: IgnorePointer(
                                      child: Opacity(
                                        // Keep the bubble opaque over the content;
                                        // only the label fades with distance.
                                        opacity: open,
                                        child: Transform.scale(
                                          scale: .9 + .1 * influence,
                                          alignment: Alignment.centerRight,
                                          child: Align(
                                            alignment: Alignment.centerRight,
                                            child: Container(
                                              key: ValueKey(
                                                '${widget.keyPrefix}-tick-label-${widget.idOf(entry)}',
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 3,
                                                  ),
                                              decoration: BoxDecoration(
                                                color:
                                                    scheme.surfaceContainerLow,
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
                                                '${index + 1} · ${widget.labelOf(entry)}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: context.texts.bodySmall
                                                    ?.copyWith(
                                                      fontSize: 13,
                                                      height: 1.35,
                                                      color: scheme.onSurface
                                                          .withValues(
                                                            alpha:
                                                                .45 +
                                                                .55 * influence,
                                                          ),
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
      ),
    );
    return widget.ticksOnly
        ? Padding(
            padding: EdgeInsets.fromLTRB(0, yInset, rightInset, yInset),
            child: region,
          )
        : region;
  }
}
