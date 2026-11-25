/// 「我的库」:灵感页里用户自己的画风库 / OC 库。查画风、查 OC 两个工具与它们的预取都从这里取,
/// 库的内容只在本机用。
library;

import 'dart:math';

import '../../../core/util/name_query.dart';
import '../runtime/placeholders.dart' show artistPlaceholder;

export '../../../core/util/name_query.dart' show normalizeName;

/// 按码点数长度,名字里带表情时和 UTF-16 长度不一样。
int nameLength(String s) => s.runes.length;

/// 按 [key] 从大到小排,一样大的保持原来的先后(Dart 的 sort 不保证稳定)。
List<T> largestFirst<T>(List<T> items, int Function(T) key) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final c = key(b.$2).compareTo(key(a.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

// ---- 库条目 ----

/// 一条画师串。
class LibArtist {
  const LibArtist({
    required this.id,
    required this.name,
    required this.prompt,
    this.negative = '',
  });

  final String id;
  final String name;

  final String negative;

  /// 完整画师串。
  final String prompt;

  /// 块里、占位符里用的名字:有编号用编号。
  String get label => id.isNotEmpty ? id : name;
}

/// 一个 OC。
class LibOc {
  const LibOc({
    required this.enName,
    required this.zhName,
    required this.aliases,
    required this.tagGroup,
  });

  final String enName;
  final String zhName;
  final List<String> aliases;
  final String tagGroup;

  /// 给模型看的名字:有中文名用中文名。
  String get label => zhName.isNotEmpty ? zhName : enName;
}

String _field(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v != null && '$v'.isNotEmpty) return '$v'.trim();
  }
  return '';
}

/// 控制器拼好的画风库(`{'id','name','prompt'}`)→ 条目。没内容的丢掉、重复的去掉。
List<LibArtist> libArtistsOf(List<Map<String, dynamic>> raw) {
  final seen = <String>{};
  final out = <LibArtist>[];
  for (final m in raw) {
    final id = _field(m, const ['id', 'name']);
    final name = _field(m, const ['name']);
    final prompt = _field(m, const ['prompt', 'artist_string']);
    if ((id.isEmpty && name.isEmpty) || prompt.isEmpty) continue;
    final a = LibArtist(
      id: id.isNotEmpty ? id : name,
      name: name.isNotEmpty ? name : id,
      prompt: prompt,
      negative: _field(m, const ['negative']),
    );
    if (seen.add('${a.id.toUpperCase()}|${a.name.toUpperCase()}|${a.prompt}')) {
      out.add(a);
    }
  }
  return out;
}

/// 控制器拼好的 OC 库(`{'en_name','zh_name','zh_aliases','tag_group'}`)→ 条目。
List<LibOc> libOcsOf(List<Map<String, dynamic>> raw) {
  final seen = <String>{};
  final out = <LibOc>[];
  for (final m in raw) {
    final name = _field(m, const ['name', 'zh_name', 'id']);
    final en = _field(m, const ['en_name', 'id']);
    final zh = _field(m, const ['zh_name', 'zhName']);
    final tags = _field(m, const ['tag_group', 'positive']);
    final enName = en.isNotEmpty ? en : name;
    final zhName = zh.isNotEmpty ? zh : name;
    if ((enName.isEmpty && zhName.isEmpty) || tags.isEmpty) continue;
    final rawAliases = m['zh_aliases'] ?? m['aliases'];
    final oc = LibOc(
      enName: enName,
      zhName: zhName,
      aliases: [
        if (rawAliases is List)
          for (final a in rawAliases)
            if (a != null && '$a'.trim().isNotEmpty) '$a',
      ],
      tagGroup: tags,
    );
    if (seen.add('${oc.enName.toLowerCase()}|${oc.zhName}|${oc.tagGroup}')) {
      out.add(oc);
    }
  }
  return out;
}

// ---- 字面匹配(预取用) ----

final _artistIdRe = RegExp(r'(?<![A-Za-z])([A-Za-z])(\d+)');

/// 编号形状的名字(A1、b12)。
final _artistIdShape = RegExp(r'^[A-Za-z]\d+$');

/// 一块最多几条。
const kBlockMax = 10;

/// 这句话点到的画师串 → [(块里的名字, 完整串)],按块里的顺序。
///
/// 两条路:编号(A1 / b12)、名字(规范化后至少 2 个字,越长越靠前)。编号形状的名字
/// 只走编号那条,「A12」里不会再撞出 A1。最多 10 条。
List<(String, String)> matchArtists(String text, List<LibArtist> artists) {
  final out = <(String, String)>[];
  final seen = <String>{};
  for (final m in _artistIdRe.allMatches(text)) {
    final id = '${m[1]!.toUpperCase()}${m[2]}';
    for (final a in artists) {
      if (a.id.toUpperCase() != id && a.name.toUpperCase() != id) continue;
      if (!seen.add(a.label.toUpperCase())) continue;
      out.add((a.label, a.prompt));
      break;
    }
  }
  final textNorm = normalizeName(text);
  final byName = <(int, String, String)>[];
  for (final a in artists) {
    if (a.name.isEmpty ||
        _artistIdShape.hasMatch(a.name.trim()) ||
        seen.contains(a.label.toUpperCase())) {
      continue;
    }
    final n = normalizeName(a.name);
    if (nameLength(n) < 2 || !textNorm.contains(n)) continue;
    seen.add(a.label.toUpperCase());
    byName.add((nameLength(n), a.name, a.prompt));
  }
  for (final (_, name, prompt) in largestFirst(byName, (e) => e.$1)) {
    out.add((name, prompt));
  }
  return out.take(kBlockMax).toList();
}

/// Keep each form's canonical label in the resource block and placeholder map.
List<(String, String)> matchOcs(String text, List<LibOc> ocs) {
  final query = NameQuery(text);
  final hits =
      <
        ({String label, String tags, int length, String group, bool specific})
      >[];
  final specificGroups = <String>{};
  for (final oc in ocs) {
    final bare = oc.enName.toLowerCase().startsWith('oc_')
        ? oc.enName.substring(3)
        : oc.enName;
    final names = {
      for (final n in [oc.zhName, ...oc.aliases, bare])
        if (n.trim().isNotEmpty) n.trim(),
    };
    if (!oc.enName.startsWith('ext:')) {
      final matched = [
        for (final name in names)
          if (normalizeName(name) case final key
              when key.isNotEmpty && query.compact.contains(key))
            name,
      ];
      if (matched.isNotEmpty) {
        hits.add((
          label: oc.label,
          tags: oc.tagGroup,
          length: matched.map(nameLength).reduce(max),
          group: '',
          specific: false,
        ));
      }
      continue;
    }

    final length = names.map(query.mentionLength).fold(0, max);
    if (length == 0) continue;
    // Forms from one external character share an ID prefix and the first alias.
    final group = oc.enName.substring(0, oc.enName.lastIndexOf(':'));
    final base = oc.aliases.firstOrNull ?? oc.label;
    final specific =
        length > nameLength(normalizeName(base)) ||
        (query.words.length > 1 &&
            query.score(names) > 0 &&
            query.score([base]) == 0);
    if (specific) specificGroups.add(group);
    hits.add((
      label: oc.label,
      tags: oc.tagGroup,
      length: length,
      group: group,
      specific: specific,
    ));
  }
  return [
    for (final hit
        in largestFirst(hits, (h) => h.length)
            .where((h) => h.specific || !specificGroups.contains(h.group))
            .take(kBlockMax))
      (hit.label, hit.tags),
  ];
}

// ---- 查询(工具用) ----

/// 查画风返回的一条。
Map<String, dynamic> artistToolEntry(LibArtist a) => {
  'id': a.id,
  'name': a.name,
  'prompt': a.prompt,
  if (a.negative.isNotEmpty) 'negative': a.negative,
  'placeholder': artistPlaceholder(a.label),
};

List<String> _stringList(Object? v) => switch (v) {
  final List l => [
    for (final e in l)
      if (e != null && '$e'.trim().isNotEmpty) '$e'.trim(),
  ],
  final String s when s.trim().isNotEmpty => [s.trim()],
  _ => const [],
};

/// 工具参数里的整数,模型写成字符串也认。
int intArg(Object? v, int fallback) => switch (v) {
  final num n => n.toInt(),
  final String s => int.tryParse(s.trim()) ?? fallback,
  _ => fallback,
};

/// 按编号 / 名字列表,或者按关键词(名字和画师串里找)查画风库。
List<LibArtist> searchArtists(
  List<LibArtist> artists,
  Map<String, dynamic> args,
) {
  final ids = {
    for (final i in _stringList(args['artist_ids'])) i.toUpperCase(),
  };
  if (ids.isNotEmpty) {
    return [
      for (final a in artists)
        if (ids.contains(a.id.toUpperCase()) ||
            ids.contains(a.name.toUpperCase()))
          a,
    ];
  }
  final k = '${args['keyword'] ?? ''}'.trim().toLowerCase();
  if (k.isEmpty) return const [];
  return [
    for (final a in artists)
      if ('${a.name} ${a.prompt}'.toLowerCase().contains(k)) a,
  ];
}

/// 按名字 / 别名查 OC 库。
List<LibOc> searchOcs(List<LibOc> ocs, String query) {
  final q = NameQuery(query);
  if (q.words.isEmpty) return const [];
  final hits = <(int, LibOc)>[];
  for (final oc in ocs) {
    final primary = q.score([oc.label, oc.enName]);
    final score = q.score([oc.label, ...oc.aliases, oc.enName]);
    if (score > 0) hits.add((score * 5 + primary, oc));
  }
  return [for (final hit in largestFirst(hits, (h) => h.$1)) hit.$2];
}
