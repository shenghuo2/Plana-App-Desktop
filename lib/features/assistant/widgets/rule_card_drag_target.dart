import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Mouse movement starts a reorder immediately. Touch can scroll until held.
class RuleCardDragTarget extends StatelessWidget {
  const RuleCardDragTarget({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      if (event.buttons != kPrimaryButton) return;
      final list = SliverReorderableList.maybeOf(context);
      if (list == null) return;
      final recognizer = event.kind == PointerDeviceKind.mouse
          ? ImmediateMultiDragGestureRecognizer()
          : DelayedMultiDragGestureRecognizer();
      list.startItemDragReorder(
        index: index,
        event: event,
        recognizer: recognizer
          ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
      );
    },
    child: child,
  );
}
