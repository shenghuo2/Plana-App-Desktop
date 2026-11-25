import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A single visible row of categories. The Wrap lays out the remaining rows
/// at the same height so the scrollbar and the wheel use the same positions.
class DesktopCategoryStrip extends StatefulWidget {
  const DesktopCategoryStrip({
    super.key,
    required this.controller,
    required this.snap,
    required this.onReflow,
    required this.children,
  });

  final ScrollController controller;
  final bool snap;
  final VoidCallback onReflow;
  final List<Widget> children;

  @override
  State<DesktopCategoryStrip> createState() => _DesktopCategoryStripState();
}

class _DesktopCategoryStripState extends State<DesktopCategoryStrip> {
  Size? _viewport;

  void _wheel(PointerSignalEvent event) {
    if (!widget.snap ||
        event is! PointerScrollEvent ||
        event.scrollDelta.dy == 0) {
      return;
    }
    final position = widget.controller.position;
    if (position.maxScrollExtent <= 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final row = (position.pixels / position.viewportDimension).round();
      final target =
          (row + event.scrollDelta.dy.sign) * position.viewportDimension;
      position.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    });
  }

  @override
  void didUpdateWidget(DesktopCategoryStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.snap && widget.snap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.controller.hasClients) return;
        final p = widget.controller.position;
        final target =
            (p.pixels / p.viewportDimension).round() * p.viewportDimension;
        p.jumpTo(target.clamp(0.0, p.maxScrollExtent));
      });
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const gap = 4.0;
      const gutter = 12.0;
      final width = math.min(bounds.maxWidth, 960.0);
      final height = math.max(
        52.0,
        (MediaQuery.textScalerOf(context).scale(15) * 1.6 + 28).ceilToDouble(),
      );
      final viewport = Size(width, height);
      if (_viewport != viewport) widget.onReflow();
      _viewport = viewport;
      final minWidth = math.max(
        0.0,
        ((width - gutter - gap * 6) / 7).floorToDouble(),
      );
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          key: const ValueKey('inspiration-category-viewport'),
          width: width,
          height: height,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ScrollbarTheme(
              data: ScrollbarTheme.of(context).copyWith(minThumbLength: 16),
              child: Scrollbar(
                controller: widget.controller,
                thumbVisibility: true,
                trackVisibility: true,
                interactive: true,
                thickness: 6,
                child: SingleChildScrollView(
                  controller: widget.controller,
                  primary: false,
                  physics: widget.snap
                      ? const PageScrollPhysics()
                      : const ClampingScrollPhysics(),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: _wheel,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: gutter),
                      child: Wrap(
                        spacing: gap,
                        children: [
                          for (final tab in widget.children)
                            SizedBox(
                              height: height,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minWidth: minWidth,
                                  ),
                                  child: tab,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
