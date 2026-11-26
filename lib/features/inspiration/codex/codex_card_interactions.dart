import '../../../l10n/l10n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/theme_settings.dart';
import '../../generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import '../../import/import_panel.dart' show ImportImagePanel;
import '../../shell/shell_state.dart';
import 'codex_actions.dart';
import 'codex_models.dart';

Future<void> copyCodexPrompt(BuildContext context, CodexEntry entry) async {
  await Clipboard.setData(ClipboardData(text: entry.fullText));
  if (context.mounted) {
    hintSnack(context, l10nNow.promptCopied, icon: Icons.copy);
  }
}

void importCodexPrompt(
  BuildContext context,
  WidgetRef ref,
  CodexEntry entry, {
  required bool section,
}) {
  final result = codexAddToPrompt(ref, entry, asSection: section);
  final shell = ref.read(shellIndexProvider.notifier);
  hintSnack(
    context,
    '${section ? '已创建分区并导入' : '已追加到主提示词'}'
    '${result.added > 0 ? ' · ${result.added} 个角色' : ''}'
    '${result.dropped > 0 ? '（另 ${result.dropped} 个超出上限）' : ''}',
    icon: Icons.check_circle_outline,
    actionLabel: '去创作',
    onAction: () => shell.select(kTabCreate),
  );
}

Future<void> importCodexImage(
  BuildContext context,
  CodexMeta book,
  CodexEntry entry,
  CodexMedia media, {
  int index = 0,
}) async {
  final url = codexImageItemUrl(book, entry, media, index, original: true);
  if (url == null) return;
  try {
    final bytes = await fetchRemoteImageBytes(url);
    if (!context.mounted) return;
    final name = entry.title.trim().isEmpty ? '法典原图' : entry.title.trim();
    final path = Uri.tryParse(url)?.path ?? url;
    final extension =
        RegExp(r'\.[A-Za-z0-9]{2,4}$').firstMatch(path)?.group(0) ?? '.png';
    await Navigator.of(context).push(
      sharedAxisRoute(
        ImportImagePanel(
          bytes: bytes,
          fileName: '$name$extension',
          displayName: name,
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      hintSnack(
        context,
        l10nNow.desktopCouldNotDownloadTheOriginalCheckYourConnection,
        icon: Icons.wifi_off_outlined,
      );
    }
  }
}

/// Desktop actions and a delayed, non-modal preview shared by both browsers.
class CodexCardInteractions extends ConsumerStatefulWidget {
  const CodexCardInteractions({
    super.key,
    required this.codex,
    required this.entry,
    required this.media,
    required this.onOpen,
    required this.builder,
  });
  final CodexMeta codex;
  final CodexEntry entry;
  final CodexMedia media;
  final VoidCallback onOpen;
  final Widget Function(
    BuildContext,
    Widget actions,
    Widget Function(Widget image) hoverImage,
    VoidCallback open,
  )
  builder;

  @override
  ConsumerState<CodexCardInteractions> createState() =>
      _CodexCardInteractionsState();
}

class _CodexCardInteractionsState extends ConsumerState<CodexCardInteractions> {
  bool _overCard = false, _focused = false, _importing = false;

  Future<void> _copy() => copyCodexPrompt(context, widget.entry);

  void _importPrompt(bool section) =>
      importCodexPrompt(context, ref, widget.entry, section: section);

  Future<void> _importImage() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      await importCodexImage(context, widget.codex, widget.entry, widget.media);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Widget _actions(VoidCallback dismiss) {
    if (!_overCard && !_focused && !_importing) return const SizedBox.shrink();
    Widget action(
      String name,
      IconData icon,
      VoidCallback? callback, {
      bool busy = false,
    }) => IconButton.filledTonal(
      key: ValueKey('codex-hover-$name'),
      tooltip: name,
      onPressed: callback == null
          ? null
          : () {
              dismiss();
              callback();
            },
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 19),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 100),
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: .96),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              action(
                '导入图片',
                Icons.add_photo_alternate_outlined,
                widget.entry.hasImage && !_importing ? _importImage : null,
                busy: _importing,
              ),
              action('复制提示词', Icons.copy, _copy),
              action('创建分区并导入', Icons.playlist_add, () => _importPrompt(true)),
              action('导入主提示词', Icons.notes_rounded, () => _importPrompt(false)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (value) => setState(() => _focused = value),
      child: MouseRegion(
        onEnter: (_) => setState(() => _overCard = true),
        onExit: (_) => setState(() => _overCard = false),
        child: CodexHoverPreviewArea(
          codex: widget.codex,
          entry: widget.entry,
          media: widget.media,
          builder: (preview, dismiss) =>
              widget.builder(context, _actions(dismiss), preview, () {
                dismiss();
                widget.onOpen();
              }),
        ),
      ),
    );
  }
}

/// The builder chooses which part of the card triggers the large preview.
class CodexHoverPreviewArea extends ConsumerStatefulWidget {
  const CodexHoverPreviewArea({
    super.key,
    required this.codex,
    required this.entry,
    required this.media,
    required this.builder,
  });

  final CodexMeta codex;
  final CodexEntry entry;
  final CodexMedia media;
  final Widget Function(Widget Function(Widget) preview, VoidCallback dismiss)
  builder;

  @override
  ConsumerState<CodexHoverPreviewArea> createState() =>
      _CodexHoverPreviewAreaState();
}

class _CodexHoverPreviewAreaState extends ConsumerState<CodexHoverPreviewArea> {
  Timer? _showTimer;
  ScrollPosition? _scroll;
  late final VoidCallback _scrollListener = _onScroll;
  bool _previewVisible = false, _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final scroll = Scrollable.maybeOf(context)?.position;
    if (_scroll != scroll) {
      _resetPreview();
      _scroll = scroll;
    }
    if (!_active) _resetPreview();
  }

  @override
  void didUpdateWidget(CodexHoverPreviewArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry ||
        oldWidget.codex != widget.codex ||
        oldWidget.media != widget.media) {
      _resetPreview();
    }
  }

  void _onScroll() {
    if (_scroll?.isScrollingNotifier.value ?? false) _dismiss();
  }

  void _resetPreview() {
    _cancelHover();
    _previewVisible = false;
  }

  void _dismiss() {
    _cancelHover();
    if (_previewVisible) setState(() => _previewVisible = false);
  }

  void _cancelHover() {
    if (_showTimer == null) return;
    _showTimer!.cancel();
    _showTimer = null;
    _scroll?.isScrollingNotifier.removeListener(_scrollListener);
  }

  void _enterImage() {
    if (!_active ||
        (_scroll?.isScrollingNotifier.value ?? false) ||
        !ref.read(themeSettingsProvider).codexHoverPreview) {
      return;
    }
    if (_showTimer == null) {
      _scroll?.isScrollingNotifier.addListener(_scrollListener);
    } else {
      _showTimer!.cancel();
    }
    _showTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted &&
          _active &&
          !(_scroll?.isScrollingNotifier.value ?? false) &&
          ref.read(themeSettingsProvider).codexHoverPreview) {
        setState(() => _previewVisible = true);
      } else {
        _cancelHover();
      }
    });
  }

  @override
  void dispose() {
    _cancelHover();
    super.dispose();
  }

  Widget _hoverImage(Widget image) {
    final thumb = codexImageUrl(widget.codex, widget.entry, widget.media);
    final original = codexImageUrl(
      widget.codex,
      widget.entry,
      widget.media,
      original: true,
    );
    final fallback = thumb ?? original;
    if (fallback == null) return image;
    return MouseRegion(
      onEnter: (event) {
        if (event.buttons == 0) _enterImage();
      },
      onExit: (_) => _dismiss(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (_previewVisible)
            _CodexHoverPreview(
              thumbnail: fallback,
              original: original,
              aspect: widget.entry.aspect,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      themeSettingsProvider.select((s) => s.codexHoverPreview),
    );
    if (!enabled) _resetPreview();
    return Listener(
      onPointerDown: (_) => _dismiss(),
      onPointerSignal: (_) => _dismiss(),
      child: widget.builder(_hoverImage, _dismiss),
    );
  }
}

/// Exists only while one image is being previewed. The portal can paint past
/// the card, while the nearest grid's viewport keeps it inside its own pane.
class _CodexHoverPreview extends StatefulWidget {
  const _CodexHoverPreview({
    required this.thumbnail,
    required this.original,
    required this.aspect,
  });

  final String thumbnail;
  final String? original;
  final double aspect;

  @override
  State<_CodexHoverPreview> createState() => _CodexHoverPreviewState();
}

class _CodexHoverPreviewState extends State<_CodexHoverPreview> {
  final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) {
    final scrollable = Scrollable.maybeOf(context);
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) {
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final viewport = scrollable?.context.findRenderObject() as RenderBox?;
        var bounds = Offset.zero & info.overlaySize;
        if (viewport != null && viewport.attached && viewport.hasSize) {
          bounds = bounds.intersect(
            MatrixUtils.transformRect(
              viewport.getTransformTo(overlay),
              Offset.zero & viewport.size,
            ),
          );
        }
        bounds = bounds.deflate(8);
        final anchor = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        if (bounds.isEmpty || !bounds.overlaps(anchor)) {
          return const SizedBox.shrink();
        }
        final source = Size(widget.aspect, 1);
        var size = applyBoxFit(
          BoxFit.contain,
          source,
          Size(math.min(380, bounds.width), bounds.height),
        ).destination;
        const gap = 8.0;
        double x = anchor.center.dx - size.width / 2;
        double y = anchor.center.dy - size.height / 2;
        if (bounds.right - anchor.right >= size.width + gap) {
          x = anchor.right + gap;
        } else if (anchor.left - bounds.left >= size.width + gap) {
          x = anchor.left - gap - size.width;
        } else {
          final below = bounds.bottom - anchor.bottom;
          final above = anchor.top - bounds.top;
          final space = math.max(above, below) - gap;
          if (space > 0 && space < size.height) {
            final beside = applyBoxFit(
              BoxFit.contain,
              source,
              Size(size.width, space),
            ).destination;
            // Keep the hovered controls in view when there is room for a
            // substantially enlarged image entirely above or below the card.
            if (beside.width >= size.width * .8 &&
                beside.width >= anchor.width * 1.5) {
              size = beside;
            }
          }
          x = anchor.center.dx - size.width / 2;
          y = below >= size.height + gap || below >= above
              ? anchor.bottom + gap
              : anchor.top - gap - size.height;
        }
        final origin = Offset(
          x.clamp(
            bounds.left,
            math.max(bounds.left, bounds.right - size.width),
          ),
          y.clamp(
            bounds.top,
            math.max(bounds.top, bounds.bottom - size.height),
          ),
        );
        final thumb = _image(context, widget.thumbnail, size);
        final original = widget.original;
        return IgnorePointer(
          child: ExcludeSemantics(
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: origin & size,
                  child: original != null && original != widget.thumbnail
                      ? _image(context, original, size, fallback: thumb)
                      : thumb,
                ),
              ],
            ),
          ),
        );
      },
      child: const SizedBox.expand(),
    );
  }

  Widget _image(
    BuildContext context,
    String url,
    Size size, {
    Widget? fallback,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return RemoteImage(
      url,
      key: ValueKey(url),
      decodeWidth: size.width,
      decodeHeight: size.height,
      fit: BoxFit.contain,
      frameBuilder: (_, child, frame, sync) => frame == null && !sync
          ? fallback ?? const SizedBox.shrink()
          : FittedBox(
              fit: BoxFit.contain,
              child: Material(
                key: const ValueKey('codex-hover-preview'),
                color: scheme.surface,
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: child,
              ),
            ),
      errorBuilder: (_, _, _) => fallback ?? const SizedBox.shrink(),
    );
  }
}
