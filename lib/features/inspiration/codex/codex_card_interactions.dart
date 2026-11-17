import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/theme_settings.dart';
import '../../generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import '../../import/import_panel.dart' show ImportImagePanel;
import '../../shell/shell_state.dart';
import 'codex_actions.dart';
import 'codex_models.dart';

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
  final Widget Function(BuildContext, Widget actions, VoidCallback open)
  builder;

  @override
  ConsumerState<CodexCardInteractions> createState() =>
      _CodexCardInteractionsState();
}

class _CodexCardInteractionsState extends ConsumerState<CodexCardInteractions> {
  final _portal = OverlayPortalController();
  Timer? _showTimer, _hideTimer;
  ScrollPosition? _scroll;
  bool _overCard = false, _overPreview = false, _focused = false;
  bool _suppressed = false, _importing = false;
  bool _active = true;
  Offset? _pointer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final scroll = Scrollable.maybeOf(context)?.position;
    if (_scroll != scroll) {
      _scroll?.isScrollingNotifier.removeListener(_onScroll);
      _scroll = scroll;
      _scroll?.isScrollingNotifier.addListener(_onScroll);
    }
    if (!_active) _dismiss();
  }

  @override
  void didUpdateWidget(CodexCardInteractions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id ||
        oldWidget.codex.id != widget.codex.id) {
      _dismiss();
    }
  }

  void _onScroll() {
    if (_scroll?.isScrollingNotifier.value ?? false) _dismiss();
  }

  void _dismiss() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    final box = context.findRenderObject();
    _suppressed =
        _pointer != null &&
        box is RenderBox &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(_pointer!));
    _overPreview = false;
    if (!_portal.isShowing) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _portal.hide();
      });
    } else {
      _portal.hide();
    }
  }

  void _enterCard() {
    _hideTimer?.cancel();
    setState(() => _overCard = true);
    if (_suppressed ||
        !_active ||
        !ref.read(themeSettingsProvider).codexHoverPreview) {
      return;
    }
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted &&
          _active &&
          _overCard &&
          !_suppressed &&
          ref.read(themeSettingsProvider).codexHoverPreview) {
        _portal.show();
      }
    });
  }

  void _leave() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    // Allow crossing the small gap into the preview without losing it.
    _hideTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted && !_overCard && !_overPreview) {
        _portal.hide();
        _suppressed = false;
      }
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _scroll?.isScrollingNotifier.removeListener(_onScroll);
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.entry.fullText));
    if (mounted) hintSnack(context, '已复制提示词', icon: Icons.copy);
  }

  void _importPrompt(bool section) {
    final result = codexAddToPrompt(ref, widget.entry, asSection: section);
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

  Future<void> _importImage() async {
    if (_importing) return;
    final entry = widget.entry;
    final url = codexImageItemUrl(
      widget.codex,
      entry,
      widget.media,
      0,
      original: true,
    );
    if (url == null) return;
    setState(() => _importing = true);
    try {
      final bytes = await fetchRemoteImageBytes(url);
      if (!mounted) return;
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
      if (mounted) {
        hintSnack(context, '原图没下下来，检查下网络', icon: Icons.wifi_off_outlined);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Widget _actions() {
    final visible = _overCard || _focused || _importing;
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
              _dismiss();
              callback();
            },
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 19),
    );
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 100),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: .96),
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
                  action(
                    '创建分区并导入',
                    Icons.playlist_add,
                    () => _importPrompt(true),
                  ),
                  action(
                    '导入主提示词',
                    Icons.notes_rounded,
                    () => _importPrompt(false),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _previewText {
    final text = widget.entry.fullText;
    if (text.isEmpty) return '暂无提示词';
    return text.length <= 2400 ? text : '${text.substring(0, 2400)}…';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(themeSettingsProvider.select((s) => s.codexHoverPreview), (
      _,
      enabled,
    ) {
      if (!enabled) _dismiss();
    });
    final enabled = ref.watch(
      themeSettingsProvider.select((s) => s.codexHoverPreview),
    );
    return Focus(
      onFocusChange: (value) => setState(() => _focused = value),
      child: MouseRegion(
        onEnter: (event) {
          _pointer = event.position;
          _enterCard();
        },
        onHover: (event) => _pointer = event.position,
        onExit: (_) {
          setState(() => _overCard = false);
          _leave();
        },
        child: Listener(
          onPointerDown: (event) {
            _pointer = event.position;
            _dismiss();
          },
          child: OverlayPortal.overlayChildLayoutBuilder(
            controller: _portal,
            overlayChildBuilder: (context, info) {
              if (!enabled || !_active) return const SizedBox.shrink();
              final anchor = MatrixUtils.transformRect(
                info.childPaintTransform,
                Offset.zero & info.childSize,
              );
              return CustomSingleChildLayout(
                delegate: _HoverLayout(anchor),
                child: MouseRegion(
                  onEnter: (event) {
                    _pointer = event.position;
                    _overPreview = true;
                    _hideTimer?.cancel();
                  },
                  onHover: (event) => _pointer = event.position,
                  onExit: (_) {
                    _overPreview = false;
                    _leave();
                  },
                  child: GestureDetector(
                    onTap: _dismiss,
                    behavior: HitTestBehavior.opaque,
                    child: Material(
                      key: const ValueKey('codex-hover-preview'),
                      elevation: 8,
                      color: Theme.of(context).colorScheme.inverseSurface,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              widget.entry.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onInverseSurface,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Flexible(
                              child: LayoutBuilder(
                                builder: (context, bounds) {
                                  final lineHeight =
                                      MediaQuery.textScalerOf(
                                        context,
                                      ).scale(13) *
                                      1.5;
                                  // Fit complete lines before applying ellipsis, even
                                  // at large text scales in a short window.
                                  final lines = (bounds.maxHeight / lineHeight)
                                      .floor()
                                      .clamp(1, 18);
                                  return Text(
                                    _previewText,
                                    maxLines: lines,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onInverseSurface,
                                      fontSize: 13,
                                      height: 1.5,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: widget.builder(context, _actions(), () {
              _dismiss();
              widget.onOpen();
            }),
          ),
        ),
      ),
    );
  }
}

class _HoverLayout extends SingleChildLayoutDelegate {
  _HoverLayout(this.anchor);
  final Rect anchor;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(520, math.max(0, constraints.maxWidth - 24)),
        maxHeight: math.min(480, math.max(0, constraints.maxHeight - 24)),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x, y;
    if (anchor.right + 8 + childSize.width <= size.width - 12) {
      x = anchor.right + 8;
      y = anchor.top;
    } else if (anchor.left - 8 - childSize.width >= 12) {
      x = anchor.left - 8 - childSize.width;
      y = anchor.top;
    } else {
      x = anchor.left;
      y = anchor.bottom + 8 + childSize.height <= size.height - 12
          ? anchor.bottom + 8
          : anchor.top - childSize.height - 8;
    }
    return Offset(
      x.clamp(12, math.max(12, size.width - childSize.width - 12)),
      y.clamp(12, math.max(12, size.height - childSize.height - 12)),
    );
  }

  @override
  bool shouldRelayout(_HoverLayout oldDelegate) => anchor != oldDelegate.anchor;
}
