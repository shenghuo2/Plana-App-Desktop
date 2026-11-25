part of 'metadata_compare_page.dart';

class _ComparePanel extends StatelessWidget {
  const _ComparePanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: context.raisedFill(context.scheme.surfaceContainerLowest),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: context.scheme.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _ComparePreview extends StatefulWidget {
  const _ComparePreview({
    required this.sides,
    required this.busy,
    required this.files,
    required this.gallery,
    required this.clear,
    required this.swap,
    required this.drop,
  });
  final List<_Side?> sides;
  final bool busy;
  final ValueChanged<int> files, gallery, clear;
  final VoidCallback swap;
  final Future<void> Function(int, List<PickedImage>) drop;

  @override
  State<_ComparePreview> createState() => _ComparePreviewState();
}

class _ComparePreviewState extends State<_ComparePreview> {
  final _view = TransformationController();
  final _frame = GlobalKey();
  bool _cover = false;

  @override
  void didUpdateWidget(_ComparePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sides[0] != widget.sides[0] ||
        oldWidget.sides[1] != widget.sides[1]) {
      _reset();
    }
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  void _reset() => _view.value = Matrix4.identity();

  // Scale about the centre of either equally sized frame. Both viewers listen
  // to the same controller, so wheel zoom and direct panning also stay in sync.
  void _zoom(double factor) {
    final frame = _frame.currentContext?.findRenderObject() as RenderBox?;
    if (frame == null || !frame.hasSize) return;
    final centre = frame.size.center(Offset.zero);
    final point = _view.toScene(centre);
    final scale = (_view.value.getMaxScaleOnAxis() * factor).clamp(1.0, 6.0);
    final dx = (centre.dx - point.dx * scale).clamp(
      frame.size.width * (1 - scale),
      0.0,
    );
    final dy = (centre.dy - point.dy * scale).clamp(
      frame.size.height * (1 - scale),
      0.0,
    );
    _view.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  Widget _button(String tip, IconData icon, VoidCallback? action) => IconButton(
    tooltip: tip,
    icon: Icon(icon, size: 18),
    onPressed: action,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
    padding: const EdgeInsets.all(4),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final any = widget.sides.any((s) => s != null);
    return _ComparePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 4,
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.view_column_outlined,
                      size: 19,
                      color: context.scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(l.compareSideBySide, style: context.texts.titleSmall),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      selected: {_cover},
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(l.compareContain),
                        ),
                        ButtonSegment(value: true, label: Text(l.compareCover)),
                      ],
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelectionChanged: (v) => setState(() {
                        _cover = v.single;
                        _reset();
                      }),
                    ),
                    ValueListenableBuilder<Matrix4>(
                      valueListenable: _view,
                      builder: (_, matrix, _) {
                        final scale = matrix.getMaxScaleOnAxis();
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _button(
                              l.compareZoomOut,
                              Icons.zoom_out,
                              any && scale > 1.001 ? () => _zoom(.8) : null,
                            ),
                            TextButton(
                              onPressed: any ? _reset : null,
                              child: Text('${(scale * 100).round()}%'),
                            ),
                            _button(
                              l.compareZoomIn,
                              Icons.zoom_in,
                              any && scale < 5.999 ? () => _zoom(1.25) : null,
                            ),
                            _button(
                              l.compareResetView,
                              Icons.fit_screen_outlined,
                              any ? _reset : null,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ColoredBox(
              color: context.scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SizedBox(key: _frame, child: _slot(0)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _slot(1)),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(child: _dock(0)),
                _button(
                  l.swapAB,
                  Icons.swap_horiz,
                  any && !widget.busy ? widget.swap : null,
                ),
                Expanded(child: _dock(1)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(int index) => DecoratedBox(
    decoration: BoxDecoration(
      color: index == 0 ? context.scheme.error : context.editor.oc,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text(
        _letter(index),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );

  Widget _slot(int i) {
    final l = context.l10n, side = widget.sides[i];
    final dropLabel = l.compareDrop(_letter(i));
    return ImageDropRegion(
      key: ValueKey('compare-drop-$i'),
      label: dropLabel,
      multiple: true,
      enabled: !widget.busy,
      onDrop: (images, _) => widget.drop(i, images),
      child: Material(
        color: context.scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (side != null)
              InteractiveViewer(
                transformationController: _view,
                minScale: 1,
                maxScale: 6,
                child: Image.memory(
                  side.image.bytes,
                  fit: _cover ? BoxFit.cover : BoxFit.contain,
                  gaplessPlayback: true,
                  semanticLabel: side.image.name,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              )
            else
              LayoutBuilder(
                builder: (_, box) {
                  final compact = box.maxWidth < 175 || box.maxHeight < 170;
                  return Center(
                    child: SingleChildScrollView(
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(6, 32, 6, 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            size: compact ? 23 : 32,
                            color: context.scheme.primary,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            dropLabel,
                            textAlign: TextAlign.center,
                            style: context.texts.titleSmall,
                          ),
                          if (!compact)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                i == 0
                                    ? l.compareMetadataHint
                                    : l.comparePairHint,
                                textAlign: TextAlign.center,
                                style: context.texts.bodySmall,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              FilledButton(
                                onPressed: widget.busy
                                    ? null
                                    : () => widget.files(i),
                                child: Text(l.compareOpenFile),
                              ),
                              OutlinedButton(
                                onPressed: widget.busy
                                    ? null
                                    : () => widget.gallery(i),
                                child: Text(l.comparePickGallery),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            Positioned(top: 9, left: 9, child: IgnorePointer(child: _badge(i))),
          ],
        ),
      ),
    );
  }

  Widget _dock(int i) {
    final l = context.l10n, side = widget.sides[i], slot = _letter(i);
    final label = side?.image.name ?? l.compareEmptySlot(slot);
    final name = Row(
      children: [
        _badge(i),
        const SizedBox(width: 6),
        Flexible(
          child: Tooltip(
            message: label,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: context.texts.labelMedium,
            ),
          ),
        ),
      ],
    );
    final buttons = Wrap(
      alignment: WrapAlignment.end,
      children: [
        _button(
          '${l.comparePickGallery} · $slot',
          Icons.photo_library_outlined,
          widget.busy ? null : () => widget.gallery(i),
        ),
        _button(
          '${l.compareOpenFile} · $slot',
          Icons.folder_open_outlined,
          widget.busy ? null : () => widget.files(i),
        ),
        _button(
          '${l.remove} · $slot',
          Icons.close,
          side == null || widget.busy ? null : () => widget.clear(i),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (_, box) => box.maxWidth < 205
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [name, buttons],
            )
          : Row(
              children: [
                Expanded(child: name),
                buttons,
              ],
            ),
    );
  }
}
