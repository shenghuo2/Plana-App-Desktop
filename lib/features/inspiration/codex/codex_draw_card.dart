import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/horizontal_scroll_strip.dart';
import '../../../l10n/l10n.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import 'codex_card_interactions.dart' show copyCodexPrompt;
import 'codex_favorites.dart';
import 'codex_history.dart';
import 'codex_models.dart';

class CodexDrawImage extends StatelessWidget {
  const CodexDrawImage(
    this.record,
    this.media, {
    super.key,
    this.fit = BoxFit.contain,
    this.example,
  });
  final CodexDrawRecord record;
  final CodexMedia media;
  final BoxFit fit;
  final int? example;

  @override
  Widget build(BuildContext context) {
    final preview = example == null
        ? null
        : codexImageItemUrl(record.codex, record.entry, media, example!);
    final url =
        preview ??
        codexImageUrl(record.codex, record.entry, media) ??
        (fit == BoxFit.contain
            ? codexImageUrl(record.codex, record.entry, media, original: true)
            : null);
    final missing = Icon(Icons.image_outlined, color: context.scheme.outline);
    if (url == null) return Center(child: missing);
    return LayoutBuilder(
      builder: (context, box) => RemoteImage(
        url,
        fit: fit,
        width: box.maxWidth,
        height: box.maxHeight,
        decodeWidth: box.maxWidth,
        decodeHeight: box.maxHeight,
        errorBuilder: (_, _, _) => Center(child: missing),
      ),
    );
  }
}

class DrawFavoriteButton extends ConsumerWidget {
  const DrawFavoriteButton({super.key, required this.record});
  final CodexDrawRecord record;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorite = ref
        .watch(codexFavKeysProvider)
        .contains(codexFavKey(record.codex.id, record.entry.id));
    return IconButton.filledTonal(
      tooltip: favorite ? context.l10n.unfavorite : context.l10n.favorites,
      visualDensity: VisualDensity.compact,
      icon: Icon(favorite ? Icons.star : Icons.star_border, size: 19),
      onPressed: () async {
        final favorites = ref.read(codexFavoritesProvider.notifier);
        final added = await favorites.toggle(
          record.codex.id,
          record.entry,
          now: DateTime.now().millisecondsSinceEpoch,
        );
        if (!added && favorites.isFull && context.mounted) {
          hintSnack(context, context.l10n.desktopFavoritesAreFull);
        }
      },
    );
  }
}

class CodexDrawCard extends StatelessWidget {
  const CodexDrawCard({
    super.key,
    required this.record,
    required this.media,
    required this.onOpen,
    this.onPrevious,
    this.onNext,
    required this.imageHeight,
    required this.availableHeight,
  });
  final CodexDrawRecord record;
  final CodexMedia media;
  final VoidCallback onOpen;
  final VoidCallback? onPrevious, onNext;
  final double imageHeight, availableHeight;

  @override
  Widget build(BuildContext context) {
    final e = record.entry;
    final text = context.texts;
    final colors = context.scheme;
    final promptFont = (text.bodyMedium ?? const TextStyle()).copyWith(
      height: 1.45,
    );
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(promptFont.fontSize ?? 14) *
        1.45;
    final category = e.path.isEmpty
        ? context.l10n.codexCategoryless
        : e.path.last;
    // Lay out the title, metadata and three prompt lines before sizing the image.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: availableHeight),
      child: Material(
        color: colors.surfaceContainerLowest,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SizedBox(
                height: imageHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: colors.surfaceContainerLow,
                      child: CodexDrawImage(record, media),
                    ),
                    Semantics(
                      button: true,
                      label: context.l10n.desktopViewDetails,
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          key: const ValueKey('codex-draw-image'),
                          onTap: onOpen,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      top: 8,
                      right: 62,
                      child: IgnorePointer(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surface.withValues(alpha: .94),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Text(
                                category,
                                style: text.labelMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: DrawFavoriteButton(
                        key: const ValueKey('codex-draw-favorite'),
                        record: record,
                      ),
                    ),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Material(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(20),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: context.l10n.previous,
                              visualDensity: VisualDensity.compact,
                              key: const ValueKey('codex-draw-previous'),
                              onPressed: onPrevious,
                              icon: const Icon(Icons.chevron_left, size: 18),
                            ),
                            IconButton(
                              tooltip: context.l10n.next,
                              visualDensity: VisualDensity.compact,
                              key: const ValueKey('codex-draw-next'),
                              onPressed: onNext,
                              icon: const Icon(Icons.chevron_right, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    e.title,
                    key: const ValueKey('codex-draw-title'),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.path.join(' / '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (e.postCount case final count?)
                        Text('post $count', style: text.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 8,
                        top: 5,
                        bottom: 5,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: (lineHeight * 3).ceilToDouble() + 2,
                              child: Text(
                                e.fullText,
                                key: const ValueKey('codex-draw-prompt'),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: promptFont,
                                strutStyle: StrutStyle.fromTextStyle(
                                  promptFont,
                                  forceStrutHeight: true,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: context.l10n.copyPrompt,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            onPressed: () => copyCodexPrompt(context, e),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CodexRecentDraws extends StatefulWidget {
  const CodexRecentDraws({
    super.key,
    this.wide = false,
    this.historyOpen = false,
    required this.records,
    required this.media,
    required this.selectedId,
    required this.onSelect,
    required this.onHistory,
  });
  final bool wide, historyOpen;
  final List<CodexDrawRecord> records;
  final CodexMedia media;
  final String? selectedId;
  final ValueChanged<CodexDrawRecord> onSelect;
  final VoidCallback onHistory;
  @override
  State<CodexRecentDraws> createState() => _CodexRecentDrawsState();
}

class _CodexRecentDrawsState extends State<CodexRecentDraws> {
  final _scroll = ScrollController();
  double get _itemWidth => widget.wide ? 178 : 58;

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  @override
  void didUpdateWidget(CodexRecentDraws oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedId != oldWidget.selectedId ||
        (oldWidget.historyOpen && !widget.historyOpen)) {
      _revealSelection();
    }
  }

  void _revealSelection() {
    if (widget.historyOpen || widget.selectedId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final index = widget.records.indexWhere((r) => r.id == widget.selectedId);
      if (index < 0) return;
      final position = _scroll.position;
      final start = index * _itemWidth;
      final end = start + _itemWidth;
      final double offset;
      if (start < position.pixels || _itemWidth > position.viewportDimension) {
        offset = start;
      } else if (end > position.pixels + position.viewportDimension) {
        offset = end - position.viewportDimension;
      } else {
        return;
      }
      position.jumpTo(
        offset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '${context.l10n.codexDeckRecent} · ${widget.records.length}',
              key: const ValueKey('codex-draw-recent-count'),
              style: context.texts.labelLarge,
            ),
          ),
          if (widget.wide)
            _DrawHistoryToggle(
              expanded: widget.historyOpen,
              onPressed: widget.onHistory,
            )
          else
            TextButton(
              onPressed: widget.onHistory,
              child: Text(context.l10n.codexDeckHistory),
            ),
        ],
      ),
      if (!widget.historyOpen && widget.records.isNotEmpty)
        SizedBox(
          height: 70,
          child: LayoutBuilder(
            builder: (context, box) {
              final overflow =
                  widget.records.length * _itemWidth > box.maxWidth;
              return HorizontalScrollStrip.scrollable(
                controller: _scroll,
                showTrack: overflow,
                child: ListView.builder(
                  key: const ValueKey('codex-recent-draws'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  itemExtent: _itemWidth,
                  itemCount: widget.records.length,
                  padding: EdgeInsets.only(
                    bottom: overflow ? HorizontalScrollStrip.dragAreaHeight : 9,
                  ),
                  itemBuilder: (context, i) {
                    final r = widget.records[i];
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Material(
                        clipBehavior: Clip.antiAlias,
                        color: context.scheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            width: r.id == widget.selectedId ? 2 : 1,
                            color: r.id == widget.selectedId
                                ? context.scheme.primary
                                : context.scheme.outlineVariant,
                          ),
                        ),
                        child: Tooltip(
                          message: r.entry.title,
                          child: InkWell(
                            key: ValueKey('codex-recent-${r.id}'),
                            onTap: () => widget.onSelect(r),
                            child: IgnorePointer(
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: widget.wide
                                    ? Row(
                                        children: [
                                          SizedBox(
                                            width: 44,
                                            child: CodexDrawImage(
                                              r,
                                              widget.media,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                          const SizedBox(width: 7),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  r.entry.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style:
                                                      context.texts.labelLarge,
                                                ),
                                                Text(
                                                  r.entry.path.lastOrNull ??
                                                      context
                                                          .l10n
                                                          .codexCategoryless,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style:
                                                      context.texts.bodySmall,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      )
                                    : CodexDrawImage(
                                        r,
                                        widget.media,
                                        fit: BoxFit.cover,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
    ],
  );
}

class _DrawHistoryToggle extends StatefulWidget {
  const _DrawHistoryToggle({required this.expanded, required this.onPressed});

  final bool expanded;
  final VoidCallback onPressed;

  @override
  State<_DrawHistoryToggle> createState() => _DrawHistoryToggleState();
}

class _DrawHistoryToggleState extends State<_DrawHistoryToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.expanded
        ? context.l10n.codexWideHideHistory
        : context.l10n.codexWideHistory;
    return TextButton(
      key: const ValueKey('codex-random-history'),
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerRight,
      ),
      onHover: (value) => setState(() => _hovered = value),
      onPressed: widget.onPressed,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_hovered) ...[Text(label), const SizedBox(width: 8)],
            DecoratedBox(
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: context.scheme.surfaceContainerHigh,
              ),
              child: SizedBox(
                width: 36,
                height: 32,
                child: Icon(
                  widget.expanded ? Icons.expand_more : Icons.expand_less,
                  size: 18,
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
