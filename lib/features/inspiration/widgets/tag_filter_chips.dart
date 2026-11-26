import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';
import '../tag_models.dart';

class InspirationTagFilter {
  const InspirationTagFilter({this.tags = const {}, this.favorites = false});
  final Set<String> tags;
  final bool favorites;
  bool get active => favorites || tags.isNotEmpty;
  bool matches(TagEntry entry, {bool matchAny = false}) =>
      (!favorites || entry.isFavorite) &&
      (tags.isEmpty ||
          (matchAny
              ? tags.any(entry.tags.contains)
              : tags.every(entry.tags.contains)));
  InspirationTagFilter withTags(Set<String> value) =>
      InspirationTagFilter(tags: value, favorites: favorites);
  InspirationTagFilter toggle(String tag) =>
      withTags(tags.contains(tag) ? ({...tags}..remove(tag)) : {...tags, tag});
  InspirationTagFilter toggleFavorites() =>
      InspirationTagFilter(tags: tags, favorites: !favorites);
  InspirationTagFilter validFor(Iterable<String> pool) =>
      tags.every(pool.contains)
      ? this
      : withTags(tags.where(pool.contains).toSet());
}

/// 「我的」库的全部 / 收藏 / 用户标签筛选行，灵感页与角色选择器共用。
class TagFilterChips extends StatelessWidget {
  const TagFilterChips({
    super.key,
    required this.tags,
    required this.filter,
    required this.onChanged,
    required this.onManageTags,
    this.edge = 14,
  });

  final List<String> tags;
  final InspirationTagFilter filter;
  final ValueChanged<InspirationTagFilter> onChanged;
  final VoidCallback onManageTags;
  final double edge;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    Widget chip(
      String label,
      bool selected,
      VoidCallback onTap, {
      IconData? icon,
    }) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: icon == null
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: selected
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(label),
                ],
              ),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
        labelStyle: context.texts.labelMedium!.copyWith(
          fontWeight: FontWeight.w600,
          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
        selectedColor: scheme.primary,
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide.none,
        showCheckmark: false,
      ),
    );
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(edge, 4, 4, 4),
              children: [
                chip(
                  context.l10n.all,
                  !filter.active,
                  () => onChanged(const InspirationTagFilter()),
                ),
                chip(
                  '收藏',
                  filter.favorites,
                  () => onChanged(filter.toggleFavorites()),
                  icon: Icons.star_rounded,
                ),
                for (final tag in tags)
                  chip(
                    tag,
                    filter.tags.contains(tag),
                    () => onChanged(filter.toggle(tag)),
                  ),
              ],
            ),
          ),
          if (filter.tags.length >= 2)
            TextButton(
              onPressed: () => onChanged(filter.withTags({})),
              child: Text(context.l10n.clear),
            ),
          IconButton(
            tooltip: context.l10n.manageTagPool,
            icon: Icon(
              Icons.settings_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: onManageTags,
          ),
          SizedBox(width: edge - 8),
        ],
      ),
    );
  }
}
