import '../../inspiration/public_tag_blocks.dart';
import '../../inspiration/external/oc_sources.dart';
import '../../inspiration/tag_models.dart';
import '../assistant_settings.dart' show LibrarySelection;
import '../../../core/util/name_query.dart';

/// One category of references for a turn, including local copies saved from
/// the public library. Independent local creations keep their own identity.
class AssistantReferences {
  AssistantReferences(
    TagCategory category,
    Iterable<TagEntry> library,
    List<TagEntry> catalog,
    this.rule, {
    List<String> order = const [
      LibrarySelection.local,
      LibrarySelection.public,
    ],
    Map<String, List<TagEntry>> external = const {},
    this.strictScope = false,
  }) {
    final byId = {for (final e in catalog) e.publicId ?? e.id: e};
    final byName = {for (final e in catalog) e.name: e};
    for (final e in library.where((e) => e.category == category)) {
      final linked = e.publicId != null || e.origin != TagOrigin.local;
      final original = e.publicId != null ? byId[e.publicId] : byName[e.name];
      if (linked && rule.hides(e, publicSource: original)) continue;
      local.add(e);
    }
    final claimed = <String>{};
    for (final id in order) {
      final bucket = switch (id) {
        LibrarySelection.local => local,
        LibrarySelection.public => catalog.where((e) => !rule.hides(e)),
        _ => external[id] ?? const <TagEntry>[],
      };
      final names = <String>{};
      for (final entry in bucket) {
        final name = normalizeName(entry.name);
        final key = normalizeName(entry.publicId ?? entry.id);
        if (claimed.contains(name) || claimed.contains(key)) continue;
        final aliases = entry.aliases
            .where((a) => !claimed.contains(normalizeName(a)))
            .toList();
        entries.add(
          aliases.length == entry.aliases.length
              ? entry
              : entry.copyWith(aliases: aliases),
        );
        if (entry.positive.trim().isNotEmpty) {
          names.addAll(
            [
              name,
              key,
              ...aliases.map(normalizeName),
            ].where((n) => n.isNotEmpty),
          );
        }
      }
      claimed.addAll(names);
    }
  }
  final bool strictScope;
  final PublicTagRule rule;
  final local = <TagEntry>[];
  final entries = <TagEntry>[];

  late final _known = {
    for (final e in entries)
      for (final key in [e.publicId ?? e.id, e.name, ...e.aliases])
        (key.trim().toLowerCase(), e.positive.trim()),
  };
  bool allowsResource(String name, String value) =>
      (!strictScope && !rule.active) || containsResource(name, value);
  bool containsResource(String name, String value) =>
      _known.contains((name.trim().toLowerCase(), value.trim()));

  List<Map<String, dynamic>> wire({required bool includePublic}) => [
    for (final e in includePublic ? entries : local)
      if (e.positive.trim().isNotEmpty)
        if (e.category == TagCategory.artist)
          {
            'id': e.publicId ?? e.name,
            'name': e.name,
            'prompt': e.positive,
            if (e.negative.trim().isNotEmpty) 'negative': e.negative,
          }
        else
          {
            'en_name': e.publicId ?? e.id,
            'zh_name': e.name,
            'zh_aliases': e.aliases,
            'tag_group': e.positive,
          },
  ];
}

/// A null query requests the full text snapshot for older backends that run
/// their own lookup. On-device tools resolve only the matching characters.
Future<Map<String, List<TagEntry>>> externalOcReferences(
  OcRepository repository,
  Iterable<OcSource> sources, {
  String? query,
  bool search = false,
}) async {
  final text = query == null ? null : NameQuery(query);
  final result = <String, List<TagEntry>>{};
  for (final source in sources) {
    try {
      result[source.id] = await repository.referenceEntries(
        source,
        matches: text == null
            ? null
            : (c) {
                if (text.words.isEmpty) return false;
                if (query!.contains(c.entryPrefix(source.id))) return true;
                return c.forms.any((f) {
                  final names = c.formNames(f);
                  return search
                      ? text.score(names) > 0
                      : names.any((name) => text.mentionLength(name) > 0);
                });
              },
      );
    } catch (_) {
      throw OcAccessError('无法读取资料库「${source.label}」，请检查连接或在助手设置中取消勾选。');
    }
  }
  return result;
}
