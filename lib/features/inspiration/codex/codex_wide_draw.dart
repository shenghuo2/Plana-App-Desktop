import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import 'codex_card_interactions.dart';
import 'codex_draw_card.dart';
import 'codex_history.dart';
import 'codex_models.dart';
import 'codex_sheets.dart';

class CodexWideDraw extends StatelessWidget {
  const CodexWideDraw({
    super.key,
    required this.book,
    required this.media,
    required this.current,
    required this.scope,
    required this.count,
    required this.seen,
    required this.noRepeat,
    required this.onToggleRepeat,
    required this.onReshuffle,
    required this.history,
    required this.onHistory,
    required this.recent,
    required this.onSelect,
    required this.onOpen,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.onDraw,
    required this.trio,
    required this.hand,
    required this.onLayout,
    required this.relatedCount,
    required this.onRelatedDraw,
    required this.onBrowse,
  });
  final CodexMeta book;
  final CodexMedia media;
  final CodexDrawRecord? current;
  final String scope;
  final int count, seen, relatedCount;
  final bool noRepeat, trio;
  final Widget? history;
  final List<CodexDrawRecord> recent, hand;
  final ValueChanged<CodexDrawRecord> onSelect;
  final void Function(CodexDrawRecord, {int imageIndex}) onOpen;
  final ValueChanged<bool> onLayout;
  final VoidCallback onToggleRepeat, onHistory, onBack;
  final VoidCallback? onReshuffle,
      onPrevious,
      onNext,
      onDraw,
      onRelatedDraw,
      onBrowse;

  Widget _drawButton(BuildContext context) {
    final t = context.l10n;
    return FilledButton.icon(
      key: const ValueKey('codex-random-draw'),
      onPressed: onDraw,
      icon: const Icon(Icons.casino_outlined, size: 18),
      label: Text(
        '${trio
            ? t.codexWideDeal
            : current == null
            ? t.desktopDrawAtRandom
            : t.codexWideNext}   ·   Space',
      ),
    );
  }

  Widget _header(BuildContext context, double width) {
    final t = context.l10n;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final compact = width < 980 * scale;
    final controls = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilterChip(
          key: const ValueKey('codex-draw-no-repeat'),
          label: Text(t.codexDeckNoRepeat),
          selected: noRepeat,
          showCheckmark: false,
          avatar: const Icon(Icons.shuffle, size: 16),
          onSelected: (_) => onToggleRepeat(),
        ),
        TextButton(
          key: const ValueKey('codex-draw-reshuffle'),
          onPressed: onReshuffle,
          child: Text(t.codexWideReshuffle),
        ),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: false,
              icon: const Icon(Icons.crop_portrait, size: 17),
              label: compact ? null : Text(t.codexWideSingle),
              tooltip: t.codexWideSingle,
            ),
            ButtonSegment(
              value: true,
              icon: const Icon(Icons.view_column_outlined, size: 17),
              label: compact ? null : Text(t.codexWideTrio),
              tooltip: t.codexWideTrio,
            ),
          ],
          showSelectedIcon: false,
          selected: {trio},
          onSelectionChanged: (s) => onLayout(s.first),
        ),
      ],
    );
    final stats = Wrap(
      spacing: 7,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          t.codexDeckCandidates(count),
          key: const ValueKey('codex-random-candidates'),
          style: context.texts.labelLarge?.copyWith(
            color: context.scheme.primary,
          ),
        ),
        if (noRepeat)
          Text(
            '${t.codexDeckSeen} $seen/$count',
            key: const ValueKey('codex-draw-seen'),
            style: context.texts.labelMedium,
          ),
      ],
    );
    final backLabel = history == null ? t.desktopBackToCodex : t.codexDeckBack;
    final title = Row(
      children: [
        if (compact)
          IconButton.outlined(
            key: const ValueKey('codex-draw-back'),
            onPressed: onBack,
            tooltip: backLabel,
            icon: const Icon(Icons.arrow_back, size: 19),
          )
        else
          OutlinedButton.icon(
            key: const ValueKey('codex-draw-back'),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 17),
            label: Text(backLabel),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.desktopRandomInspiration,
                style: context.texts.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Tooltip(
                message: '${book.displayTitle} · $scope',
                child: Text(
                  '${book.displayTitle} · $scope',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: title),
          const SizedBox(width: 6),
          if (compact) SizedBox(width: 96 * scale, child: stats) else stats,
          const SizedBox(width: 10),
          controls,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final r = current;
    final panel = history;
    return LayoutBuilder(
      builder: (context, box) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, box.maxWidth),
            Expanded(
              child: _DrawSurface(
                child:
                    panel ??
                    (trio && hand.isNotEmpty
                        ? Column(
                            children: [
                              Expanded(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (final card in hand)
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: _ChoiceCard(
                                            record: card,
                                            media: media,
                                            onSelect: () => onSelect(card),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: _drawButton(context),
                              ),
                            ],
                          )
                        : !trio && r != null
                        ? _Spotlight(
                            key: ValueKey(r.id),
                            record: r,
                            media: media,
                            drawButton: _drawButton(context),
                            onOpen: (i) => onOpen(r, imageIndex: i),
                            onPrevious: onPrevious,
                            onNext: onNext,
                            relatedCount: relatedCount,
                            onRelatedDraw: onRelatedDraw,
                            onBrowse: onBrowse,
                          )
                        : Center(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.style_outlined,
                                    size: 42,
                                    color: context.scheme.primary,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    count == 0
                                        ? t.noMatchingEntries
                                        : t.codexDeckFirst,
                                    style: context.texts.titleMedium,
                                  ),
                                  const SizedBox(height: 12),
                                  _drawButton(context),
                                ],
                              ),
                            ),
                          )),
              ),
            ),
            const SizedBox(height: 8),
            _DrawSurface(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
                child: CodexRecentDraws(
                  wide: true,
                  historyOpen: panel != null,
                  records: recent,
                  media: media,
                  selectedId: r?.id,
                  onSelect: onSelect,
                  onHistory: onHistory,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DrawSurface extends StatelessWidget {
  const _DrawSurface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: context.scheme.surfaceContainerLowest,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: context.scheme.outlineVariant),
    ),
    child: child,
  );
}

class _Spotlight extends ConsumerStatefulWidget {
  const _Spotlight({
    super.key,
    required this.record,
    required this.media,
    required this.drawButton,
    required this.onOpen,
    required this.onPrevious,
    required this.onNext,
    required this.relatedCount,
    required this.onRelatedDraw,
    required this.onBrowse,
  });
  final CodexDrawRecord record;
  final CodexMedia media;
  final Widget drawButton;
  final ValueChanged<int> onOpen;
  final int relatedCount;
  final VoidCallback? onPrevious, onNext, onRelatedDraw, onBrowse;
  @override
  ConsumerState<_Spotlight> createState() => _SpotlightState();
}

class _SpotlightState extends ConsumerState<_Spotlight> {
  int _image = 0;
  bool _importing = false;

  Future<void> _importOriginal() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      await importCodexImage(
        context,
        widget.record.codex,
        widget.record.entry,
        widget.media,
        index: _image,
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Widget _art() {
    final r = widget.record;
    final t = context.l10n;
    final images = r.entry.images.length;
    Widget arrow(bool prev) => IconButton.filledTonal(
      key: ValueKey(prev ? 'codex-draw-previous' : 'codex-draw-next'),
      tooltip: prev ? t.previous : t.next,
      onPressed: prev ? widget.onPrevious : widget.onNext,
      icon: Icon(prev ? Icons.chevron_left : Icons.chevron_right),
    );
    return ColoredBox(
      color: context.scheme.surfaceContainerLow,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            child: CodexDrawImage(r, widget.media, example: _image),
          ),
          Semantics(
            button: true,
            label: t.desktopViewDetails,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: const ValueKey('codex-draw-image'),
                onTap: () => widget.onOpen(_image),
              ),
            ),
          ),
          if (r.entry.path.isNotEmpty)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.scheme.surface.withValues(alpha: .94),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        r.entry.path.last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.labelMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(child: arrow(true)),
          ),
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(child: arrow(false)),
          ),
          if (images > 1)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Material(
                  color: context.scheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: t.previous,
                        onPressed: _image > 0
                            ? () => setState(() => _image--)
                            : null,
                        icon: const Icon(Icons.navigate_before),
                      ),
                      Text('${_image + 1} / $images'),
                      IconButton(
                        tooltip: t.next,
                        onPressed: _image + 1 < images
                            ? () => setState(() => _image++)
                            : null,
                        icon: const Icon(Icons.navigate_next),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _info() {
    final r = widget.record, e = r.entry;
    final t = context.l10n;
    final colors = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [r.codex.displayTitle, ...e.path].join(' / '),
                    style: context.texts.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    e.title,
                    key: const ValueKey('codex-draw-title'),
                    style: context.texts.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            DrawFavoriteButton(
              key: const ValueKey('codex-draw-favorite'),
              record: r,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 4,
          children: [
            for (final label in [
              r.codex.type.label,
              if (e.postCount != null) 'post ${e.postCount}',
              if (e.isNew) t.codexRecentAdditions,
            ])
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Text(label, style: context.texts.labelSmall),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          t.prompt,
          style: context.texts.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        codexPromptChips(
          ref,
          r.codex.id,
          e,
          onCopy: (raw) async {
            await Clipboard.setData(ClipboardData(text: raw));
            if (mounted) hintSnack(context, t.promptCopied, icon: Icons.copy);
          },
        ),
      ],
    );
  }

  Widget _related() {
    final e = widget.record.entry;
    if (e.path.isEmpty || widget.onBrowse == null) {
      return const SizedBox.shrink();
    }
    final t = context.l10n;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 4),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            t.codexWideRelated(e.path.last, widget.relatedCount),
            style: context.texts.bodySmall,
          ),
          TextButton(
            key: const ValueKey('codex-draw-in-category'),
            onPressed: widget.onRelatedDraw,
            child: Text(t.codexWideSameCategory),
          ),
          TextButton(
            onPressed: widget.onBrowse,
            child: Text(t.codexWideBrowseCategory),
          ),
        ],
      ),
    );
  }

  Widget _actions() {
    final e = widget.record.entry;
    final t = context.l10n;
    final section = FilledButton.tonalIcon(
      key: const ValueKey('codex-draw-import-section'),
      onPressed: () => importCodexPrompt(context, ref, e, section: true),
      icon: const Icon(Icons.add, size: 17),
      label: Text(t.codexNewSection),
    );
    final secondary = [
      OutlinedButton.icon(
        key: const ValueKey('codex-draw-append-main'),
        onPressed: () => importCodexPrompt(context, ref, e, section: false),
        icon: const Icon(Icons.notes_rounded, size: 16),
        label: Text(t.codexAppendMain),
      ),
      OutlinedButton.icon(
        onPressed: () => copyCodexPrompt(context, e),
        icon: const Icon(Icons.copy, size: 16),
        label: Text(t.copyPrompt),
      ),
      OutlinedButton.icon(
        onPressed: e.hasImage && !_importing ? _importOriginal : null,
        icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
        label: Text(t.codexWideOriginal),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(10),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < MediaQuery.textScalerOf(context).scale(440)) {
            return Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [widget.drawButton, section, ...secondary],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(flex: 3, child: widget.drawButton),
                  const SizedBox(width: 6),
                  Expanded(flex: 2, child: section),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (final button in secondary) ...[
                    if (button != secondary.first) const SizedBox(width: 6),
                    Expanded(child: button),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(flex: 53, child: _art()),
      const VerticalDivider(width: 1),
      Expanded(
        flex: 47,
        child: LayoutBuilder(
          builder: (context, box) {
            final pin =
                box.maxHeight >= MediaQuery.textScalerOf(context).scale(300) &&
                box.maxWidth >= 310;
            final padding = (box.maxWidth * .045).clamp(12.0, 24.0);
            Widget content() => LayoutBuilder(
              builder: (context, area) => SingleChildScrollView(
                key: const ValueKey('codex-wide-info'),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: area.maxHeight),
                  child: Padding(
                    padding: EdgeInsets.all(padding),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [_info(), _related()],
                    ),
                  ),
                ),
              ),
            );
            if (pin) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: content()),
                  const Divider(height: 1),
                  _actions(),
                ],
              );
            }
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.all(padding),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [_info(), _related()],
                    ),
                  ),
                  const Divider(height: 1),
                  _actions(),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

class _ChoiceCard extends ConsumerWidget {
  const _ChoiceCard({
    required this.record,
    required this.media,
    required this.onSelect,
  });
  final CodexDrawRecord record;
  final CodexMedia media;
  final VoidCallback onSelect;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = record.entry, t = context.l10n;
    return _DrawSurface(
      child: LayoutBuilder(
        builder: (context, box) {
          final imageHeight = math.max(
            80.0,
            box.maxHeight - MediaQuery.textScalerOf(context).scale(115),
          );
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  key: ValueKey('codex-choice-${e.id}'),
                  onTap: onSelect,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: imageHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(
                              color: context.scheme.surfaceContainerLow,
                              child: CodexDrawImage(record, media),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: DrawFavoriteButton(record: record),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              e.path.join(' / '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodySmall,
                            ),
                            Text(
                              e.fullText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  children: [
                    IconButton(
                      tooltip: t.codexNewSection,
                      icon: const Icon(Icons.playlist_add),
                      onPressed: () =>
                          importCodexPrompt(context, ref, e, section: true),
                    ),
                    IconButton(
                      tooltip: t.codexAppendMain,
                      icon: const Icon(Icons.notes_rounded),
                      onPressed: () =>
                          importCodexPrompt(context, ref, e, section: false),
                    ),
                    IconButton(
                      tooltip: t.copyPrompt,
                      icon: const Icon(Icons.copy),
                      onPressed: () => copyCodexPrompt(context, e),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
