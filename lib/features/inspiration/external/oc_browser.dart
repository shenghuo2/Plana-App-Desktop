import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/selection_bar.dart';
import '../../../core/util/name_query.dart';
import '../../../l10n/l10n.dart';
import '../../gallery/widgets/gallery_drag_selection.dart';
import '../codex/codex_image_loading.dart';
import '../tag_editor_page.dart';
import '../tag_library.dart';
import '../tag_models.dart';
import '../widgets/inspiration_entry_card.dart';
import '../widgets/inspiration_selection_bar.dart';
import '../widgets/tag_filter_chips.dart';
import 'oc_catalog.dart';
import 'oc_sources.dart';

typedef OcBrowseItem = ({OcSource source, OcCharacter character});

// The index knows characters and forms before their prompt-based card IDs are
// available. Keep candidates with private tags until the exact cards are read.
Map<String, Set<String>> _tagsByCharacter(Map<String, List<String>> overrides) {
  final grouped = <String, Set<String>>{};
  for (final e in overrides.entries) {
    final prefix = e.key.substring(0, e.key.lastIndexOf(':') + 1);
    (grouped[prefix] ??= {}).addAll(e.value);
  }
  return grouped;
}

List<OcBrowseItem> matchingOcCharacters(
  List<OcSource> sources, {
  required String search,
  required String? author,
  required InspirationTagFilter filter,
  required bool matchAny,
  required Set<String> favorites,
  Map<String, List<String>> tagOverrides = const {},
}) {
  final query = NameQuery(search);
  final byCharacter = _tagsByCharacter(tagOverrides);
  final favoriteCharacters = {
    if (filter.favorites)
      for (final id in favorites)
        if (id.startsWith('ext:')) id.substring(0, id.lastIndexOf(':') + 1),
  };
  final result = <OcBrowseItem>[];
  for (final source in sources) {
    for (final c in source.catalog.characters) {
      if (author != null && c.author != author) continue;
      final localTags = byCharacter.isEmpty
          ? null
          : byCharacter[c.entryPrefix(source.id)];
      if (localTags != null &&
          c.forms.every((f) => f.positive != null) &&
          (query.words.isNotEmpty || filter.active)) {
        // JSON catalogs already contain the prompts. Resolve edits exactly
        // without fetching media, including an explicitly empty tag list.
        final cards = groupOcForms(source.id, c, [
          for (final f in c.forms)
            (
              positive: f.positive!,
              negative: f.negative,
              images: const <String>[],
            ),
        ]);
        if (matchingOcCards(
          cards,
          query: query,
          filter: filter,
          matchAny: matchAny,
          favorites: favorites,
          tagOverrides: tagOverrides,
        ).isNotEmpty) {
          result.add((source: source, character: c));
        }
        continue;
      }
      if (!c.forms.any(
        (f) => c.matchesForm(query, f, localTags: localTags ?? const []),
      )) {
        continue;
      }
      if (filter.favorites &&
          !favoriteCharacters.contains(c.entryPrefix(source.id))) {
        continue;
      }
      if (filter.tags.isNotEmpty) {
        final tags = {
          ...c.tags,
          for (final f in c.forms) ...f.tags,
          ...?localTags,
        };
        if (!(matchAny
            ? filter.tags.any(tags.contains)
            : filter.tags.every(tags.contains))) {
          continue;
        }
      }
      result.add((source: source, character: c));
    }
  }
  return result;
}

Iterable<TagEntry> matchingOcCards(
  Iterable<TagEntry> entries, {
  required NameQuery query,
  required InspirationTagFilter filter,
  required bool matchAny,
  required Set<String> favorites,
  Map<String, List<String>> tagOverrides = const {},
}) sync* {
  for (final entry in entries) {
    final tags = tagOverrides[entry.id] ?? entry.tags;
    if (query.words.isNotEmpty &&
        query.score([
              entry.name,
              entry.createdBy ?? '',
              ...entry.aliases,
              ...tags,
              entry.positive,
            ]) ==
            0) {
      continue;
    }
    final card = entry.copyWith(
      tags: tags,
      favorite: favorites.contains(entry.id),
    );
    if (filter.matches(card, matchAny: matchAny)) yield card;
  }
}

/// Favorites and private tag edits use the resolved card ID. Other single-form
/// matches can be counted from the index without fetching offscreen details.
Future<int> countMatchingOcCards(
  List<OcBrowseItem> items,
  OcRepository repository, {
  required String search,
  required InspirationTagFilter filter,
  required bool matchAny,
  required Set<String> favorites,
  Map<String, List<String>> tagOverrides = const {},
}) async {
  final byCharacter = _tagsByCharacter(tagOverrides);
  var count = 0;
  final unresolved = <OcSource, Set<OcCharacter>>{};
  for (final item in items) {
    final c = item.character;
    final checkEdited =
        byCharacter.isNotEmpty &&
        (search.trim().isNotEmpty || filter.tags.isNotEmpty) &&
        byCharacter.containsKey(c.entryPrefix(item.source.id));
    if (c.forms.length == 1 && !filter.favorites && !checkEdited) {
      count++;
    } else {
      (unresolved[item.source] ??= {}).add(c);
    }
  }
  final query = NameQuery(search);
  for (final group in unresolved.entries) {
    final entries = await repository.referenceEntries(
      group.key,
      matches: group.value.contains,
    );
    count += matchingOcCards(
      entries,
      query: query,
      filter: filter,
      matchAny: matchAny,
      favorites: favorites,
      tagOverrides: tagOverrides,
    ).length;
  }
  return count;
}

class ExternalOcBrowser extends ConsumerStatefulWidget {
  const ExternalOcBrowser({
    super.key,
    required this.items,
    required this.sources,
    required this.query,
    this.author,
    required this.filter,
    required this.tagOverrides,
    required this.sort,
    required this.matchAny,
    required this.embedded,
    required this.limit,
    required this.scope,
    required this.onPrompt,
    this.onCharacters,
  });
  final List<OcBrowseItem> items;
  final List<OcSource> sources;
  final String scope, query;
  final String? author;
  final InspirationTagFilter filter;
  final Map<String, List<String>> tagOverrides;
  final TagSort sort;
  final bool matchAny, embedded;
  final int limit;
  final Future<void> Function(List<TagEntry>) onPrompt;
  final Future<void> Function(List<TagEntry>)? onCharacters;
  @override
  ConsumerState<ExternalOcBrowser> createState() => _ExternalOcBrowserState();
}

typedef _Tile = ({OcBrowseItem item, TagEntry? entry, String title});
typedef _Row = ({String? header, List<_Tile> tiles});

class _OcJob {
  _OcJob(this.ticket);
  final CodexLoadTicket ticket;
  int owners = 0;
}

class _ExternalOcBrowserState extends ConsumerState<ExternalOcBrowser> {
  final _loading = CodexImageLoadController();
  late final _scroll = ScrollController(
    onAttach: _loading.attach,
    onDetach: _loading.detach,
  );
  final _selected = <String, TagEntry>{};
  final _entries = <OcBrowseItem, List<TagEntry>>{};
  final _jobs = <OcBrowseItem, _OcJob>{};
  final _failed = <OcBrowseItem>{};
  bool _applying = false;

  @override
  void didUpdateWidget(ExternalOcBrowser old) {
    super.didUpdateWidget(old);
    if ((old.sort != widget.sort ||
            old.author != widget.author ||
            old.query != widget.query ||
            old.filter.favorites != widget.filter.favorites ||
            old.matchAny != widget.matchAny ||
            !setEquals(old.filter.tags, widget.filter.tags)) &&
        _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    final current = widget.sources.toSet();
    final expired = old.sources.where((s) => !current.contains(s)).toSet();
    if (expired.isNotEmpty) {
      final staleIds = {
        for (final entry in _entries.entries)
          if (expired.contains(entry.key.source))
            for (final card in entry.value) card.id,
      };
      _selected.removeWhere((id, _) => staleIds.contains(id));
      _entries.removeWhere((item, _) => expired.contains(item.source));
      _failed.removeWhere((item) => expired.contains(item.source));
    }
  }

  @override
  void dispose() {
    for (final job in _jobs.values) {
      job.ticket.cancel();
    }
    _jobs.clear();
    _loading.dispose();
    _scroll.dispose();
    super.dispose();
  }

  VoidCallback _watch(OcBrowseItem item) {
    final job = _jobs.putIfAbsent(item, () {
      final next = _OcJob(_loading.ticket());
      Future<void> load() async {
        try {
          final repository = ref.read(ocRepositoryProvider);
          await next.ticket.waitForViewport();
          final cards = await repository.character(
            item.source,
            item.character,
            schedule: next.ticket.run,
          );
          if (mounted && _jobs[item] == next) {
            setState(() => _entries[item] = cards);
          }
        } on CodexLoadCancelled {
          // This character left the viewport before its next read.
        } catch (_) {
          if (mounted && _jobs[item] == next) setState(() => _failed.add(item));
        }
      }

      unawaited(load());
      return next;
    });
    job.owners++;
    return () {
      if (--job.owners == 0 && _jobs[item] == job) {
        _jobs.remove(item);
        job.ticket.cancel();
      }
    };
  }

  void _pick(TagEntry entry) => setState(() {
    if (_selected.remove(entry.id) == null && _selected.length < widget.limit) {
      _selected[entry.id] = entry;
    }
  });

  Future<void> _open(TagEntry entry, List<TagEntry> entries) async {
    final choice = await showDialog<TagEntry>(
      context: context,
      builder: (_) => InspirationPromptDialog(
        entries: entries,
        initialEntry: entry,
        scope: widget.scope,
        categoryLabel: tagCategoryDef(TagCategory.character).label,
        selected: _selected.keys.toSet(),
        previewOf: (e) => e.previewUrl,
        isMasked: (_) => false,
        reveal: (_) {},
        browseImages: true,
      ),
    );
    if (mounted && choice != null) _pick(choice);
  }

  Future<void> _apply(Future<void> Function(List<TagEntry>) action) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      await action(_selected.values.toList());
      if (mounted) setState(_selected.clear);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  List<_Row> _rows(int columns, Set<String> favorites) {
    final query = NameQuery(widget.query);
    final byCharacter = _tagsByCharacter(widget.tagOverrides);
    final groups = <String, List<OcBrowseItem>>{};
    for (final item in widget.items) {
      (groups[widget.sort == TagSort.author ? item.character.author : ''] ??=
              [])
          .add(item);
    }
    final authors = groups.keys.toList();
    if (widget.sort == TagSort.author) {
      authors.sort((a, b) {
        if (a.isEmpty || b.isEmpty) {
          return a.isEmpty == b.isEmpty
              ? 0
              : a.isEmpty
              ? 1
              : -1;
        }
        final count = groups[b]!.length.compareTo(groups[a]!.length);
        return count != 0 ? count : naturalCompare(a, b);
      });
    }
    final rows = <_Row>[];
    for (final author in authors) {
      final items = groups[author]!;
      // A catalog without individual timestamps keeps its own sequence on ties.
      final ordered = items.indexed.toList()
        ..sort((a, b) {
          final time = b.$2.source
              .timeOf(b.$2.character)
              .compareTo(a.$2.source.timeOf(a.$2.character));
          return time != 0 ? time : a.$1.compareTo(b.$1);
        });
      final tiles = <_Tile>[];
      for (final (_, item) in ordered) {
        final entries = _entries[item];
        if (entries == null) {
          // The index supplies names before any private details or media are fetched.
          final localTags = byCharacter.isEmpty
              ? null
              : byCharacter[item.character.entryPrefix(item.source.id)];
          for (final f in item.character.forms) {
            if (!item.character.matchesForm(
              query,
              f,
              localTags: localTags ?? const [],
            )) {
              continue;
            }
            tiles.add((
              item: item,
              entry: null,
              title: item.character.formLabel(f),
            ));
          }
        } else {
          for (final card in matchingOcCards(
            entries,
            query: query,
            filter: widget.filter,
            matchAny: widget.matchAny,
            favorites: favorites,
            tagOverrides: widget.tagOverrides,
          )) {
            tiles.add((item: item, entry: card, title: card.name));
          }
        }
      }
      if (tiles.isEmpty) continue;
      if (widget.sort == TagSort.author) {
        rows.add((header: author.isEmpty ? '未认领' : author, tiles: const []));
      }
      for (var i = 0; i < tiles.length; i += columns) {
        rows.add((
          header: null,
          tiles: tiles.sublist(i, math.min(i + columns, tiles.length)),
        ));
      }
    }
    return rows;
  }

  Widget _tile(_Tile tile, double width, List<TagEntry> order) {
    if (tile.entry case final e?) {
      return MetaData(
        metaData: e.id,
        child: CodexDeferredImage(
          key: ValueKey(e.id),
          controller: _loading,
          builder: (decorate) => InspirationEntryCard(
            entry: e,
            preview: e.previewUrl,
            width: width,
            masked: false,
            selected: _selected.containsKey(e.id),
            providerDecorator: decorate,
            onSelect: () => _pick(e),
            onFavorite: () =>
                ref.read(ocFavoritesProvider.notifier).toggle(e.id),
            onMenu: (action) async {
              switch (action) {
                case InspirationEntryAction.edit:
                  final sourceEntry = _entries[tile.item]
                      ?.where((card) => card.id == e.id)
                      .firstOrNull;
                  if (sourceEntry == null) return;
                  await ref.read(tagLibraryProvider.future);
                  if (!mounted) return;
                  await showTagEditor(
                    context,
                    cat: e.category,
                    edit: sourceEntry,
                    externalSource: tile.item.source,
                  );
                case InspirationEntryAction.copy:
                  await Clipboard.setData(ClipboardData(text: e.positive));
                case InspirationEntryAction.view:
                  await _open(e, order);
              }
            },
          ),
        ),
      );
    }
    final item = tile.item;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _failed.contains(item)
                ? Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: Text(context.l10n.retry),
                      onPressed: () => setState(() => _failed.remove(item)),
                    ),
                  )
                : _OcDemand(item: item, watch: _watch),
          ),
          Padding(
            padding: const EdgeInsets.all(9),
            child: Text(
              tile.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(ocFavoritesProvider);
    final characters = widget.onCharacters;
    final onCharacters = characters == null ? null : () => _apply(characters);
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final edge = widget.embedded ? 12.0 : 24.0;
              const gap = 12.0;
              final columns = math.max(
                1,
                ((box.maxWidth - 2 * edge + gap) /
                        (widget.embedded ? 146 : 230))
                    .floor(),
              );
              final width = math.max(
                1.0,
                (box.maxWidth - 2 * edge - (columns - 1) * gap) / columns,
              );
              final height = InspirationEntryCard.extent(
                tagCategoryDef(TagCategory.character),
                width,
                MediaQuery.textScalerOf(context),
              );
              final rows = _rows(columns, favorites);
              if (rows.isEmpty) return const Center(child: Text('没有匹配的角色'));
              final order = [
                for (final row in rows)
                  for (final tile in row.tiles) ?tile.entry,
              ];
              final list = ListView.builder(
                key: const ValueKey('external-library-list'),
                controller: _scroll,
                padding: EdgeInsets.symmetric(horizontal: edge, vertical: 6),
                scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                itemCount: rows.length,
                itemExtentBuilder: (index, _) => index >= rows.length
                    ? null
                    : rows[index].header == null
                    ? height + gap
                    : 38,
                itemBuilder: (context, i) {
                  final row = rows[i];
                  if (row.header case final name?) {
                    return Row(
                      children: [
                        Icon(
                          Icons.account_circle_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 17,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(child: Divider()),
                      ],
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: gap),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, tile) in row.tiles.indexed) ...[
                          if (i > 0) const SizedBox(width: gap),
                          SizedBox(
                            width: width,
                            child: _tile(tile, width, order),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              );
              return GalleryDragSelection(
                enabled: true,
                mouseOnly: true,
                scrollController: _scroll,
                order: [for (final e in order) e.id],
                maxSelected: widget.limit,
                selected: _selected.keys.toSet(),
                onChanged: (next) => setState(() {
                  _selected.removeWhere((id, _) => !next.contains(id));
                  for (final e in order) {
                    if (next.contains(e.id)) _selected[e.id] = e;
                  }
                }),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    interactive: true,
                    child: list,
                  ),
                ),
              );
            },
          ),
        ),
        if (_selected.isNotEmpty)
          if (widget.embedded)
            SelectionBar(
              visible: true,
              safeArea: false,
              onClear: _applying ? null : () => setState(_selected.clear),
              primary: InspirationApplyActions(
                count: _selected.length,
                busy: _applying,
                onPrompt: () => _apply(widget.onPrompt),
                onCharacters: onCharacters,
              ),
            )
          else
            DesktopInspirationSelectionBar(
              count: _selected.length,
              busy: _applying,
              onClear: () => setState(_selected.clear),
              onPrompt: () => _apply(widget.onPrompt),
              onCharacters: onCharacters,
            ),
      ],
    );
  }
}

class _OcDemand extends StatefulWidget {
  const _OcDemand({required this.item, required this.watch});
  final OcBrowseItem item;
  final VoidCallback Function(OcBrowseItem) watch;
  @override
  State<_OcDemand> createState() => _OcDemandState();
}

class _OcDemandState extends State<_OcDemand> {
  late VoidCallback release;
  @override
  void initState() {
    super.initState();
    release = widget.watch(widget.item);
  }

  @override
  void didUpdateWidget(_OcDemand old) {
    super.didUpdateWidget(old);
    if (old.item != widget.item) {
      release();
      release = widget.watch(widget.item);
    }
  }

  @override
  void dispose() {
    release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
