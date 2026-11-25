/// 规则预设库:导入过的预设,以及每个模型在用哪一份。
///
/// 每个模型各选一份:NAI4.5 和 NAI5 的写法差得多,一份预设可以只支持其中一个,
/// 也可以两个都支持。选默认规则就用包里内置的那份(见 default_rules.dart)。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../../l10n/l10n.dart';
import 'preset_rule.dart';
import 'rules_file.dart';

const _key = 'assistant_rule_presets';

/// 上一版的存法(每个模型一份无名规则)。读到就迁成预设,见 [RulesLibraryNotifier.build]。
const _legacyKey = 'assistant_rules';

enum RulesPresetKind { standard, semantic, semanticLite, custom }

/// 一份规则预设。
class RulesPreset {
  const RulesPreset({
    required this.id,
    required this.name,
    required this.author,
    required this.models,
    required this.rules,
    this.kind = RulesPresetKind.custom,
    this.localOnly = false,
  });

  final String id;
  final String name;

  /// 空 = 没署名。
  final String author;

  /// 支持的模型。至少一个。
  final Set<RulesFamily> models;

  final List<PresetRule> rules;

  final RulesPresetKind kind;
  // The persisted flag identifies the optional API supplement section.
  final bool localOnly;
  bool get isDefault => kind != RulesPresetKind.custom;

  String get settingsLabel => switch (kind) {
    RulesPresetKind.standard => l10nNow.presetGroupDefault,
    RulesPresetKind.semantic => l10nNow.semanticPromptGrouping,
    RulesPresetKind.semanticLite => l10nNow.semanticPromptGroupingLite,
    RulesPresetKind.custom => name,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    if (localOnly) 'localOnly': true,
    'name': name,
    'author': author,
    'models': [
      for (final m in RulesFamily.values)
        if (models.contains(m)) m.name,
    ],
    'rules': [for (final r in rules) r.toJson()],
  };

  static RulesPreset? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}'.trim();
    final name = '${j['name'] ?? ''}'.trim();
    final models = decodeModels(j['models']);
    final rules = [
      if (j['rules'] is List)
        for (final r in j['rules'] as List)
          if (PresetRule.fromJson(r) case final rule?)
            if (rule.name != kToolLayerName) rule,
    ];
    if (id.isEmpty || id.startsWith('default') || name.isEmpty) return null;
    // 一段都没有的也收:新建的预设从空的开始
    if (models.isEmpty) return null;
    return RulesPreset(
      id: id,
      name: name,
      author: '${j['author'] ?? ''}'.trim(),
      localOnly: j['localOnly'] == true,
      models: models,
      rules: rules,
    );
  }
}

/// 默认规则:每个模型一份,**不存规则内容** —— 内容在包里(见 default_rules.dart)。
/// 名称、作者、版本以内置那份的 meta 为准,这里的几个值只是占位。
RulesPreset defaultPresetOf(RulesFamily f) => RulesPreset(
  id: 'default-${f.name}',
  name: kDefaultRulesName,
  author: kDefaultRulesAuthor,
  models: {f},
  rules: const [],
  kind: RulesPresetKind.standard,
);

const kDefaultRulesName = 'Nyako';
const kDefaultRulesAuthor = '夏夜浮梦';
String defaultRulesVersionOf(RulesFamily f) =>
    f == RulesFamily.nai5 ? 'v5' : 'v4.5';

class RulesLibrary {
  const RulesLibrary({
    this.presets = const [],
    this.bundled = const [],
    this.active = const {},
    this.apiSupplements = const {},
    this.order = const [],
  });

  /// 可编辑的导入预设和用户副本。
  final List<RulesPreset> presets;

  /// 随应用分发的四份语义规则，正文从资源文件读取。
  final List<RulesPreset> bundled;

  /// 缺少键沿用默认预设，值为 null 表示用户关闭了这个模型的预设。
  final Map<RulesFamily, String?> active;
  final Map<RulesFamily, String> apiSupplements;

  /// 列表的显示顺序，包含内置预设的 ID。旧存档从两份内置预设开始。
  final List<String> order;

  List<RulesPreset> get all {
    final remaining = {
      for (final p in [
        ...RulesFamily.values.map(defaultPresetOf),
        ...bundled,
        ...presets,
      ])
        p.id: p,
    };
    return [for (final id in order) ?remaining.remove(id), ...remaining.values];
  }

  RulesLibrary copyWith({
    List<RulesPreset>? presets,
    Map<RulesFamily, String?>? active,
    Map<RulesFamily, String>? apiSupplements,
    List<String>? order,
  }) => RulesLibrary(
    presets: presets ?? this.presets,
    bundled: bundled,
    active: active ?? this.active,
    apiSupplements: apiSupplements ?? this.apiSupplements,
    order: order ?? this.order,
  );

  /// 这个模型在用的那一份。选的预设被删了、或者它不支持这个模型,都回落默认。
  RulesPreset? activeFor(RulesFamily f) {
    final id = active[f];
    if (id == null) return active.containsKey(f) ? null : defaultPresetOf(f);
    for (final p in bundled.followedBy(presets)) {
      if (p.id == id && !p.localOnly && p.models.contains(f)) return p;
    }
    return defaultPresetOf(f);
  }

  RulesPreset? supplementFor(RulesFamily f) => presets
      .where(
        (p) => p.id == apiSupplements[f] && p.localOnly && p.models.contains(f),
      )
      .firstOrNull;

  Set<RulesFamily> enabledFor(String id) => {
    for (final f in RulesFamily.values)
      if (activeFor(f)?.id == id || supplementFor(f)?.id == id) f,
  };

  /// 副本的名字:「原名 (副本)」,重名再往后加数字。
  String copyNameOf(String base) => unusedName('$base ${l10nNow.copySuffix}');

  String unusedName(String first) {
    final taken = {for (final p in all) p.name};
    var name = first;
    for (var n = 2; taken.contains(name); n++) {
      name = '$first $n';
    }
    return name;
  }

  /// 这个模型自定义过的规则;用默认规则时是 null。
  List<PresetRule>? customRulesFor(RulesFamily f) {
    final p = activeFor(f);
    if (p == null) return const [];
    return p.kind == RulesPresetKind.standard ? null : p.rules;
  }

  Map<String, dynamic> toJson() => {
    'presets': [for (final p in presets) p.toJson()],
    'active': {for (final e in active.entries) e.key.name: e.value},
    if (apiSupplements.isNotEmpty)
      'apiSupplements': {
        for (final e in apiSupplements.entries) e.key.name: e.value,
      },
    if (order.isNotEmpty) 'order': order,
    // An older client should not reinstall its editable starter presets.
    'semanticPresetsInstalled': true,
    if (bundled.isNotEmpty) 'bundledSemanticPresets': true,
  };

  static RulesLibrary fromJson(
    Object? j, {
    List<RulesPreset> bundled = const [],
  }) {
    if (j is! Map) return RulesLibrary(bundled: bundled);
    final presets = [
      if (j['presets'] is List)
        for (final p in j['presets'] as List) ?RulesPreset.fromJson(p),
    ];
    final active = <RulesFamily, String?>{};
    if (j['active'] is Map) {
      (j['active'] as Map).forEach((k, v) {
        final f = RulesFamily.values.where((f) => f.name == '$k').firstOrNull;
        if (f != null && (v == null || v is String && v.isNotEmpty)) {
          active[f] = v as String?;
        }
      });
    }
    final selectedSupplements = j['apiSupplements'];
    final order = j['order'];
    final library = RulesLibrary(
      presets: presets,
      bundled: bundled,
      active: active,
      apiSupplements: {
        if (selectedSupplements is Map)
          for (final f in RulesFamily.values)
            if (selectedSupplements[f.name] case final String id)
              if (presets.any(
                (p) => p.id == id && p.localOnly && p.models.contains(f),
              ))
                f: id,
      },
      order: order is List ? order.whereType<String>().toList() : const [],
    );
    return j['bundledSemanticPresets'] == true
        ? library
        : library._adoptBundledPresets();
  }

  RulesLibrary _adoptBundledPresets() {
    final aliases = <String, String>{};
    for (final imported in presets) {
      for (final original in bundled) {
        if (_matchesOriginal(imported, original)) {
          aliases[imported.id] = original.id;
          break;
        }
      }
    }
    if (aliases.isEmpty) return this;
    final oldOrder = [
      ...order,
      ...RulesFamily.values.map((f) => defaultPresetOf(f).id),
      ...presets.map((p) => p.id),
    ];
    return copyWith(
      presets: [
        for (final p in presets)
          if (!aliases.containsKey(p.id)) p,
      ],
      active: active.map((family, id) => MapEntry(family, aliases[id] ?? id)),
      order: {for (final id in oldOrder) aliases[id] ?? id}.toList(),
    );
  }

  static bool _matchesOriginal(RulesPreset p, RulesPreset original) {
    final family = original.models.single;
    if (p.localOnly ||
        p.models.length != 1 ||
        !p.models.contains(family) ||
        p.rules.length != original.rules.length) {
      return false;
    }
    // Both the distributed YAML files and the credited editions were imported
    // before these presets were bundled. Keep renamed or edited copies.
    final lite = original.kind == RulesPresetKind.semanticLite;
    final distributedName = lite
        ? 'Plana 规则预设 · ${rulesFamilyLabel(family)}（语义分块）'
        : original.name;
    final distributedAuthor = lite ? 'Plana' : '夏夜浮梦 · 语义分块增强';
    final credited = p.name == original.name && p.author == original.author;
    final distributed =
        p.name == distributedName && p.author == distributedAuthor;
    if (!credited && !distributed) {
      return false;
    }
    for (var i = 0; i < p.rules.length; i++) {
      final a = p.rules[i], b = original.rules[i];
      if (a.name != b.name ||
          a.when != b.when ||
          a.content != b.content ||
          a.enabled != b.enabled) {
        return false;
      }
    }
    return true;
  }
}

final rulesLibraryProvider =
    AsyncNotifierProvider<RulesLibraryNotifier, RulesLibrary>(
      RulesLibraryNotifier.new,
    );

class RulesLibraryNotifier extends AsyncNotifier<RulesLibrary> {
  var _idSeq = 0;

  @override
  Future<RulesLibrary> build() async {
    final bundled = await Future.wait([
      for (final kind in [
        RulesPresetKind.semantic,
        RulesPresetKind.semanticLite,
      ])
        for (final family in RulesFamily.values) _loadSemantic(kind, family),
    ]);
    return _readLibrary(bundled);
  }

  Future<RulesPreset> _loadSemantic(
    RulesPresetKind kind,
    RulesFamily family,
  ) async {
    final lite = kind == RulesPresetKind.semanticLite;
    final variant = lite ? 'semantic-lite' : 'semantic';
    final file = decodeRulesFile(
      await rootBundle.loadString(
        'assets/prompts/${lite ? 'plana' : 'nyako'}-$variant-${family.name}.yaml',
      ),
    );
    return RulesPreset(
      id: 'default-$variant-${family.name}',
      kind: kind,
      name: file.name,
      author: file.author,
      models: file.models,
      rules: file.rules,
    );
  }

  Future<RulesLibrary> _readLibrary(List<RulesPreset> bundled) async {
    final prefs = ref.read(prefsStoreProvider);
    try {
      final raw = await prefs.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        return RulesLibrary.fromJson(jsonDecode(raw), bundled: bundled);
      }
      // 上一版每个模型存一份无名规则:迁成「导入的 NAI 5 规则」这样的预设,并且照旧在用
      final legacy = await prefs.read(key: _legacyKey);
      if (legacy == null || legacy.isEmpty) {
        return RulesLibrary(bundled: bundled);
      }
      final j = jsonDecode(legacy);
      final presets = <RulesPreset>[];
      final active = <RulesFamily, String>{};
      for (final f in RulesFamily.values) {
        final rules = [
          if (j is Map && j[f.name] is List)
            for (final r in j[f.name] as List) ?PresetRule.fromJson(r),
        ];
        if (rules.isEmpty) continue;
        final id = 'legacy-${f.name}';
        presets.add(
          RulesPreset(
            id: id,
            name: '导入的 ${rulesFamilyLabel(f)} 规则',
            author: '',
            models: {f},
            rules: rules,
          ),
        );
        active[f] = id;
      }
      final lib = RulesLibrary(
        presets: presets,
        active: active,
        bundled: bundled,
      );
      await _write(lib);
      await prefs.delete(key: _legacyKey);
      return lib;
    } catch (_) {
      // 读坏了当没导入过:最坏是回到默认规则,不该让助手整个用不了
      return RulesLibrary(bundled: bundled);
    }
  }

  RulesLibrary get _lib => state.value ?? const RulesLibrary();

  String _newId() => 'r${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  RulesPreset newDraft(String name) => RulesPreset(
    id: _newId(),
    name: _lib.unusedName(name),
    author: '',
    models: Set.unmodifiable(RulesFamily.values),
    rules: const [],
  );

  /// 加一份预设,返回它的 id。
  Future<String> add({
    required String name,
    required String author,
    required Set<RulesFamily> models,
    required List<PresetRule> rules,
    RulesFamily? enableFor,
    bool localOnly = false,
  }) async {
    final id = _newId();
    await replace(
      id,
      name: name,
      author: author,
      models: models,
      rules: rules,
      insertIfMissing: true,
      localOnly: localOnly,
      enableFor: enableFor,
    );
    return id;
  }

  /// 改一份预设(规则页的全文编辑)。id 不变,在用它的模型照旧用它;
  /// 改完不再支持的模型回到默认规则。
  Future<void> replace(
    String id, {
    required String name,
    required String author,
    required Set<RulesFamily> models,
    required List<PresetRule> rules,
    bool insertIfMissing = false,
    bool? localOnly,
    RulesFamily? enableFor,
  }) async {
    if (id.startsWith('default')) return;
    final presets = [..._lib.presets];
    final index = presets.indexWhere((p) => p.id == id);
    if (index < 0 && !insertIfMissing) return;
    final edited = RulesPreset(
      id: id,
      name: name,
      author: author,
      models: Set.unmodifiable(models),
      rules: List.unmodifiable(rules),
      localOnly: localOnly ?? (index >= 0 && presets[index].localOnly),
    );
    if (index < 0) {
      presets.add(edited);
    } else {
      presets[index] = edited;
    }
    final active = {..._lib.active}
      ..removeWhere(
        (f, v) => v == id && (edited.localOnly || !models.contains(f)),
      );
    final apiSupplements = {..._lib.apiSupplements}
      ..removeWhere(
        (f, v) => v == id && (!edited.localOnly || !models.contains(f)),
      );
    if (enableFor != null && models.contains(enableFor)) {
      if (edited.localOnly) {
        apiSupplements[enableFor] = id;
      } else {
        active[enableFor] = id;
      }
    }
    await _save(
      _lib.copyWith(
        presets: presets,
        active: active,
        apiSupplements: apiSupplements,
      ),
    );
  }

  /// 按 ID 移动到目标卡的位置，拖动期间增删的其他卡片仍沿用最新存档。
  Future<void> move(String id, String targetId) async {
    final lib = _lib;
    final order = [for (final p in lib.all) p.id];
    final from = order.indexOf(id);
    final to = order.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    order.insert(to, order.removeAt(from));
    await _save(lib.copyWith(order: order));
  }

  /// 删一份预设。正在用它的模型回落默认规则。
  Future<void> remove(String id) async {
    if (!_lib.presets.any((p) => p.id == id)) return;
    await _save(
      _lib.copyWith(
        presets: [
          for (final p in _lib.presets)
            if (p.id != id) p,
        ],
        active: {..._lib.active}..removeWhere((_, v) => v == id),
        apiSupplements: {..._lib.apiSupplements}
          ..removeWhere((_, v) => v == id),
        order: [..._lib.order]..removeWhere((value) => value == id),
      ),
    );
  }

  /// A null selection explicitly disables this family's writing preset.
  Future<void> use(RulesFamily f, String? id, {bool supplement = false}) =>
      _select([f], id, supplement: supplement);

  Future<void> togglePreset(String id) async {
    final preset = _lib.all.where((p) => p.id == id).firstOrNull;
    if (preset == null) return;
    final enabled = _lib.enabledFor(id);
    await _select(
      enabled.isEmpty ? preset.models : enabled,
      enabled.isEmpty ? id : null,
      supplement: preset.localOnly,
    );
  }

  Future<void> _select(
    Iterable<RulesFamily> models,
    String? id, {
    required bool supplement,
  }) {
    if (supplement) {
      final selected = {..._lib.apiSupplements};
      for (final family in models) {
        if (id == null) {
          selected.remove(family);
        } else if (_lib.presets.any(
          (p) => p.id == id && p.localOnly && p.models.contains(family),
        )) {
          selected[family] = id;
        }
      }
      return _save(_lib.copyWith(apiSupplements: selected));
    }
    if (_lib.presets.any((p) => p.id == id && p.localOnly)) {
      return Future.value();
    }
    final active = {..._lib.active};
    for (final f in models) {
      if (id == defaultPresetOf(f).id) {
        active.remove(f);
      } else {
        active[f] = id;
      }
    }
    return _save(_lib.copyWith(active: active));
  }

  Future<void> _save(RulesLibrary next) async {
    state = AsyncData(next);
    await _write(next);
  }

  Future<void> _write(RulesLibrary lib) => ref
      .read(prefsStoreProvider)
      .write(key: _key, value: jsonEncode(lib.toJson()));
}
