import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';
import '../../generate/widgets/reference_image_preview.dart';
import '../tag_models.dart';
import 'prompt_chips.dart';
import 'tag_card.dart';

enum InspirationEntryAction { edit, copy, view }

class InspirationPromptDialog extends StatefulWidget {
  const InspirationPromptDialog({
    super.key,
    required this.entries,
    required this.initialEntry,
    required this.scope,
    required this.categoryLabel,
    required this.selected,
    required this.previewOf,
    required this.isMasked,
    required this.reveal,
  });

  final List<TagEntry> entries;
  final TagEntry initialEntry;
  final String scope, categoryLabel;
  final Set<String> selected;
  final String? Function(TagEntry) previewOf;
  final bool Function(TagEntry) isMasked;
  final ValueChanged<TagEntry> reveal;

  @override
  State<InspirationPromptDialog> createState() =>
      _InspirationPromptDialogState();
}

class _InspirationPromptDialogState extends State<InspirationPromptDialog> {
  late int index = widget.entries.indexWhere(
    (e) => e.id == widget.initialEntry.id,
  );

  void _move(int step) {
    final next = index + step;
    if (next >= 0 && next < widget.entries.length) {
      setState(() => index = next);
    }
  }

  Widget _art(TagEntry entry) {
    final masked = widget.isMasked(entry);
    final url = widget.previewOf(entry);
    final preview = TagCardPreview(
      url: url,
      name: entry.name,
      mosaic: masked,
      fit: BoxFit.contain,
    );
    return ColoredBox(
      color: context.scheme.surfaceContainerLow,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!masked && url != null && url.isNotEmpty)
            Tooltip(
              message: context.l10n.desktopOpenFullImage,
              child: InkWell(
                key: const ValueKey('inspiration-enlarge-image'),
                mouseCursor: SystemMouseCursors.zoomIn,
                onTap: () => showImageProviderPreview(
                  context,
                  title: entry.name,
                  image: url.startsWith('http')
                      ? RemoteImageProvider(
                          url,
                          version: RemoteImageStore.versionOf(url),
                        )
                      : FileImage(File(url)),
                ),
                child: preview,
              ),
            )
          else
            preview,
          if (masked)
            Center(
              child: FilledButton.tonalIcon(
                onPressed: () {
                  widget.reveal(entry);
                  setState(() {});
                },
                icon: const Icon(Icons.visibility_outlined),
                label: Text(context.l10n.desktopClickToShowOriginal),
              ),
            ),
        ],
      ),
    );
  }

  Widget _description(TagEntry entry) => Padding(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.tags.isNotEmpty) ...[
          Text(
            context.l10n.tagLabel,
            style: context.texts.labelMedium?.copyWith(
              color: context.scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(entry.tags.join(' · '), style: context.texts.bodyMedium),
          const SizedBox(height: 16),
        ],
        Text(context.l10n.positivePrompt, style: context.texts.titleSmall),
        const SizedBox(height: 6),
        PromptChips.single(
          entry.positive,
          key: ValueKey('positive-${entry.id}'),
        ),
        if (entry.negative.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(context.l10n.negativePrompt, style: context.texts.titleSmall),
          const SizedBox(height: 6),
          PromptChips.single(
            entry.negative,
            key: ValueKey('negative-${entry.id}'),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final entry = widget.entries[index];
    final hasArt = tagCategoryDef(entry.category).hasPreview;
    final selected = widget.selected.contains(entry.id);
    final apply = Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      child: FilledButton.icon(
        key: const ValueKey('inspiration-detail-select'),
        onPressed: () => Navigator.pop(context, entry),
        icon: Icon(
          selected ? Icons.remove_circle_outline : Icons.check,
          size: 18,
        ),
        label: Text(
          selected
              ? context.l10n.sidebarDeselectAndReturn
              : context.l10n.sidebarSelectAndReturn,
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          key: const ValueKey('inspiration-prompt-detail'),
          backgroundColor: context.scheme.surfaceContainerLowest,
          insetPadding: const EdgeInsets.all(20),
          clipBehavior: Clip.antiAlias,
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
          child: SizedBox(
            width: 720,
            height: 520,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${widget.scope} / ${widget.categoryLabel}',
                              style: context.texts.labelSmall?.copyWith(
                                color: context.scheme.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const CloseButton(),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      final wide = hasArt && bounds.maxWidth >= 500;
                      final details = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              key: ValueKey(entry.id),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (hasArt && !wide)
                                    SizedBox(
                                      height: math.min(
                                        205,
                                        bounds.maxHeight * .42,
                                      ),
                                      child: _art(entry),
                                    ),
                                  _description(entry),
                                ],
                              ),
                            ),
                          ),
                          apply,
                        ],
                      );
                      if (!wide) return details;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 5, child: _art(entry)),
                          const VerticalDivider(width: 1),
                          Expanded(flex: 4, child: details),
                        ],
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: context.l10n.sidebarPreviousEntry,
                        onPressed: index == 0 ? null : () => _move(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '${index + 1} / ${widget.entries.length}',
                        style: context.texts.labelMedium,
                      ),
                      IconButton(
                        tooltip: context.l10n.sidebarNextEntry,
                        onPressed: index == widget.entries.length - 1
                            ? null
                            : () => _move(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InspirationEntryCard extends StatelessWidget {
  const InspirationEntryCard({
    super.key,
    required this.entry,
    required this.preview,
    required this.width,
    required this.selected,
    required this.masked,
    required this.onSelect,
    required this.onFavorite,
    required this.onMenu,
    this.onSecondaryTapDown,
  });
  final TagEntry entry;
  final String? preview;
  final double width;
  final bool selected, masked;
  final VoidCallback onSelect, onFavorite;
  final ValueChanged<InspirationEntryAction> onMenu;
  final GestureTapDownCallback? onSecondaryTapDown;

  static double extent(
    TagCategoryDef category,
    double width,
    TextScaler scale,
  ) {
    final aspect = category.hasPreview
        ? math.max(kInspirationPortraitCardAspect, category.previewAspect)
        : 1.5;
    return math.max(category.hasPreview ? 56.0 : 98.0, width / aspect) +
        25 +
        scale.scale(32);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final tags = entry.tags;
    final previewTags = [...tags.take(2), if (tags.length > 2) '…'].join(' · ');
    final actions = [
      (InspirationEntryAction.edit, Icons.edit_outlined, context.l10n.edit),
      (
        InspirationEntryAction.copy,
        Icons.copy_outlined,
        context.l10n.copyPrompt,
      ),
      (
        InspirationEntryAction.view,
        Icons.visibility_outlined,
        context.l10n.viewPrompt,
      ),
    ];
    return Material(
      key: ValueKey('inspiration-card-${entry.id}'),
      color: scheme.surfaceContainerLowest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onSelect,
        onSecondaryTapDown: onSecondaryTapDown,
        onLongPress: () => onMenu(InspirationEntryAction.view),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (tagCategoryDef(entry.category).hasPreview)
                    TagCardPreview(
                      name: entry.name,
                      url: preview,
                      mosaic: masked,
                      alignment: entry.category == TagCategory.character
                          ? Alignment.topCenter
                          : Alignment.center,
                      decodeWidth: width,
                    )
                  else
                    TagTextPreview(
                      text: entry.positive,
                      padding: const EdgeInsets.fromLTRB(10, 37, 10, 6),
                    ),
                  if (masked)
                    Center(
                      child: Tooltip(
                        message: context.l10n.desktopClickToShowOriginal,
                        child: Chip(
                          label: const Icon(
                            Icons.visibility_off_outlined,
                            size: 18,
                          ),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: scheme.surface,
                        ),
                      ),
                    ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Semantics(
                      checked: selected,
                      child: IconButton(
                        key: ValueKey('inspiration-select-${entry.id}'),
                        tooltip: selected
                            ? context.l10n.clearSelection
                            : context.l10n.sidebarPickEntry,
                        onPressed: onSelect,
                        style: IconButton.styleFrom(
                          fixedSize: const Size.square(30),
                          minimumSize: Size.zero,
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? scheme.primary
                                : scheme.scrim.withValues(alpha: .30),
                            border: Border.all(
                              color: scheme.surfaceContainerLowest.withValues(
                                alpha: .9,
                              ),
                              width: 1.5,
                            ),
                          ),
                          child: selected
                              ? Icon(
                                  Icons.check_rounded,
                                  size: 16,
                                  color: scheme.onPrimary,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton(
                      key: ValueKey('inspiration-star-${entry.id}'),
                      tooltip: entry.isFavorite
                          ? context.l10n.unfavorite
                          : context.l10n.favorites,
                      onPressed: onFavorite,
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.surfaceContainerLowest
                            .withValues(alpha: .94),
                        foregroundColor: entry.isFavorite
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fixedSize: const Size.square(27),
                        minimumSize: Size.zero,
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: Icon(
                        entry.isFavorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 6, 7, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: tags.isEmpty
                            ? const SizedBox.shrink()
                            : Tooltip(
                                message: tags.join(' · '),
                                child: Text(
                                  previewTags,
                                  key: ValueKey('inspiration-tags-${entry.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                      ),
                      PopupMenuButton<InspirationEntryAction>(
                        key: ValueKey('inspiration-menu-${entry.id}'),
                        tooltip: context.l10n.sidebarEntryMenu,
                        position: PopupMenuPosition.under,
                        onSelected: onMenu,
                        itemBuilder: (_) => [
                          for (final (action, icon, label) in actions)
                            PopupMenuItem(
                              value: action,
                              height: 40,
                              child: Row(
                                children: [
                                  Icon(
                                    icon,
                                    size: 18,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(label),
                                ],
                              ),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (width >= 100)
                                Text(
                                  context.l10n.sidebarEntryMenu,
                                  style: context.texts.labelSmall?.copyWith(
                                    color: scheme.primary,
                                  ),
                                ),
                              Icon(
                                Icons.expand_more,
                                size: 15,
                                color: scheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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
