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
    Widget? preview,
    VoidCallback open,
  )
  builder;

  @override
  ConsumerState<CodexCardInteractions> createState() =>
      _CodexCardInteractionsState();
}

class _CodexCardInteractionsState extends ConsumerState<CodexCardInteractions> {
  Timer? _showTimer;
  ScrollPosition? _scroll;
  bool _overCard = false, _focused = false, _previewVisible = false;
  bool _importing = false, _active = true;

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
    if (!_active) _resetPreview();
  }

  @override
  void didUpdateWidget(CodexCardInteractions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id ||
        oldWidget.codex.id != widget.codex.id) {
      _resetPreview();
    }
  }

  void _onScroll() {
    if (_scroll?.isScrollingNotifier.value ?? false) _dismiss();
  }

  void _resetPreview() {
    _showTimer?.cancel();
    _previewVisible = false;
  }

  void _dismiss() {
    _showTimer?.cancel();
    if (_previewVisible) setState(() => _previewVisible = false);
  }

  void _enterCard() {
    setState(() => _overCard = true);
    if (!_active || !ref.read(themeSettingsProvider).codexHoverPreview) return;
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted &&
          _active &&
          _overCard &&
          !(_scroll?.isScrollingNotifier.value ?? false) &&
          ref.read(themeSettingsProvider).codexHoverPreview) {
        setState(() => _previewVisible = true);
      }
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _scroll?.isScrollingNotifier.removeListener(_onScroll);
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.entry.fullText));
    if (mounted) hintSnack(context, l10nNow.promptCopied, icon: Icons.copy);
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
        hintSnack(context, l10nNow.desktopCouldNotDownloadTheOriginalCheckYourConnection, icon: Icons.wifi_off_outlined);
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

  Widget _preview(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context);
    final bodyHeight = scale.scale(13) * 1.5;
    final titleHeight = scale.scale(14) * 1.3;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: LayoutBuilder(
        builder: (context, bounds) {
          if (bounds.maxHeight < bodyHeight) return const SizedBox.shrink();
          final inset = math.min(10.0, (bounds.maxHeight - bodyHeight) / 2);
          final available = bounds.maxHeight - inset * 2;
          final showTitle = available >= titleHeight + 4 + bodyHeight;
          final bodySpace = available - (showTitle ? titleHeight + 4 : 0);
          final lines = (bodySpace / bodyHeight).floor().clamp(1, 18);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: Material(
              key: const ValueKey('codex-hover-preview'),
              elevation: 6,
              color: scheme.inverseSurface,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: inset),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showTitle) ...[
                      Text(
                        widget.entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onInverseSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Flexible(
                      child: Text(
                        _previewText,
                        maxLines: lines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onInverseSurface,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      themeSettingsProvider.select((s) => s.codexHoverPreview),
    );
    if (!enabled) _resetPreview();
    return Focus(
      onFocusChange: (value) => setState(() => _focused = value),
      child: MouseRegion(
        onEnter: (_) => _enterCard(),
        onExit: (_) => setState(() {
          _overCard = false;
          _resetPreview();
        }),
        child: Listener(
          onPointerDown: (_) => _showTimer?.cancel(),
          onPointerUp: (_) => _dismiss(),
          child: widget.builder(
            context,
            _actions(),
            _previewVisible ? _preview(context) : null,
            () {
              _dismiss();
              widget.onOpen();
            },
          ),
        ),
      ),
    );
  }
}
