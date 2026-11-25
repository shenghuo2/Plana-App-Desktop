import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A desktop chip row with a separate, draggable track below its controls.
class HorizontalScrollStrip extends StatelessWidget {
  const HorizontalScrollStrip({
    super.key,
    required this.controller,
    required this.child,
    this.showTrack = true,
  }) : _hasScrollView = false;

  /// Wraps a lazy horizontal scroll view that already owns [controller].
  const HorizontalScrollStrip.scrollable({
    super.key,
    required this.controller,
    required this.child,
    this.showTrack = true,
  }) : _hasScrollView = true;

  static const dragAreaHeight = 18.0;

  final ScrollController controller;
  final Widget child;
  final bool showTrack;
  final bool _hasScrollView;

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.kind != PointerDeviceKind.mouse ||
        event.scrollDelta.dx != 0 ||
        event.scrollDelta.dy == 0 ||
        !controller.hasClients) {
      return;
    }
    final position = controller.position;
    final delta = position.axisDirection == AxisDirection.left
        ? -event.scrollDelta.dy
        : event.scrollDelta.dy;
    if ((delta > 0 && position.extentAfter == 0) ||
        (delta < 0 && position.extentBefore == 0)) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      position.pointerScroll(delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    final theme = ScrollbarTheme.of(context);
    return ScrollConfiguration(
      behavior: behavior.copyWith(
        dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
        scrollbars: false,
      ),
      child: Listener(
        onPointerSignal: showTrack ? _onWheel : null,
        // Flutter uses the painted thumb height for mouse hit testing. Give
        // the reserved gutter its own native drag target and paint a slim
        // Material scrollbar over the same scroll position.
        child: RawScrollbar(
          controller: controller,
          thumbVisibility: showTrack,
          interactive: showTrack,
          thickness: dragAreaHeight,
          thumbColor: Colors.transparent,
          trackVisibility: false,
          minThumbLength: theme.minThumbLength ?? 48,
          mainAxisMargin: theme.mainAxisMargin ?? 0,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: Scrollbar(
            controller: controller,
            thumbVisibility: showTrack,
            trackVisibility: showTrack,
            interactive: false,
            thickness: 8,
            radius: const Radius.circular(4),
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: _hasScrollView
                ? child
                : SingleChildScrollView(
                    controller: controller,
                    primary: false,
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.only(
                      bottom: showTrack ? dragAreaHeight : 0,
                    ),
                    child: child,
                  ),
          ),
        ),
      ),
    );
  }
}
