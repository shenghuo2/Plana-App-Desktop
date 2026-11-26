import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/util/name_query.dart';
import '../tag_models.dart';

String ocKey(String text) => sha256.convert(utf8.encode(text)).toString();
String ocCopyPrefix(String entryId) => 'oc_copy_${ocKey(entryId)}_';

typedef OcJson = Map<String, dynamic>;

String _str(dynamic value) => value is String ? value.trim() : '';
List<String> _strings(dynamic value) => value is List
    ? value
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList()
    : [_str(value)].where((s) => s.isNotEmpty).toList();

class OcForm {
  const OcForm(
    this.id,
    this.name,
    this.positive,
    this.negative,
    this.images,
    this.tags,
  );
  final String id, name, negative;
  // The visitor API stores the prompt in a separate record.
  final String? positive;
  final List<String> images, tags;

  factory OcForm.parse(OcJson row, String fallback, {bool atlas = false}) {
    final id = _str(row['id']);
    return OcForm(
      id.isEmpty ? fallback : id,
      _str(row['name']),
      atlas && row['hasPrompt'] != false
          ? null
          : _str(row['prompt'] ?? row['positive']),
      _str(row['negativePrompt'] ?? row['negative']),
      _strings(row['images'] ?? row['previews'] ?? row['image']),
      _strings(row['tags']),
    );
  }
}

int _timestamp(OcJson row) {
  for (final key in ['updatedAt', 'updated_at', 'createdAt', 'created_at']) {
    final raw = row[key];
    final n = raw is num ? raw.toInt() : int.tryParse(_str(raw));
    if (n != null && n > 0) return n < 100000000000 ? n * 1000 : n;
    final date = DateTime.tryParse(_str(raw));
    if (date != null) return date.millisecondsSinceEpoch;
  }
  return 0;
}

class OcCharacter {
  const OcCharacter(
    this.id,
    this.name,
    this.author,
    this.aliases,
    this.tags,
    this.forms, {
    this.updatedAt = 0,
  });
  final String id, name, author;
  final List<String> aliases, tags;
  final List<OcForm> forms;
  final int updatedAt;

  String formLabel(OcForm form) {
    if (form.name.isEmpty) return name;
    return normalizeName(form.name).startsWith(normalizeName(name))
        ? form.name
        : '$name · ${form.name}';
  }

  Iterable<String> formNames(OcForm form) => [
    formLabel(form),
    name,
    ...aliases,
  ];

  bool matchesForm(
    NameQuery query,
    OcForm form, {
    Iterable<String> localTags = const [],
  }) =>
      query.words.isEmpty ||
      query.score([
            ...formNames(form),
            author,
            ...tags,
            ...form.tags,
            ...localTags,
            form.positive ?? '',
          ]) >
          0;

  bool matchesSearch(String query) => matchesQuery(NameQuery(query));
  bool matchesQuery(NameQuery query) => forms.any((f) => matchesForm(query, f));

  String entryPrefix(String sourceId) => 'ext:$sourceId:${ocKey(id)}:';
}

class OcCatalog {
  OcCatalog(this.name, this.characters, this.atlas, this.release);
  final String name, release;
  final List<OcCharacter> characters;
  final bool atlas;
  late final List<String> tags = {
    for (final c in characters) ...[
      ...c.tags,
      for (final f in c.forms) ...f.tags,
    ],
  }.toList()..sort();

  factory OcCatalog.parse(Object? raw) {
    final root = raw is OcJson ? raw : <String, dynamic>{'characters': raw};
    final chars = root['characters'] ?? root['entries'];
    if (chars is! List) {
      throw const FormatException('需要包含 characters 或 entries 的 JSON 资料库');
    }
    final atlas =
        root['releaseId'] is String &&
        root['entries'] is List &&
        root['characters'] is List;
    final index = {
      if (atlas)
        for (final f in (root['entries'] as List).whereType<OcJson>())
          _str(f['id']): f,
    };
    final result = <OcCharacter>[];
    final usedIds = <String>{};
    for (final row in chars.whereType<OcJson>()) {
      final name = _str(row['name']);
      if (name.isEmpty) continue;
      final owner = _str(row['owner'] ?? row['author'] ?? row['createdBy']);
      final identity = _str(row['id']);
      final id = identity.isNotEmpty ? identity : '$owner/$name';
      if (!usedIds.add(id)) throw const FormatException('同名角色需要不同的 id');
      final forms = <OcForm>[];
      if (atlas) {
        for (final fid in _strings(row['formIds'])) {
          final form = index[fid];
          if (form == null) throw const FormatException('形态索引不完整');
          forms.add(OcForm.parse(form, fid, atlas: true));
        }
      } else {
        final rows = row['forms'] is List ? row['forms'] as List : [row];
        for (final (i, form) in rows.whereType<OcJson>().indexed) {
          forms.add(OcForm.parse(form, '$i'));
        }
      }
      if (forms.isNotEmpty) {
        result.add(
          OcCharacter(
            id,
            name,
            owner,
            _strings(row['aliases']),
            _strings(row['tags']),
            forms,
            updatedAt: _timestamp(row),
          ),
        );
      }
    }
    if (chars.isNotEmpty && result.isEmpty) {
      throw const FormatException('未找到带名称和形态的角色');
    }
    return OcCatalog(
      _str(root['name'] ?? root['title']),
      result,
      atlas,
      _str(root['releaseId']),
    );
  }
}

typedef OcFormData = ({String positive, String negative, List<String> images});

List<TagEntry> groupOcForms(
  String sourceId,
  OcCharacter character,
  List<OcFormData> details,
) {
  final groups = <(String, String, String), List<int>>{};
  for (var i = 0; i < details.length; i++) {
    final f = details[i];
    // An absent prompt does not establish that two forms are the same.
    final key = (
      f.positive.trim(),
      f.negative.trim(),
      f.positive.trim().isEmpty && f.negative.trim().isEmpty
          ? character.forms[i].id
          : '',
    );
    (groups[key] ??= []).add(i);
  }
  return [
    for (final g in groups.entries)
      TagEntry(
        id: '${character.entryPrefix(sourceId)}${ocKey(g.key.$1.isEmpty && g.key.$2.isEmpty ? jsonEncode(['form', g.key.$3]) : jsonEncode([g.key.$1, g.key.$2]))}',
        category: TagCategory.character,
        name: groups.length > 1
            ? character.formLabel(character.forms[g.value.first])
            : character.name,
        createdBy: character.author,
        aliases: {
          character.name,
          ...character.aliases,
          for (final i in g.value) character.formLabel(character.forms[i]),
        }.toList(),
        createdAt: character.updatedAt,
        tags: {
          ...character.tags,
          for (final i in g.value) ...character.forms[i].tags,
        }.toList(),
        positive: g.key.$1,
        negative: g.key.$2,
        previews: {for (final i in g.value) ...details[i].images}.toList(),
      ),
  ];
}
