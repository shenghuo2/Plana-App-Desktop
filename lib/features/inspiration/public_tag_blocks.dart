import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import 'tag_models.dart';

/// Public IDs are unique within one category. An author rule includes future
/// publications, with per-entry exceptions when a user unticks one card.
class PublicTagRule {
  const PublicTagRule({this.items = const {}, this.authors = const {}});
  final Set<String> items;
  final Map<String, Set<String>> authors;

  bool get active => items.isNotEmpty || authors.isNotEmpty;

  bool hides(TagEntry entry, {TagEntry? publicSource}) {
    final id =
        publicSource?.publicId ??
        entry.publicId ??
        publicSource?.id ??
        entry.id;
    final sourceOwner = publicSource?.createdBy?.trim();
    final exceptions =
        authors[sourceOwner != null && sourceOwner.isNotEmpty
            ? sourceOwner
            : entry.createdBy?.trim()];
    return items.contains(id) ||
        (exceptions != null && !exceptions.contains(id));
  }

  PublicTagRule selectItems(Iterable<TagEntry> entries, bool block) {
    final ids = {...items};
    final groups = {
      for (final e in authors.entries) e.key: {...e.value},
    };
    for (final entry in entries) {
      final id = entry.publicId ?? entry.id;
      final exceptions = groups[entry.createdBy?.trim()];
      if (exceptions != null) {
        block ? exceptions.remove(id) : exceptions.add(id);
        ids.remove(id);
      } else {
        block ? ids.add(id) : ids.remove(id);
      }
    }
    return PublicTagRule(items: ids, authors: groups);
  }

  PublicTagRule selectAuthor(
    String author,
    Iterable<TagEntry> catalog,
    bool block,
  ) {
    final ids = {...items}
      ..removeAll([
        for (final entry in catalog)
          if (entry.createdBy?.trim() == author) entry.publicId ?? entry.id,
      ]);
    final groups = {...authors};
    if (block) {
      groups[author] = {};
    } else {
      groups.remove(author);
    }
    return PublicTagRule(items: ids, authors: groups);
  }

  Map<String, Object> toJson() => {
    'items': items.toList(),
    'authors': {for (final e in authors.entries) e.key: e.value.toList()},
  };

  static PublicTagRule fromJson(Object? json) {
    if (json is! Map) return const PublicTagRule();
    Set<String> ids(Object? raw) =>
        raw is List ? raw.whereType<String>().toSet() : {};
    return PublicTagRule(
      items: ids(json['items']),
      authors: {
        if (json['authors'] case final Map authors)
          for (final e in authors.entries)
            if (e.key is String && e.value is List)
              e.key as String: ids(e.value),
      },
    );
  }
}

final publicTagBlocksProvider =
    NotifierProvider<PublicTagBlocks, Map<TagCategory, PublicTagRule>>(
      PublicTagBlocks.new,
    );

class PublicTagBlocks extends Notifier<Map<TagCategory, PublicTagRule>> {
  static const _key = 'inspiration_public_blocks';

  @override
  Map<TagCategory, PublicTagRule> build() {
    try {
      final json = jsonDecode(ref.read(prefsStoreProvider).get(_key) ?? '{}');
      if (json is Map) {
        return {
          for (final cat in [TagCategory.character, TagCategory.artist])
            if (json.containsKey(cat.name))
              cat: PublicTagRule.fromJson(json[cat.name]),
        };
      }
    } catch (_) {}
    return {};
  }

  Future<void> save(Map<TagCategory, PublicTagRule> rules) async {
    state = {
      for (final e in rules.entries)
        if (e.value.active) e.key: e.value,
    };
    await ref
        .read(prefsStoreProvider)
        .write(
          key: _key,
          value: jsonEncode({
            for (final e in state.entries) e.key.name: e.value.toJson(),
          }),
        );
  }
}
