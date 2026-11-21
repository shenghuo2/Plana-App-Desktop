import 'dart:async';

import 'package:flutter/gestures.dart';

/// Complete the first tap immediately; a second completed tap on the same block
/// may unfold it. Unlike onDoubleTap, this never holds the single-tap arena.
class ImmediateFoldTap {
  ({Object target, Offset position, PointerDeviceKind? kind})? _previous;
  Timer? _timeout, _minimum;
  bool _ready = false;
  bool _handledPointerUp = false;

  /// InkWell/GestureDetector also send onTap after onTapUp. Consume that once;
  /// keyboard and accessibility activation have no pointer event and inspect.
  void activate(void Function() inspect) {
    if (_handledPointerUp) {
      _handledPointerUp = false;
      return;
    }
    reset();
    inspect();
  }

  void call({
    required Object target,
    required TapUpDetails details,
    required void Function() inspect,
    void Function()? unfold,
  }) {
    final previous = _previous;
    final doubleClick =
        unfold != null &&
        previous != null &&
        _ready &&
        previous.target == target &&
        previous.kind == details.kind &&
        (previous.position - details.globalPosition).distance <= kDoubleTapSlop;
    reset();
    _handledPointerUp = true;
    if (doubleClick) {
      unfold();
      return;
    }
    inspect();
    if (unfold == null || details.kind == PointerDeviceKind.unknown) return;
    _previous = (
      target: target,
      position: details.globalPosition,
      kind: details.kind,
    );
    _minimum = Timer(kDoubleTapMinTime, () => _ready = true);
    _timeout = Timer(kDoubleTapTimeout, reset);
  }

  void reset() {
    _timeout?.cancel();
    _minimum?.cancel();
    _previous = null;
    _ready = false;
    _handledPointerUp = false;
  }
}
