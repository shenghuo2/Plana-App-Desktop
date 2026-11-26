import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme/theme_settings.dart';
import '../gallery/albums/album_models.dart';

/// The grid owns the gesture so the source card can scroll outside the viewport.
/// Slot hit testing uses layout geometry, independently of the moving cards.
class DesktopAlbumReorderGrid extends StatefulWidget {
  const DesktopAlbumReorderGrid({
    super.key,
    required this.ids,
    required this.tile,
    required this.feel,
    required this.onReorder,
  });
  final List<String?> ids;
  final Widget Function(String?) tile;
  final GalleryDragFeel feel;
  final Future<void> Function(
    String id,
    List<String> before,
    List<String> after,
  )
  onReorder;

  @override
  State<DesktopAlbumReorderGrid> createState() =>
      _DesktopAlbumReorderGridState();
}

class _DesktopAlbumReorderGridState extends State<DesktopAlbumReorderGrid>
    with TickerProviderStateMixin {
  static const gap = 18.0;
  final _area = GlobalKey();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _ghost = ValueNotifier(Offset.zero);
  late final Ticker _edge;
  late final AnimationController _settle;

  @override
  void initState() {
    super.initState();
    _edge = createTicker(_edgeFrame);
    _settle = AnimationController(vsync: this);
  }

  List<String?>? _working;
  String? _id, _hover;
  Offset _grab = Offset.zero, _pointer = Offset.zero, _down = Offset.zero;
  Offset _dropStart = Offset.zero;
  double _tilt = 0, _edgeSpeed = 0;
  bool _dropping = false;
  int _columns = 1;
  Size _cell = Size.zero;
  Duration _lastTick = Duration.zero;

  RenderBox? get _box {
    final ro = _area.currentContext?.findRenderObject();
    return ro is RenderBox && ro.hasSize ? ro : null;
  }

  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  Offset _origin(int slot) => Offset(
    (slot % _columns) * (_cell.width + gap),
    (slot ~/ _columns) * (_cell.height + gap),
  );
  Offset? _inGrid(Offset global, [RenderBox? box]) =>
      (box ?? _box)?.globalToLocal(global);
  Offset get _scrollOffset =>
      Offset(0, _scroll.hasClients ? _scroll.offset : 0);

  int? _slot(Offset p, List<String?> ids, [RenderBox? targetBox]) {
    final box = targetBox ?? _box;
    if (box == null || _cell.isEmpty || ids.isEmpty || !box.size.contains(p)) {
      return null;
    }
    final inside = p + _scrollOffset;
    final col = ((inside.dx + gap / 2) / (_cell.width + gap)).floor().clamp(
      0,
      _columns - 1,
    );
    final row = ((inside.dy + gap / 2) / (_cell.height + gap)).floor();
    return (row * _columns + col).clamp(0, ids.length - 1);
  }

  @override
  void didUpdateWidget(DesktopAlbumReorderGrid old) {
    super.didUpdateWidget(old);
    if (_id != null &&
        !listEquals(old.ids, widget.ids) &&
        (!_dropping || !listEquals(_working, widget.ids))) {
      _reset();
    }
  }

  bool _movable(String? id) => id != null && !isFixedGallery(id);

  void _start(Offset global) {
    if (_dropping || _working != null) return;
    final box = _box;
    final p = _inGrid(global, box);
    if (box == null || p == null) return;
    final index = _slot(p, widget.ids, box);
    if (index == null || !_movable(widget.ids[index])) return;
    final local = p + _scrollOffset - _origin(index);
    if (!_cell.contains(local)) return;
    _focus.requestFocus();
    setState(() {
      _id = widget.ids[index];
      _hover = _id;
      _working = [...widget.ids];
      _grab = local;
      _pointer = p;
      _tilt = 0;
      _ghost.value = p - _grab;
    });
  }

  void _move(Offset global) {
    if (_id == null || _dropping) return;
    final box = _box;
    final p = _inGrid(global, box);
    if (box == null || p == null) return;
    _tilt = ((p.dx - _pointer.dx) * .09)
        .clamp(-widget.feel.maxTilt, widget.feel.maxTilt)
        .toDouble();
    _pointer = p;
    _ghost.value = p - _grab;
    _retarget();
    final h = box.size.height;
    _edgeSpeed = !box.size.contains(p)
        ? 0
        : p.dy < 60
        ? -14 * (1 - p.dy / 60)
        : p.dy > h - 60
        ? 14 * (1 - (h - p.dy) / 60)
        : 0;
    if (_edgeSpeed == 0) {
      _edge.stop();
    } else if (!_edge.isActive) {
      _lastTick = Duration.zero;
      _edge.start();
    }
  }

  void _edgeFrame(Duration elapsed) {
    if (!_scroll.hasClients || _working == null) return;
    final frames = ((elapsed - _lastTick).inMicroseconds / 16667).clamp(0, 2);
    _lastTick = elapsed;
    final pos = _scroll.position;
    final next = (pos.pixels + _edgeSpeed * frames)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    if (next == pos.pixels && frames > 0) {
      _edge.stop();
      return;
    }
    _scroll.jumpTo(next);
    _retarget();
  }

  void _retarget() {
    final ids = _working;
    final box = _box;
    if (ids == null || box == null || !box.size.contains(_pointer)) return;
    final center = _ghost.value + _cell.center(Offset.zero);
    final probe = Offset.lerp(_pointer, center, .72)!;
    final dest = _slot(probe, ids, box);
    if (dest == null) return;
    final first = ids.indexWhere(_movable);
    final last = ids.lastIndexWhere(_movable);
    final current = ids.indexOf(_id);
    if (first < 0 || last < 0 || current < 0) return;
    final target = dest.clamp(first, last);
    if (current != target) {
      setState(() => ids.insert(target, ids.removeAt(current)));
    }
  }

  void _reset() {
    _edge.stop();
    _settle.stop();
    _working = null;
    _id = null;
    _dropping = false;
  }

  void _cancel() {
    if (_id != null && !_dropping) setState(_reset);
  }

  Future<void> _drop() async {
    final id = _id;
    final working = _working;
    final box = _box;
    if (id == null || working == null || _dropping) return;
    if (box == null || !box.size.contains(_pointer)) {
      _cancel();
      return;
    }
    final before = widget.ids
        .whereType<String>()
        .where((s) => !isFixedGallery(s))
        .toList();
    final after = working
        .whereType<String>()
        .where((s) => !isFixedGallery(s))
        .toList();
    _edge.stop();
    _dropStart = _ghost.value;
    setState(() => _dropping = true);
    final motion = _reduced
        ? Duration.zero
        : Duration(milliseconds: widget.feel.settleMs);
    _settle.duration = motion;
    try {
      await Future.wait([
        _settle.forward(from: 0).orCancel,
        if (!listEquals(before, after))
          widget.onReorder(id, before, after).catchError((Object _) {}),
      ]);
    } on TickerCanceled {
      // Route closed or the album set changed during the landing animation.
    } finally {
      if (mounted && _id == id) setState(_reset);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _dropping) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape && _id != null) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (_id != null ||
        !HardwareKeyboard.instance.isAltPressed ||
        _hover == null) {
      return KeyEventResult.ignored;
    }
    final delta = {
      LogicalKeyboardKey.arrowLeft: -1,
      LogicalKeyboardKey.arrowRight: 1,
      LogicalKeyboardKey.arrowUp: -_columns,
      LogicalKeyboardKey.arrowDown: _columns,
    }[event.logicalKey];
    if (delta == null) return KeyEventResult.ignored;
    final before = widget.ids
        .whereType<String>()
        .where((id) => !isFixedGallery(id))
        .toList();
    final from = before.indexOf(_hover!);
    if (from < 0) return KeyEventResult.ignored;
    final to = (from + delta).clamp(0, before.length - 1);
    if (to != from) {
      final after = [...before]..removeAt(from);
      after.insert(to, _hover!);
      unawaited(
        widget.onReorder(_hover!, before, after).catchError((Object _) {}),
      );
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    _ghost.dispose();
    _edge.dispose();
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _columns = math.max(1, (constraints.maxWidth / (245 + gap)).ceil());
      final w = (constraints.maxWidth - gap * (_columns - 1)) / _columns;
      _cell = Size(w, w / .9);
      final ids = _working ?? widget.ids;
      final slots = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      return Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        onFocusChange: (focus) {
          if (!focus) _cancel();
        },
        child: GestureDetector(
          excludeFromSemantics: true,
          supportedDevices: const {
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.trackpad,
          },
          onPanDown: (d) {
            _down = d.globalPosition;
          },
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) {
            _start(_down);
            _move(d.globalPosition);
          },
          onPanUpdate: (d) => _move(d.globalPosition),
          onPanEnd: (_) => _drop(),
          onPanCancel: _cancel,
          child: GestureDetector(
            excludeFromSemantics: true,
            supportedDevices: const {PointerDeviceKind.touch},
            onLongPressStart: (d) => _start(d.globalPosition),
            onLongPressMoveUpdate: (d) => _move(d.globalPosition),
            onLongPressEnd: (_) => _drop(),
            onLongPressCancel: _cancel,
            child: Stack(
              key: _area,
              fit: StackFit.expand,
              children: [
                GridView.builder(
                  key: const PageStorageKey('desktop-library-grid-overview'),
                  controller: _scroll,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    childAspectRatio: .9,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                  ),
                  findChildIndexCallback: (key) =>
                      slots[(key as ValueKey<String?>).value],
                  itemCount: ids.length,
                  itemBuilder: (context, i) {
                    final id = ids[i];
                    return _MovingAlbum(
                      key: ValueKey<String?>(id),
                      origin: _origin(i),
                      feel: widget.feel,
                      reduced: _reduced,
                      child: MouseRegion(
                        onEnter: (_) {
                          if (_id == null) _hover = id;
                        },
                        child: _id != null && id == _id
                            ? DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer
                                      .withValues(alpha: .35),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary.withValues(alpha: .5),
                                  ),
                                ),
                              )
                            : widget.tile(id),
                      ),
                    );
                  },
                ),
                if (_id != null)
                  AnimatedBuilder(
                    animation: Listenable.merge([_ghost, _settle]),
                    child: Material(
                      color: Colors.transparent,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox.fromSize(
                        key: const ValueKey('album-drag-preview'),
                        size: _cell,
                        child: widget.tile(_id),
                      ),
                    ),
                    builder: (context, child) {
                      final t = _dropping
                          ? widget.feel.curve.transform(_settle.value)
                          : 0.0;
                      final p = _dropping
                          ? Offset.lerp(
                              _dropStart,
                              _origin(slots[_id]!) - _scrollOffset,
                              t,
                            )!
                          : _ghost.value;
                      return Positioned(
                        left: p.dx,
                        top: p.dy,
                        width: _cell.width,
                        height: _cell.height,
                        child: IgnorePointer(
                          child: Transform.rotate(
                            angle: _reduced
                                ? 0
                                : _tilt * (1 - t) * math.pi / 180,
                            child: Transform.scale(
                              scale: _reduced
                                  ? 1
                                  : 1 + (widget.feel.scale - 1) * (1 - t),
                              child: child,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _MovingAlbum extends StatefulWidget {
  const _MovingAlbum({
    super.key,
    required this.origin,
    required this.feel,
    required this.reduced,
    required this.child,
  });
  final Offset origin;
  final GalleryDragFeel feel;
  final bool reduced;
  final Widget child;
  @override
  State<_MovingAlbum> createState() => _MovingAlbumState();
}

class _MovingAlbumState extends State<_MovingAlbum>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  Offset _from = Offset.zero;
  Offset get _shift =>
      _from * (1 - widget.feel.curve.transform(_controller.value));
  @override
  void didUpdateWidget(_MovingAlbum old) {
    super.didUpdateWidget(old);
    if (old.origin != widget.origin) {
      _from = old.origin - widget.origin + _shift;
      _controller.duration = Duration(milliseconds: widget.feel.moveMs);
      if (widget.reduced) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => Transform.translate(
      offset: _shift,
      transformHitTests: false,
      child: child,
    ),
  );
}
