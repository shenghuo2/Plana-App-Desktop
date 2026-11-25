import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        ScrollCacheExtent,
        SliverConstraints,
        SliverGridGeometry,
        SliverGridLayout;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/remote_image.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/horizontal_scroll_strip.dart';
import '../../../core/ui/scroll_memory.dart';
import '../../../core/ui/section_navigation.dart';
import '../../../l10n/l10n.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import 'codex_block.dart';
import 'codex_card.dart';
import 'codex_card_interactions.dart';
import 'codex_favorites.dart';
import 'codex_image_loading.dart';
import 'codex_models.dart';
import 'codex_sheets.dart';

enum _View { gallery, grouped, list }

class CodexCatalog extends ConsumerStatefulWidget {
  const CodexCatalog({
    super.key,
    required this.data,
    required this.media,
    required this.entries,
    required this.favorites,
    required this.block,
    required this.path,
    required this.query,
    required this.favoritesOnly,
    required this.newOnly,
    required this.categoryPicker,
    required this.bookPicker,
    required this.onCategory,
    required this.onFavorites,
    required this.onRecent,
    required this.onReset,
    required this.onDraw,
    this.drawWorkspace,
  });
  final CodexData data;
  final CodexMedia media;
  final List<CodexEntry> entries;
  final Set<String> favorites;
  final CodexBlock block;
  final List<String> path;
  final String query;
  final bool favoritesOnly, newOnly;
  final Widget categoryPicker, bookPicker;
  final ValueChanged<List<String>> onCategory;
  final VoidCallback onFavorites, onRecent, onReset, onDraw;
  final Widget? drawWorkspace;

  static bool hasRail(BoxConstraints box) =>
      box.maxWidth >= 940 && box.maxHeight >= 405;

  @override
  ConsumerState<CodexCatalog> createState() => _CodexCatalogState();
}

class _CodexCatalogState extends ConsumerState<CodexCatalog> {
  _View _view = _View.gallery;
  int _density = 1;
  String? _selected;
  final _expanded = <String>{};
  final _images = CodexImageLoadController();
  final _childScroll = ScrollController(keepScrollOffset: false);
  late final _scroll = MemoScrollController.keyed(
    () => _scope,
    onAttach: _images.attach,
    onDetach: _images.detach,
  );
  late final _treeScroll = MemoScrollController('codex.tree.${_meta.id}');
  late _CatalogCounts _counts;
  late int _favoriteCount;
  late List<CodexNode> _tree;

  CodexMeta get _meta => widget.data.meta;
  String get _scope => jsonEncode([
    'codex.catalog',
    _meta.id,
    _view.name,
    _density,
    widget.path,
    widget.query,
    widget.favoritesOnly,
    widget.newOnly,
  ]);

  @override
  void initState() {
    super.initState();
    _tree = widget.data.effectiveTree;
    _indexBook();
    _expandAncestors();
  }

  void _indexBook() {
    _counts = _CatalogCounts(widget.data, widget.block);
    _favoriteCount = _counts.favorites(widget.data, widget.favorites);
  }

  @override
  void didUpdateWidget(CodexCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data || widget.block != oldWidget.block) {
      _tree = widget.data.effectiveTree;
      _indexBook();
    } else if (!identical(widget.favorites, oldWidget.favorites)) {
      _favoriteCount = _counts.favorites(widget.data, widget.favorites);
    }
    if (!listEquals(widget.path, oldWidget.path)) _expandAncestors();
    if (_selected != null && !widget.entries.any((e) => e.id == _selected)) {
      _selected = null;
    }
  }

  void _expandAncestors() {
    for (var i = 1; i <= widget.path.length; i++) {
      _expanded.add(_pathKey(widget.path.take(i)));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _treeScroll.dispose();
    _childScroll.dispose();
    _images.dispose();
    super.dispose();
  }

  String get _recentLabel => (_meta.newFilterLabel?.trim().isNotEmpty ?? false)
      ? _meta.newFilterLabel!.trim()
      : context.l10n.codexRecentAdditions;

  List<CodexNode> get _children {
    var nodes = _tree;
    for (final name in widget.path) {
      nodes =
          nodes.where((n) => n.name == name).firstOrNull?.children ?? const [];
    }
    return nodes
        .where((node) => !widget.block.hides([...widget.path, node.name]))
        .toList();
  }

  Future<void> _favorite(CodexEntry entry) async {
    final notifier = ref.read(codexFavoritesProvider.notifier);
    final selected = await notifier.toggle(
      _meta.id,
      entry,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    if (mounted && !selected && notifier.isFull) {
      hintSnack(context, context.l10n.desktopFavoritesAreFull);
    }
  }

  void _open(int index) {
    if (_view == _View.list) {
      if (widget.drawWorkspace != null) widget.onDraw();
      setState(() => _selected = widget.entries[index].id);
    } else {
      showCodexDetailSheet(
        context,
        _meta,
        widget.media,
        entries: widget.entries,
        index: index,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = CodexCatalog.hasRail(bounds);
        final deck = widget.drawWorkspace;
        return Padding(
          key: const ValueKey('desktop-codex-browser'),
          padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 8, wide ? 24 : 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide) ...[
                SizedBox(
                  width: (bounds.maxWidth * .19).clamp(208.0, 264.0),
                  child: _rail(),
                ),
                const SizedBox(width: 18),
              ],
              Expanded(
                child: deck != null
                    ? (wide ? deck : _surface(deck))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!wide) ...[
                            _compactBook(),
                            const SizedBox(height: 6),
                          ],
                          _toolbar(),
                          const SizedBox(height: 8),
                          _subcategories(),
                          if (widget.favoritesOnly ||
                              widget.newOnly ||
                              widget.query.isNotEmpty)
                            _filterChips(),
                          Expanded(child: _results()),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _surface(
    Widget child, {
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) => Material(
    color: context.scheme.surfaceContainerLowest,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: context.scheme.outlineVariant),
      borderRadius: BorderRadius.circular(16),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );

  Widget _bookCard() {
    final byline = [
      _meta.author,
      _meta.version,
    ].where((s) => s.trim().isNotEmpty).join(' · ');
    return _surface(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.bookPicker,
          if (byline.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(5, 6, 5, 3),
              child: Text(
                byline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${context.l10n.codexAllEntries} · ${context.l10n.itemsN(_counts.total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.labelMedium,
                ),
              ),
              TextButton(
                onPressed: () => showCodexAboutSheet(context, _meta),
                child: Text(context.l10n.source),
              ),
            ],
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 3),
    );
  }

  Widget _rail() => Column(
    key: const ValueKey('desktop-codex-categories'),
    children: [
      _bookCard(),
      const SizedBox(height: 10),
      Expanded(
        child: _surface(
          LayoutBuilder(
            builder: (context, bounds) {
              final pinFilters =
                  bounds.maxHeight >=
                  110 + MediaQuery.textScalerOf(context).scale(110);
              final filters = Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _filterAction(recent: false),
                    _filterAction(recent: true),
                  ],
                ),
              );
              return Column(
                children: [
                  _treeHeading(),
                  Expanded(
                    child: Scrollbar(
                      controller: _treeScroll,
                      child: ListView(
                        controller: _treeScroll,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        children: [
                          _treeRow(const [], true),
                          ..._nodes(_tree, const []),
                          if (!pinFilters) ...[
                            const Divider(height: 1),
                            filters,
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (pinFilters) ...[const Divider(height: 1), filters],
                ],
              );
            },
          ),
        ),
      ),
    ],
  );

  Widget _treeHeading() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2, 6, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            widget.drawWorkspace == null
                ? context.l10n.desktopBrowseCategories
                : context.l10n.codexDrawScope,
            style: context.texts.titleSmall,
          ),
        ),
        IconButton(
          tooltip: _expanded.isEmpty
              ? context.l10n.codexExpandTree
              : context.l10n.codexCollapseTree,
          icon: Icon(
            _expanded.isEmpty ? Icons.unfold_more : Icons.unfold_less,
            size: 18,
          ),
          onPressed: () => setState(() {
            if (_expanded.isNotEmpty) {
              _expanded.clear();
            } else {
              void expand(List<CodexNode> nodes, List<String> path) {
                for (final node in nodes.where((n) => n.children.isNotEmpty)) {
                  final next = [...path, node.name];
                  _expanded.add(_pathKey(next));
                  expand(node.children, next);
                }
              }

              expand(_tree, const []);
            }
          }),
        ),
      ],
    ),
  );

  Iterable<Widget> _nodes(List<CodexNode> nodes, List<String> parent) sync* {
    for (final node in nodes) {
      final path = [...parent, node.name];
      yield _treeRow(path, node.children.isNotEmpty);
      if (_expanded.contains(_pathKey(path)) && !widget.block.hides(path)) {
        yield* _nodes(node.children, path);
      }
    }
  }

  Widget _treeRow(List<String> path, bool hasChildren) {
    final id = _pathKey(path);
    final enabled = !widget.block.hides(path);
    final root = path.isEmpty;
    return ListTile(
      key: ValueKey('codex-category-${path.join('/')}'),
      dense: true,
      minTileHeight: 36,
      visualDensity: VisualDensity.compact,
      enabled: enabled,
      selected: listEquals(path, widget.path),
      selectedTileColor: context.scheme.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: EdgeInsets.only(
        left: 6 + math.min(path.length, 4) * 6,
        right: 9,
      ),
      title: Row(
        children: [
          if (hasChildren && !root)
            SizedBox.square(
              dimension: 26,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: _expanded.contains(id)
                    ? context.l10n.codexCollapseTree
                    : context.l10n.codexExpandTree,
                icon: Icon(
                  _expanded.contains(id)
                      ? Icons.expand_more
                      : Icons.chevron_right,
                  size: 16,
                ),
                onPressed: enabled
                    ? () => setState(() {
                        if (!_expanded.remove(id)) _expanded.add(id);
                      })
                    : null,
              ),
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: Text(
              root ? context.l10n.allCategories : path.last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 5),
          Text('${_counts.paths[id] ?? 0}', style: context.texts.labelSmall),
        ],
      ),
      onTap: () => widget.onCategory(path),
    );
  }

  Widget _filterAction({required bool recent, bool compact = false}) {
    final selected = recent ? widget.newOnly : widget.favoritesOnly;
    final label = recent ? _recentLabel : context.l10n.codexMyFavorites;
    final count = recent ? _counts.recent : _favoriteCount;
    final icon = recent
        ? Icons.auto_awesome_outlined
        : (selected ? Icons.star_rounded : Icons.star_outline);
    final key = ValueKey(
      recent ? 'desktop-codex-recent' : 'desktop-codex-favorites',
    );
    final action = recent ? widget.onRecent : widget.onFavorites;
    if (compact) {
      return IconButton(
        key: key,
        tooltip: '$label · $count',
        onPressed: action,
        isSelected: selected,
        color: selected ? context.scheme.primary : null,
        icon: Icon(icon, size: 20),
      );
    }
    return ListTile(
      key: key,
      dense: true,
      minTileHeight: 34,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 9),
      minLeadingWidth: 20,
      horizontalTitleGap: 8,
      leading: Icon(icon, size: 19),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text('$count', style: context.texts.labelMedium),
      selected: selected,
      selectedTileColor: context.scheme.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onTap: action,
    );
  }

  Widget _compactBook() => _surface(
    Row(
      children: [
        Flexible(child: widget.bookPicker),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${context.l10n.codexAllEntries} · ${context.l10n.itemsN(_counts.total)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: context.l10n.source,
          icon: const Icon(Icons.info_outline, size: 18),
          onPressed: () => showCodexAboutSheet(context, _meta),
        ),
        _filterAction(recent: false, compact: true),
        _filterAction(recent: true, compact: true),
      ],
    ),
    padding: const EdgeInsets.symmetric(horizontal: 6),
  );

  Widget _breadcrumbs() {
    final style = context.texts.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
    );
    final path = widget.path;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i <= path.length; i++) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: context.scheme.outline,
              ),
            if (i != path.length)
              TextButton(
                onPressed: () => widget.onCategory(path.take(i).toList()),
                child: Text(i == 0 ? context.l10n.allCategories : path[i - 1]),
              )
            else
              Text(
                i == 0 ? context.l10n.allCategories : path[i - 1],
                style: style,
              ),
          ],
          const SizedBox(width: 10),
          Text(
            context.l10n.itemsN(widget.entries.length),
            key: const ValueKey('codex-results-count'),
            style: context.texts.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _toolbar() => LayoutBuilder(
    builder: (context, box) {
      final t = context.l10n;
      final views = Material(
        color: context.scheme.surfaceContainerHigh,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in _View.values)
              IconButton(
                key: ValueKey('codex-view-${mode.name}'),
                isSelected: _view == mode,
                tooltip: [
                  t.codexGalleryView,
                  t.codexGroupedView,
                  t.codexListView,
                ][mode.index],
                icon: Icon(
                  [
                    Icons.grid_view_outlined,
                    Icons.view_agenda_outlined,
                    Icons.view_list_outlined,
                  ][mode.index],
                  size: 18,
                ),
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                  shape: const RoundedRectangleBorder(),
                  backgroundColor: _view == mode
                      ? context.scheme.primaryContainer
                      : null,
                  foregroundColor: _view == mode
                      ? context.scheme.onPrimaryContainer
                      : null,
                ),
                onPressed: () => setState(() {
                  _view = mode;
                  _selected = null;
                }),
              ),
          ],
        ),
      );
      final controls = Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: widget.categoryPicker,
          ),
          if (_view != _View.list)
            Tooltip(
              message: t.codexCardDensity,
              child: OutlinedButton(
                key: const ValueKey('codex-density'),
                onPressed: () => setState(() => _density = (_density + 1) % 3),
                child: Text(
                  [
                    t.codexDensityCompact,
                    t.codexDensityNormal,
                    t.codexDensityLarge,
                  ][_density],
                ),
              ),
            ),
          views,
        ],
      );
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (box.maxWidth >= 656 * scale) {
        return Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _breadcrumbs(),
              ),
            ),
            const SizedBox(width: 8),
            controls,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_breadcrumbs(), const SizedBox(height: 6), controls],
      );
    },
  );

  Widget _subcategories() {
    final children = _children;
    if (children.isEmpty) return const SizedBox.shrink();
    return HorizontalScrollStrip(
      key: ValueKey((_meta.id, _pathKey(widget.path))),
      controller: _childScroll,
      child: Row(
        children: [
          for (final node in children)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: OutlinedButton(
                key: ValueKey('codex-child-${node.name}'),
                onPressed: () => widget.onCategory([...widget.path, node.name]),
                child: Text(
                  '${node.name}  ${_counts.paths[_pathKey([...widget.path, node.name])] ?? 0}',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterChips() => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (widget.favoritesOnly)
          InputChip(
            label: Text(context.l10n.codexOnlyFavorites),
            onDeleted: widget.onFavorites,
          ),
        if (widget.newOnly)
          InputChip(label: Text(_recentLabel), onDeleted: widget.onRecent),
        TextButton(
          onPressed: widget.onReset,
          child: Text(context.l10n.codexResetFilters),
        ),
      ],
    ),
  );

  Widget _results() {
    if (widget.entries.isEmpty) {
      return Center(
        child: Text(
          widget.favoritesOnly
              ? context.l10n.codexEmptyFavorites
              : context.l10n.noMatchingEntries,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final index =
            widget.drawWorkspace != null ||
                _view != _View.list ||
                _selected == null
            ? -1
            : widget.entries.indexWhere((e) => e.id == _selected);
        final inspector = index < 0
            ? null
            : buildCodexListInspector(
                _meta,
                widget.media,
                entries: widget.entries,
                index: index,
                onSelect: _open,
                onClose: () => setState(() => _selected = null),
              );
        final dock = bounds.maxWidth >= 830;
        final width = math.min(
          bounds.maxWidth,
          (bounds.maxWidth * .35).clamp(330.0, 460.0),
        );
        final browser = _browser();
        // The scrollable stays in the same element slot when an inspector is opened or closed.
        return Stack(
          children: [
            Positioned.fill(
              right: inspector != null && dock ? width + 10 : 0,
              child: KeyedSubtree(
                key: PageStorageKey(_scope),
                child: _view == _View.grouped
                    ? browser
                    : Scrollbar(
                        controller: _scroll,
                        thumbVisibility: true,
                        child: browser,
                      ),
              ),
            ),
            if (inspector != null)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: width,
                child: Material(
                  color: context.scheme.surfaceContainerLowest,
                  elevation: dock ? 0 : 6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: context.scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: inspector,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _browser() => LayoutBuilder(
    builder: (context, box) {
      if (_view == _View.list) {
        final extent = math.max(
          66.0,
          20 + MediaQuery.textScalerOf(context).scale(34),
        );
        return ListView.builder(
          key: const ValueKey('codex-compact-list'),
          controller: _scroll,
          padding: const EdgeInsets.only(right: 8, bottom: 12),
          itemExtent: extent,
          itemCount: widget.entries.length,
          itemBuilder: (context, i) => _entryRow(i, box.maxWidth),
        );
      }
      final layout = CodexCard.desktopGrid(
        context,
        box.maxWidth -
            (_view == _View.grouped ? _GroupedGallery.rightInset : 8),
        embedded: false,
        targetWidth: [180.0, 230.0, 280.0][_density],
        previewAspectRatio: [.88, .80, .75][_density],
      );
      if (_view == _View.grouped) {
        return _GroupedGallery(
          entries: widget.entries,
          scroll: _scroll,
          layout: layout.delegate,
          headerHeight: math.max(
            48.0,
            MediaQuery.textScalerOf(context).scale(18) + 20,
          ),
          buildCard: _card,
          width: layout.width,
          onCategory: widget.onCategory,
          onDraw: (p) {
            widget.onCategory(p);
            if (widget.drawWorkspace == null) widget.onDraw();
          },
        );
      }
      return GridView.builder(
        key: const ValueKey('desktop-codex-grid'),
        controller: _scroll,
        padding: const EdgeInsets.only(right: 8, bottom: 12),
        gridDelegate: layout.delegate,
        scrollCacheExtent: const ScrollCacheExtent.pixels(692),
        itemCount: widget.entries.length,
        itemBuilder: (context, i) => _card(i, layout.width),
      );
    },
  );

  Widget _card(int i, double width) {
    final e = widget.entries[i];
    return CodexCard(
      key: ValueKey('desktop-codex-card-${e.id}'),
      entry: e,
      codex: _meta,
      media: widget.media,
      desktop: true,
      compactFooter: true,
      showCategory: _view == _View.gallery && !listEquals(widget.path, e.path),
      imageLoading: _images,
      decodeWidth: width,
      favorite: widget.favorites.contains(codexFavKey(_meta.id, e.id)),
      onFavorite: () async => _favorite(e),
      onTap: () => _open(i),
    );
  }

  Widget _entryRow(int i, double width) {
    final e = widget.entries[i], scheme = context.scheme;
    final image = codexImageUrl(_meta, e, widget.media);
    final starred = widget.favorites.contains(codexFavKey(_meta.id, e.id));
    return Material(
      key: ValueKey('codex-row-${e.id}'),
      color: _selected == e.id
          ? scheme.secondaryContainer
          : scheme.surfaceContainerLowest,
      child: InkWell(
        onTap: () => _open(i),
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.square(
                  dimension: 46,
                  child: image == null
                      ? Icon(Icons.menu_book_outlined, color: scheme.outline)
                      : CodexDeferredImage(
                          controller: _images,
                          builder: (decorate) => RemoteImage(
                            image,
                            fit: BoxFit.cover,
                            decodeWidth: 46,
                            decodeHeight: 46,
                            providerDecorator: decorate,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      e.fullText.replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall,
                    ),
                  ],
                ),
              ),
              if (width >= 610)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      e.path.join(' / '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall,
                    ),
                  ),
                ),
              if (width >= 710 && e.postCount != null)
                Text('post ${e.postCount}', style: context.texts.labelSmall),
              IconButton(
                tooltip: context.l10n.favorites,
                isSelected: starred,
                onPressed: () => _favorite(e),
                icon: const Icon(Icons.star_outline, size: 18),
                selectedIcon: const Icon(Icons.star, size: 18),
              ),
              if (width >= 350) ...[
                IconButton(
                  tooltip: context.l10n.copyPrompt,
                  icon: const Icon(Icons.copy_outlined, size: 17),
                  onPressed: () => copyCodexPrompt(context, e),
                ),
                IconButton(
                  tooltip: context.l10n.codexNewSection,
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () =>
                      importCodexPrompt(context, ref, e, section: true),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _pathKey(Iterable<String> names) => names.join('\u0000');

/// Counts follow the same representative-per-artist rule as a filtered result.
class _CatalogCounts {
  _CatalogCounts(CodexData data, CodexBlock block) {
    final byPath = <String, Set<Object>>{};
    final newIds = <Object>{};
    for (final e in data.entries) {
      if (block.hides(e.path)) continue;
      final Object id = data.specimens[e.id]?.artist ?? e.id;
      visible[e.id] = id;
      var path = '';
      (byPath[path] ??= {}).add(id);
      for (final part in e.path) {
        path = path.isEmpty ? part : '$path\u0000$part';
        (byPath[path] ??= {}).add(id);
      }
      if (e.isNew) newIds.add(id);
    }
    paths = byPath.map((path, ids) => MapEntry(path, ids.length));
    recent = newIds.length;
  }
  late final Map<String, int> paths;
  late final int recent;
  final visible = <String, Object>{};
  int get total => paths[''] ?? 0;
  int favorites(CodexData data, Set<String> keys) => {
    for (final e in visible.entries)
      if (keys.contains(codexFavKey(data.meta.id, e.key))) e.value,
  }.length;
}

/// One lazy viewport for all groups. Offscreen groups do not load sample images.
class _GroupedGallery extends StatefulWidget {
  const _GroupedGallery({
    required this.entries,
    required this.scroll,
    required this.layout,
    required this.headerHeight,
    required this.buildCard,
    required this.width,
    required this.onCategory,
    required this.onDraw,
  });
  static const double rightInset = 56;
  final List<CodexEntry> entries;
  final ScrollController scroll;
  final SliverGridDelegateWithFixedCrossAxisCount layout;
  final Widget Function(int, double) buildCard;
  final double width, headerHeight;
  final ValueChanged<List<String>> onCategory, onDraw;

  @override
  State<_GroupedGallery> createState() => _GroupedGalleryState();
}

typedef _GroupLine = ({List<String> path, List<int> items, int start});

typedef _GroupSection = ({String id, List<String> path, int row});

class _GroupedGalleryState extends State<_GroupedGallery> {
  late List<_GroupLine> _lines;
  late _GroupRowDelegate _rows;
  late List<_GroupSection> _groups;
  late Set<String> _ambiguousNames;
  final _activeGroup = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _index();
    widget.scroll.addListener(_syncActiveGroup);
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_syncActiveGroup);
    _activeGroup.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_GroupedGallery old) {
    super.didUpdateWidget(old);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_syncActiveGroup);
      widget.scroll.addListener(_syncActiveGroup);
    }
    if (old.entries != widget.entries ||
        old.layout.crossAxisCount != widget.layout.crossAxisCount) {
      _index();
    } else if (old.headerHeight != widget.headerHeight ||
        old.layout.mainAxisExtent != widget.layout.mainAxisExtent ||
        old.layout.mainAxisSpacing != widget.layout.mainAxisSpacing) {
      _measureRows();
    }
  }

  void _index() {
    final groups = <String, List<int>>{};
    for (var i = 0; i < widget.entries.length; i++) {
      (groups[_pathKey(widget.entries[i].path)] ??= []).add(i);
    }
    final columns = widget.layout.crossAxisCount;
    _lines = [];
    _groups = [];
    _ambiguousNames = {};
    final seenNames = <String>{};
    for (final group in groups.entries) {
      final items = group.value;
      final path = widget.entries[items.first].path;
      _groups.add((id: group.key, path: path, row: _lines.length));
      if (path.isNotEmpty && !seenNames.add(path.last)) {
        _ambiguousNames.add(path.last);
      }
      for (var start = -columns; start < items.length; start += columns) {
        _lines.add((path: path, items: items, start: start));
      }
    }
    _measureRows();
  }

  void _measureRows() {
    final cardHeight =
        widget.layout.mainAxisExtent! + widget.layout.mainAxisSpacing;
    final offsets = <double>[0];
    for (final line in _lines) {
      offsets.add(
        offsets.last + (line.start < 0 ? widget.headerHeight : cardHeight),
      );
    }
    _rows = _GroupRowDelegate(offsets);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncActiveGroup();
    });
  }

  void _syncActiveGroup() {
    final scroll = widget.scroll;
    if (_groups.isEmpty || !scroll.hasClients || scroll.positions.length != 1) {
      return;
    }
    final y = scroll.position.pixels;
    var low = 0, high = _groups.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_rows.offsets[_groups[mid].row] <= y + .01) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    _activeGroup.value = low;
  }

  void _jumpToGroup(int index) {
    final scroll = widget.scroll;
    if (!scroll.hasClients || !scroll.position.hasContentDimensions) return;
    final position = scroll.position;
    scroll.jumpTo(
      _rows.offsets[_groups[index].row].clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  String _groupName(_GroupSection group) {
    final path = group.path;
    if (path.isEmpty) return context.l10n.codexCategoryless;
    if (path.length == 1 || !_ambiguousNames.contains(path.last)) {
      return path.last;
    }
    return '${path.last} · ${path.take(path.length - 1).join(' / ')}';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (_groups.isEmpty) return const SizedBox.shrink();
      // Leave just enough space for the final heading to reach the top, too.
      final lastGroupHeight =
          _rows.offsets.last - _rows.offsets[_groups.last.row];
      final bottom = _groups.length > 1
          ? math.max(12.0, box.maxHeight - lastGroupHeight)
          : 12.0;
      return Stack(
        children: [
          // A touch on the index must not also page the scrollbar track.
          Positioned.fill(
            child: Scrollbar(
              controller: widget.scroll,
              thumbVisibility: true,
              child: _grid(bottom),
            ),
          ),
          Positioned.fill(
            left: null,
            right: 12,
            child: Align(
              alignment: Alignment.centerRight,
              child: ValueListenableBuilder<int>(
                valueListenable: _activeGroup,
                builder: (context, active, _) => SectionNavigation<_GroupSection>(
                  entries: _groups,
                  activeIndex: active.clamp(0, _groups.length - 1),
                  idOf: (g) => g.id,
                  labelOf: _groupName,
                  onSelect: _jumpToGroup,
                  maxHeight: math.max(40, box.maxHeight - 32),
                  maxWidth: math.min(320, math.max(44, box.maxWidth - 24)),
                  keyPrefix: 'codex-group',
                  ticksOnly: true,
                  semanticLabel: context.l10n.codexGroupNavigation,
                  describePosition: (n) =>
                      '$n / ${_groups.length} · ${_groupName(_groups[n - 1])}',
                  hint: context.l10n.codexGroupNavigationHint,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _grid(double bottom) {
    final cols = widget.layout.crossAxisCount;
    return GridView.builder(
      gridDelegate: _rows,
      key: const ValueKey('codex-grouped-gallery'),
      controller: widget.scroll,
      padding: EdgeInsets.only(
        right: _GroupedGallery.rightInset,
        bottom: bottom,
      ),
      itemCount: _lines.length,
      itemBuilder: (context, i) {
        final line = _lines[i];
        if (line.start < 0) {
          return Row(
            key: ValueKey('codex-group-heading-${_pathKey(line.path)}'),
            children: [
              Expanded(
                child: Text(
                  '${line.path.lastOrNull ?? context.l10n.codexCategoryless}  ·  ${context.l10n.itemsN(line.items.length)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleSmall,
                ),
              ),
              if (line.path.isNotEmpty) ...[
                TextButton.icon(
                  onPressed: () => widget.onDraw(line.path),
                  icon: const Icon(Icons.casino_outlined, size: 16),
                  label: Text(context.l10n.codexDrawCategory),
                ),
                TextButton(
                  onPressed: () => widget.onCategory(line.path),
                  child: Text(context.l10n.codexEnterCategory),
                ),
              ],
            ],
          );
        }
        // Keep animation listeners local to the row when the viewport recycles cards.
        return TickerMode(
          enabled: true,
          child: Padding(
            padding: EdgeInsets.only(bottom: widget.layout.mainAxisSpacing),
            child: SizedBox(
              height: widget.layout.mainAxisExtent,
              child: Row(
                children: [
                  for (
                    var col = 0;
                    col < cols && line.start + col < line.items.length;
                    col++
                  ) ...[
                    if (col > 0)
                      SizedBox(width: widget.layout.crossAxisSpacing),
                    SizedBox(
                      width: widget.width,
                      child: widget.buildCard(
                        line.items[line.start + col],
                        widget.width,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Each slot is a full-width group header or card row. An indexed layout lets
/// the viewport seek straight to a dragged thumb without laying out intervening cards.
class _GroupRowDelegate extends SliverGridDelegate {
  const _GroupRowDelegate(this.offsets);
  final List<double> offsets;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) =>
      _GroupRowLayout(offsets, constraints.crossAxisExtent);

  @override
  bool shouldRelayout(_GroupRowDelegate oldDelegate) =>
      offsets != oldDelegate.offsets;
}

class _GroupRowLayout extends SliverGridLayout {
  const _GroupRowLayout(this.offsets, this.width);
  final List<double> offsets;
  final double width;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    var low = 0;
    var high = offsets.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (offsets[mid + 1] <= scrollOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    final row = getMinChildIndexForScrollOffset(scrollOffset);
    return row > 0 && offsets[row] >= scrollOffset ? row - 1 : row;
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    // The sliver can query the position immediately past the last row.
    final start = offsets[index];
    return SliverGridGeometry(
      scrollOffset: start,
      crossAxisOffset: 0,
      mainAxisExtent: index + 1 < offsets.length
          ? offsets[index + 1] - start
          : 0,
      crossAxisExtent: width,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) => offsets[childCount];
}
