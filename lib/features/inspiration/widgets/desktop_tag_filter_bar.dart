import '../../../l10n/l10n.dart';
import 'package:flutter/foundation.dart' show listEquals, setEquals;
import '../../../core/ui/horizontal_scroll_strip.dart';
import 'tag_filter_chips.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';

/// Desktop tag filters and a searchable multi-select popover.
class DesktopTagFilterBar extends StatefulWidget {
  const DesktopTagFilterBar({
    super.key,
    required this.tags,
    required this.filter,
    required this.onChanged,
    this.onManage,
  });

  final List<String> tags;
  final InspirationTagFilter filter;
  final ValueChanged<InspirationTagFilter> onChanged;
  final ValueChanged<BuildContext>? onManage;

  @override
  State<DesktopTagFilterBar> createState() => _DesktopTagFilterBarState();
}

class _DesktopTagFilterBarState extends State<DesktopTagFilterBar> {
  final _scroll = ScrollController();
  final _selectedChip = GlobalKey();
  double? _viewportWidth;
  double? _contentWidth;
  bool _revealScheduled = false;
  bool _pickerOpen = false;
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  @override
  void didUpdateWidget(DesktopTagFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.filter.tags, widget.filter.tags) ||
        !listEquals(oldWidget.tags, widget.tags)) {
      _revealSelection();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _revealSelection() {
    if (_revealScheduled || widget.filter.tags.isEmpty) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final target = _selectedChip.currentContext?.findRenderObject();
      if (target == null) return;
      _scroll.position.ensureVisible(
        target,
        alignment: .5,
        duration: Motion.fast,
        curve: Curves.easeOut,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _metricsChanged(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    final contentWidth = metrics.maxScrollExtent + metrics.viewportDimension;
    if (_viewportWidth != metrics.viewportDimension ||
        _contentWidth != contentWidth) {
      _viewportWidth = metrics.viewportDimension;
      _contentWidth = contentWidth;
      final overflowing = metrics.maxScrollExtent > 0;
      if (overflowing != _overflow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            setState(() => _overflow = _scroll.position.maxScrollExtent > 0);
          }
        });
      }
      _revealSelection();
    }
    return false;
  }

  Future<void> _pickTag(BuildContext anchor) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    try {
      await showDesktopTagPicker(
        anchor,
        tags: widget.tags,
        selectedTags: widget.filter.tags,
        onChanged: (tags) {
          if (mounted) widget.onChanged(widget.filter.withTags(tags));
        },
      );
    } finally {
      _pickerOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The tag strip takes all remaining width between the fixed filters
        // and actions. A narrow sidebar gives the strip a full row of its own.
        final filters = _filters(context);
        final actions = Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.filter.tags.length >= 2)
              TextButton(
                key: const ValueKey('inspiration-clear-tags'),
                onPressed: () => widget.onChanged(widget.filter.withTags({})),
                child: Text(context.l10n.clear),
              ),
            if (widget.tags.isNotEmpty)
              Builder(
                builder: (anchor) => OutlinedButton(
                  key: const ValueKey('inspiration-all-tags'),
                  onPressed: () => _pickTag(anchor),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const StadiumBorder(),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('全部标签 · ${widget.tags.length}'),
                      const SizedBox(width: 4),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
            if (widget.onManage != null)
              Builder(
                builder: (anchor) => TextButton.icon(
                  key: const ValueKey('inspiration-manage-tags'),
                  onPressed: () => widget.onManage!(anchor),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: Text(l10nNow.manageTags),
                ),
              ),
          ],
        );
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return SizedBox(
          width: box.maxWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: box.maxWidth < 520 * textScale
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [filters, const SizedBox(height: 6), actions],
                  )
                : Row(
                    children: [
                      Expanded(child: filters),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _filters(BuildContext context) {
    final fixed = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _chip(
          context,
          label: l10nNow.all,
          selected: !widget.filter.active,
          onTap: () => widget.onChanged(const InspirationTagFilter()),
        ),
        _chip(
          context,
          label: l10nNow.favorites,
          icon: Icons.star_rounded,
          selected: widget.filter.favorites,
          onTap: () => widget.onChanged(widget.filter.toggleFavorites()),
        ),
      ],
    );
    if (widget.tags.isEmpty) return fixed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
        if (constraints.maxWidth < 420 * textScale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [fixed, const SizedBox(height: 6), _tagStrip(context)],
          );
        }
        return Row(
          children: [
            fixed,
            const SizedBox(width: 8),
            Expanded(child: _tagStrip(context)),
          ],
        );
      },
    );
  }

  Widget _tagStrip(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final labelWidth = (constraints.maxWidth - 44).clamp(24.0, 220.0);
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: _metricsChanged,
        child: HorizontalScrollStrip.scrollable(
          controller: _scroll,
          shiftWheelOnly: true,
          showTrack: _overflow,
          child: SingleChildScrollView(
            key: const ValueKey('inspiration-tag-strip'),
            controller: _scroll,
            primary: false,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              vertical: _overflow ? HorizontalScrollStrip.dragAreaHeight : 0,
            ),
            child: Row(
              children: [
                for (final tag in widget.tags)
                  Padding(
                    key: widget.filter.tags.lastOrNull == tag
                        ? _selectedChip
                        : null,
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: tag,
                      child: _chip(
                        context,
                        label: tag,
                        labelWidth: labelWidth,
                        selected: widget.filter.tags.contains(tag),
                        onTap: () =>
                            widget.onChanged(widget.filter.toggle(tag)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _chip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    double? labelWidth,
  }) {
    final scheme = context.scheme;
    return ChoiceChip(
      label: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: labelWidth ?? double.infinity),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      avatar: icon == null ? null : Icon(icon, size: 15),
      iconTheme: IconThemeData(
        color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: const StadiumBorder(),
      labelStyle: context.texts.labelMedium!.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      ),
      selectedColor: scheme.primary,
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide.none,
      showCheckmark: false,
    );
  }
}

class SelectedInspirationTags extends StatefulWidget {
  const SelectedInspirationTags({
    super.key,
    required this.tags,
    required this.onChanged,
  });
  final Set<String> tags;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<SelectedInspirationTags> createState() =>
      _SelectedInspirationTagsState();
}

class _SelectedInspirationTagsState extends State<SelectedInspirationTags> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 5, 14, 0),
    child: Row(
      children: [
        Expanded(
          child: HorizontalScrollStrip(
            controller: _scroll,
            shiftWheelOnly: true,
            child: Row(
              children: [
                for (final tag in widget.tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: InputChip(
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          tag,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onDeleted: () =>
                          widget.onChanged({...widget.tags}..remove(tag)),
                      deleteIcon: const Icon(Icons.close, size: 15),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (widget.tags.length >= 2)
          TextButton(
            key: const ValueKey('sidebar-clear-tags'),
            onPressed: () => widget.onChanged({}),
            child: Text(context.l10n.clear),
          ),
      ],
    ),
  );
}

Future<void> showDesktopTagPicker(
  BuildContext anchor, {
  required List<String> tags,
  required Set<String> selectedTags,
  required ValueChanged<Set<String>> onChanged,
}) => showDesktopPopover<void>(
  anchor,
  width: 360,
  maxHeight: 460,
  builder: (_) =>
      _TagPicker(tags: tags, selected: selectedTags, onChanged: onChanged),
);

class _TagPicker extends StatefulWidget {
  const _TagPicker({
    required this.tags,
    required this.selected,
    required this.onChanged,
  });

  final List<String> tags;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<_TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<_TagPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';
  late final _selected = {...widget.selected};

  void _toggle(String tag) {
    setState(() {
      if (!_selected.add(tag)) _selected.remove(tag);
    });
    widget.onChanged({..._selected});
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _searchTags(String value) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _query = value.trim().toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final hits = widget.tags
        .where((tag) => tag.toLowerCase().contains(_query))
        .toList();
    return Column(
      key: const ValueKey('inspiration-tag-picker'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10nNow.desktopFilterByTag,
                  style: context.texts.titleSmall,
                ),
              ),
              const CloseButton(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const ValueKey('inspiration-tag-search'),
            controller: _search,
            autofocus: true,
            onChanged: _searchTags,
            onSubmitted: (value) {
              final query = value.trim().toLowerCase();
              final index = widget.tags.indexWhere(
                (tag) => tag.toLowerCase().contains(query),
              );
              if (index >= 0) _toggle(widget.tags[index]);
            },
            decoration: InputDecoration(
              hintText: l10nNow.desktopSearchTags,
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10nNow.desktopClearSearch,
                      onPressed: () {
                        _search.clear();
                        _searchTags('');
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        if (_selected.length >= 2)
          ListTile(
            key: const ValueKey('inspiration-tag-clear'),
            dense: true,
            title: Text(context.l10n.clear),
            onTap: () {
              setState(_selected.clear);
              widget.onChanged({});
            },
          ),
        const Divider(height: 1),
        Flexible(
          child: hits.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    l10nNow.desktopNoMatchingTags,
                    textAlign: TextAlign.center,
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView.builder(
                    key: const ValueKey('inspiration-tag-list'),
                    controller: _scroll,
                    primary: false,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: hits.length,
                    itemBuilder: (context, index) {
                      final tag = hits[index];
                      final selected = _selected.contains(tag);
                      return ListTile(
                        dense: true,
                        selected: selected,
                        leading: const Icon(Icons.sell_outlined, size: 18),
                        title: Text(tag),
                        trailing: selected
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () => _toggle(tag),
                      );
                    },
                  ),
                ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
