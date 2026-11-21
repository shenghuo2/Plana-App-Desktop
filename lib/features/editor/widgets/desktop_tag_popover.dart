import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Opens tag actions at the selection and holds that screen position on scroll.
class DesktopTagPopover extends StatefulWidget {
  const DesktopTagPopover({
    super.key,
    required this.visible,
    required this.anchor,
    required this.anchorRevision,
    required this.panel,
    required this.onDismiss,
    required this.child,
    this.tapGroupId,
    this.panelWidth = 360,
    this.maxPanelHeight = 420,
    this.avoidAnchor = false,
    this.scrollPanel = true,
  });

  final bool visible;
  final Rect? Function() anchor;
  final int anchorRevision;
  final Widget panel;
  final VoidCallback onDismiss;
  final Widget child;
  final Object? tapGroupId;
  final double panelWidth, maxPanelHeight;
  final bool avoidAnchor;

  /// Panels with a fixed header/footer manage scrolling inside their body.
  final bool scrollPanel;

  @override
  State<DesktopTagPopover> createState() => _DesktopTagPopoverState();
}

class _DesktopTagPopoverState extends State<DesktopTagPopover> {
  // Keep the portal attached and render nothing when inactive. This avoids
  // mutating an OverlayPortalController during an editor/provider rebuild.
  final _portal = OverlayPortalController()..show();
  final _tapGroup = Object();
  final _storage = PageStorageBucket();
  final _scroll = ScrollController(keepScrollOffset: false);
  Rect? _openedAnchor;
  Size? _anchorChildSize;
  Size? _anchorOverlaySize;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DesktopTagPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible || widget.anchorRevision != oldWidget.anchorRevision) {
      _openedAnchor = null;
    }
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: widget.tapGroupId ?? _tapGroup,
    onTapOutside: widget.visible ? (_) => widget.onDismiss() : null,
    child: OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) {
        if (!widget.visible) return const SizedBox.shrink();
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        Rect relative(Rect global) => Rect.fromPoints(
          overlay.globalToLocal(global.topLeft),
          overlay.globalToLocal(global.bottomRight),
        );
        // Keep the screen snapshot while scrolling, but resample after reflow:
        // resizing a sidebar/window can wrap the toolbar or selected tags.
        // The layout builder runs after the portal child has its new size.
        if (_openedAnchor == null ||
            _anchorChildSize != info.childSize ||
            _anchorOverlaySize != info.overlaySize) {
          final globalAnchor = widget.anchor();
          if (globalAnchor == null) return const SizedBox.shrink();
          _openedAnchor = relative(globalAnchor);
          _anchorChildSize = info.childSize;
          _anchorOverlaySize = info.overlaySize;
        }
        final anchor = _openedAnchor!;
        final viewport = Offset.zero & info.overlaySize;
        final scheme = Theme.of(context).colorScheme;
        return CustomSingleChildLayout(
          delegate: _TagPopoverLayout(
            anchor,
            viewport,
            widget.panelWidth,
            widget.maxPanelHeight,
            widget.avoidAnchor,
          ),
          child: TapRegion(
            groupId: widget.tapGroupId ?? _tapGroup,
            child: TextFieldTapRegion(
              child: Material(
                key: const ValueKey('desktop-tag-popover'),
                elevation: 8,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: PageStorage(
                  bucket: _storage,
                  child: PrimaryScrollController.none(
                    child: widget.scrollPanel
                        ? SingleChildScrollView(
                            controller: _scroll,
                            primary: false,
                            child: widget.panel,
                          )
                        : widget.panel,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: widget.child,
    ),
  );
}

class _TagPopoverLayout extends SingleChildLayoutDelegate {
  _TagPopoverLayout(
    this.anchor,
    this.viewport,
    this.width,
    this.maxHeight,
    this.avoidAnchor,
  );
  final Rect anchor;
  final Rect viewport;
  final double width, maxHeight;
  final bool avoidAnchor;
  static const margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final availableWidth = math.min(
      width,
      math.max(0.0, constraints.maxWidth - margin * 2),
    );
    // An immediate inspector must leave the clicked title reachable for the
    // second click, including when the title is halfway down a narrow window.
    final availableHeight = avoidAnchor
        ? math.max(
            anchor.top - viewport.top - margin * 2,
            viewport.bottom - anchor.bottom - margin * 2,
          )
        : viewport.height - margin * 2;
    return BoxConstraints(
      minWidth: availableWidth,
      maxWidth: availableWidth,
      maxHeight: math.min(maxHeight, math.max(0.0, availableHeight)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = anchor.left.clamp(
      margin,
      math.max(margin, size.width - childSize.width - margin),
    );
    final below = anchor.bottom + margin;
    final y = below + childSize.height <= viewport.bottom - margin
        ? below
        : anchor.top - childSize.height - margin;
    return Offset(
      x.toDouble(),
      y.clamp(
        viewport.top + margin,
        math.max(
          viewport.top + margin,
          viewport.bottom - childSize.height - margin,
        ),
      ),
    );
  }

  @override
  bool shouldRelayout(_TagPopoverLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.viewport != viewport ||
      oldDelegate.width != width ||
      oldDelegate.maxHeight != maxHeight ||
      oldDelegate.avoidAnchor != avoidAnchor;
}
