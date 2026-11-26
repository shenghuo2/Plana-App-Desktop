import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/horizontal_scroll_strip.dart';
import '../../../l10n/l10n.dart';
import '../tag_models.dart';

String compactLibraryLabel(String label) {
  final letters = label.characters;
  return letters.length <= 5 ? label : '${letters.take(5)}…';
}

class SidebarLibraryScope extends StatelessWidget {
  const SidebarLibraryScope({
    super.key,
    required this.publicAvailable,
    required this.publicSelected,
    required this.favorites,
    required this.onScope,
    required this.onFavorites,
    this.sources = const [],
    this.sourceIndex = -1,
    this.remoteIndex = 1,
  });

  final bool publicAvailable, publicSelected, favorites;
  final List<String> sources;
  final int sourceIndex;
  final int remoteIndex;
  final ValueChanged<int> onScope;
  final VoidCallback onFavorites;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final labelStyle = context.texts.labelLarge!.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    const buttonSize = Size(80, 42);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 12);
    Widget scope(
      String label,
      IconData icon,
      int index,
      bool selected,
    ) => Semantics(
      selected: selected,
      child: TextButton.icon(
        key: ValueKey('sidebar-scope-$index'),
        onPressed: () => onScope(index),
        style: TextButton.styleFrom(
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: labelStyle,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
          backgroundColor: selected ? scheme.primaryContainer : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
    final remoteLabels = [
      context.l10n.publicLibrary,
      ...sources,
      if (sources.isNotEmpty) context.l10n.allExternalLibraries,
    ];
    final index = remoteIndex.clamp(1, remoteLabels.length);
    Widget remote() {
      final label = remoteLabels[index - 1];
      final compact = index == 1 ? label : compactLibraryLabel(label);
      final selected = publicSelected || sourceIndex >= 0;
      return PopupMenuButton<int>(
        key: const ValueKey('sidebar-remote-picker'),
        tooltip: compact == label ? context.l10n.selectLibrarySource : label,
        position: PopupMenuPosition.under,
        onSelected: onScope,
        itemBuilder: (_) => [
          for (final (i, label) in remoteLabels.indexed)
            CheckedPopupMenuItem<int>(
              key: ValueKey('sidebar-scope-${i + 1}'),
              value: i + 1,
              checked: index == i + 1,
              child: Text(label),
            ),
        ],
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  index == 1
                      ? Icons.public
                      : Icons.collections_bookmark_outlined,
                  size: 17,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    compact,
                    semanticsLabel: label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle.copyWith(
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final scopes = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          scope(
            context.l10n.scopeMine,
            Icons.folder_outlined,
            0,
            !publicSelected && sourceIndex < 0,
          ),
          if (publicAvailable && sources.isEmpty)
            scope(context.l10n.publicLibrary, Icons.public, 1, publicSelected),
          if (sources.isNotEmpty)
            Flexible(child: SizedBox(height: 42, child: remote())),
        ],
      ),
    );
    final star = Semantics(
      selected: favorites,
      child: OutlinedButton.icon(
        key: const ValueKey('sidebar-favorites-filter'),
        onPressed: onFavorites,
        style: OutlinedButton.styleFrom(
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: labelStyle,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: favorites
              ? scheme.primaryContainer
              : scheme.surfaceContainerLowest,
          foregroundColor: favorites ? scheme.primary : scheme.onSurfaceVariant,
          side: BorderSide(
            color: favorites ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        icon: Icon(
          favorites ? Icons.star_rounded : Icons.star_border_rounded,
          size: 19,
        ),
        label: Text(context.l10n.favorites),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: sources.isEmpty
          ? OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              spacing: 6,
              overflowSpacing: 4,
              children: [scopes, star],
            )
          : Row(
              children: [
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: scopes),
                ),
                const SizedBox(width: 6),
                star,
              ],
            ),
    );
  }
}

/// Reserve equal space above and below the tab centers when the bottom track is visible.
class ScopeScrollStrip extends StatefulWidget {
  const ScopeScrollStrip({
    super.key,
    required this.controller,
    required this.child,
  });
  final ScrollController controller;
  final Widget child;
  @override
  State<ScopeScrollStrip> createState() => _ScopeScrollStripState();
}

class _ScopeScrollStripState extends State<ScopeScrollStrip> {
  bool _overflow = false;
  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (event) {
          final next = event.metrics.maxScrollExtent > 0;
          if (next != _overflow) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && next != _overflow) {
                setState(() => _overflow = next);
              }
            });
          }
          return false;
        },
        child: HorizontalScrollStrip(
          controller: widget.controller,
          showTrack: _overflow,
          shiftWheelOnly: true,
          child: Padding(
            padding: EdgeInsets.only(
              top: _overflow ? HorizontalScrollStrip.dragAreaHeight : 0,
            ),
            child: widget.child,
          ),
        ),
      );
}

class SidebarCategoryTabs extends StatelessWidget {
  const SidebarCategoryTabs({
    super.key,
    required this.categories,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    required this.controller,
    required this.itemKeys,
  });

  final List<TagCategory> categories;
  final TagCategory selected;
  final String Function(TagCategory) labelOf;
  final ValueChanged<TagCategory> onSelected;
  final ScrollController controller;
  final Map<TagCategory, GlobalKey> itemKeys;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (categories.isEmpty) return const SizedBox.shrink();
      final scheme = context.scheme;
      final inactiveColor = scheme.surfaceContainer == scheme.surface
          ? scheme.surfaceContainerLow
          : scheme.surfaceContainer;
      const gap = 5.0;
      final visibleCount = math.min(4, categories.length);
      final width = math.max(
        66.0,
        (constraints.maxWidth - (visibleCount - 1) * gap) / visibleCount,
      );
      final overflow =
          width * categories.length + gap * (categories.length - 1) >
          constraints.maxWidth + .5;
      return HorizontalScrollStrip(
        controller: controller,
        showTrack: overflow,
        child: Row(
          spacing: gap,
          children: [
            for (final category in categories)
              SizedBox(
                key: itemKeys.putIfAbsent(category, () => GlobalKey()),
                width: width,
                child: Semantics(
                  selected: category == selected,
                  child: TextButton(
                    key: ValueKey('desktop-inspiration-${category.name}'),
                    onPressed: () => onSelected(category),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: category == selected
                          ? scheme.primary
                          : inactiveColor,
                      foregroundColor: category == selected
                          ? scheme.onPrimary
                          : scheme.onSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                    child: Text(
                      labelOf(category),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: category == selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
