import '../ui/tag_category_icons.dart';

/// A display label supplied by the model, separate from the prompt text.
String assistantSectionName(Object? value) {
  if (value is! String) return '';
  final name = value.trim();
  return name.length <= 64 && !RegExp(r'[\x00-\x1f<>]').hasMatch(name)
      ? name
      : '';
}

/// A block annotates a continuous piece of one prompt. The prompt itself is
/// always the source used for generation, copying and conversation replay.
enum PromptBlockKind {
  character('角色', 'character', '☺'),
  scene('场景', 'scene', '☀'),
  style('画风', 'artist-style', '✎'),
  other('其它', 'other', '◇');

  const PromptBlockKind(this.label, this.libraryId, this.glyph);
  final String label, libraryId, glyph;
}

class PromptBlock {
  const PromptBlock({
    required this.kind,
    required this.name,
    required this.text,
    required this.start,
    this.icon,
    this.character = -1,
    this.negative = false,
  });
  final PromptBlockKind kind;
  final String name, text;
  final String? icon;
  final int start, character;
  final bool negative;

  String get title => '$name · ${kind.label}';
  String get foldTitle => '${kind.glyph} $title';

  PromptBlock _withLabel(String name, String? icon) => PromptBlock(
    kind: kind,
    name: name,
    icon: icon,
    text: text,
    start: start,
    character: character,
    negative: negative,
  );

  /// Pair only one positive and one negative with the same owner and label.
  PromptBlock? counterpartIn(Iterable<PromptBlock> blocks) {
    final group = blocks.where(
      (b) => b.character == character && b.kind == kind && b.name == name,
    );
    if (group.where((b) => b.negative == negative).singleOrNull != this) {
      return null;
    }
    return group.where((b) => b.negative != negative).singleOrNull;
  }

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'icon': ?icon,
    'name': name,
    'text': text,
    'start': start,
    if (character >= 0) 'character': character,
    if (negative) 'negative': true,
  };

  static List<PromptBlock> decode(Object? data) {
    final blocks = <PromptBlock>[];
    if (data is! List) return blocks;
    for (final item in data) {
      if (item case {
        'kind': String k,
        'name': String n,
        'text': String t,
        'start': int s,
      }) {
        final kind = PromptBlockKind.values
            .where((x) => x.name == k)
            .firstOrNull;
        final index = item['character'] ?? -1;
        if (kind == null ||
            !_validName(n) ||
            t.isEmpty ||
            s < 0 ||
            index is! int ||
            index < -1) {
          continue;
        }
        blocks.add(
          PromptBlock(
            kind: kind,
            name: n,
            icon: canonicalTagIconKey(item['icon']),
            text: t,
            start: s,
            character: index,
            negative: item['negative'] == true,
          ),
        );
      }
    }
    return blocks;
  }

  static bool _validName(String value) =>
      value.trim().isNotEmpty &&
      value.length <= 64 &&
      !RegExp(r'[\x00-\x1f<>]').hasMatch(value);

  /// Recover exact library spans and explicitly owned character fields.
  static List<PromptBlock> fromKnownParts(
    Map<String, dynamic> draw,
    Map<String, Map<String, String>> resources, {
    bool recoverSplitLines = false,
  }) {
    final blocks = <PromptBlock>[];
    final positive = draw['positive'] is String
        ? draw['positive'] as String
        : '';
    final leftEdge = RegExp(r'(?:^|[,，\n])\s*$');
    final rightEdge = RegExp(r'^\s*(?:$|[,，\n])');
    for (final (key, kind) in [
      ('artist', PromptBlockKind.style),
      ('oc', PromptBlockKind.character),
    ]) {
      for (final e in (resources[key] ?? const <String, String>{}).entries) {
        final body = e.value.trim();
        if (body.isEmpty || !_validName(e.key)) continue;
        final at = positive.indexOf(body);
        if (at < 0 ||
            positive.indexOf(body, at + 1) >= 0 ||
            !leftEdge.hasMatch(positive.substring(0, at)) ||
            !rightEdge.hasMatch(positive.substring(at + body.length))) {
          continue;
        }
        blocks.add(
          PromptBlock(
            kind: kind,
            name: e.key,
            icon: kind == PromptBlockKind.style
                ? 'Brush'
                : _matchingIcon(_words(body), _characterIcons),
            text: body,
            start: at,
          ),
        );
      }
    }
    blocks.sort((a, b) {
      final order = a.start.compareTo(b.start);
      return order != 0 ? order : b.text.length.compareTo(a.text.length);
    });
    var end = 0;
    final result = <PromptBlock>[];
    for (final block in blocks) {
      if (block.start < end) continue;
      result.add(block);
      end = block.start + block.text.length;
    }
    final chars = draw['characters'];
    if (recoverSplitLines) {
      result.addAll(
        _unlabelledLines(
          positive,
          result,
          hasCharacterFields: chars is List && chars.isNotEmpty,
        ).toList(),
      );
      result.sort((a, b) => a.start.compareTo(b.start));
    }
    if (chars is! List) return result;
    for (final (index, c) in chars.indexed) {
      if (c is! Map) continue;
      final name = c['name'];
      if (name is! String || !_validName(name)) continue;
      final positive = c['positive'];
      final icon = positive is String
          ? _matchingIcon(_words(positive), _characterIcons)
          : null;
      for (final field in ['positive', 'negative']) {
        final source = c[field];
        if (source is! String) continue;
        final text = source.trim();
        if (text.isEmpty) continue;
        result.add(
          PromptBlock(
            kind: PromptBlockKind.character,
            name: name,
            icon: icon,
            text: text,
            start: source.indexOf(text),
            character: index,
            negative: field == 'negative',
          ),
        );
      }
    }
    return result;
  }

  static final _identity = RegExp(
    r'(?:^|[,，])\s*(?:-?\d+(?:\.\d+)?::)?([\w][\w -]*?)(?:[ _]+\([^(),]+\))+(?:::)?\s*(?=[,，]|$)',
    caseSensitive: false,
  );
  static String _words(String text) => text.toLowerCase().replaceAll('_', ' ');

  // More specific subjects get the icon when a line has several cues.
  static final _characterIcons = {
    'Shirt': RegExp(
      r'\b(?:swimsuits?|swimwear|bikinis?|maids?|dress(?:es)?|uniforms?)\b',
    ),
    'PersonStanding': RegExp(r'\b(?:standing|sitting|kneeling)\b'),
  };
  static final _sceneIcons = {
    'Moon': RegExp(r'\b(?:moonlight|moonlit|moon)\b'),
    'Droplet': RegExp(
      r'\b(?:beach(?:es|side)?|shoreline|seashore|swimming pool|poolside|rain(?:ing|y|fall|drops?)?)\b',
    ),
    'Sun': RegExp(r'\b(?:sunlight|sunlit|sunshine|sunny|daylight)\b'),
  };
  static String? _matchingIcon(String words, Map<String, RegExp> rules) {
    for (final rule in rules.entries) {
      if (rule.value.hasMatch(words)) return rule.key;
    }
    return null;
  }

  static final _figure = RegExp(
    r'\b(arms crossed|smil(?:e|ing)|expression|wink(?:ing)?|hair|eyes|wearing)\b',
  );
  static final _setting = RegExp(
    r'\b(lighting|backlight(?:ing)?|background|indoors|outdoors|interior|courtyard|room|classroom|cafe|garden|low angle|high angle|from below|from above|(?:wide|medium|long) shot|close[- ]up|depth of field)\b',
  );
  static final _transparent = RegExp(
    r'^(?:transparent background|no background)(?:,\s*(?:alpha channel|transparent))?$',
  );
  static final _personCount = RegExp(r'^\s*1(?:girl|boy)(?:\s*[,，]|$)');
  static final _lineBody = RegExp(r'[^ \t\r\n][^\r\n]*');
  static final _trailingComma = RegExp(r'[,，\s]+$');
  static final _labelSeparator = RegExp(r'[·・•:：]');

  /// A missing label array sometimes accompanies an otherwise correctly split
  /// prompt. Keep the model's boundaries and leave ambiguous lines as plain tags.
  static Iterable<PromptBlock> _unlabelledLines(
    String text,
    List<PromptBlock> known, {
    required bool hasCharacterFields,
  }) sync* {
    final lines = _lineBody.allMatches(text).toList();
    if (lines.length < 2 && !hasCharacterFields) return;
    for (final line in lines) {
      final body = line[0]!.replaceFirst(_trailingComma, '');
      if (body.isEmpty ||
          known.any(
            (b) =>
                b.start < line.start + body.length &&
                line.start < b.start + b.text.length,
          )) {
        continue;
      }
      final words = _words(body);
      final identity = _identity.firstMatch(body);
      final characterIcon = _matchingIcon(words, _characterIcons);
      final sceneIcon = _matchingIcon(words, _sceneIcons);
      final figure = characterIcon != null || _figure.hasMatch(words);
      final setting = sceneIcon != null || _setting.hasMatch(words);
      final (kind, name, icon) = switch ((identity, figure, setting)) {
        _ when _transparent.hasMatch(words) => (
          PromptBlockKind.other,
          '透明背景',
          null,
        ),
        (_, _, true) when hasCharacterFields => (
          PromptBlockKind.scene,
          '环境与构图',
          sceneIcon,
        ),
        _ when hasCharacterFields => (null, '', null),
        (final m?, _, _) => (
          PromptBlockKind.character,
          m[1]!.replaceAll('_', ' '),
          characterIcon,
        ),
        (null, true, false) => (PromptBlockKind.character, '人物', characterIcon),
        (null, true, true) when _personCount.hasMatch(words) => (
          PromptBlockKind.character,
          '人物',
          characterIcon,
        ),
        (null, false, true) => (PromptBlockKind.scene, '环境与构图', sceneIcon),
        _ => (null, '', null),
      };
      if (kind != null && _validName(name)) {
        yield PromptBlock(
          kind: kind,
          name: name,
          icon: icon,
          text: body,
          start: line.start,
        );
      }
    }
  }

  /// Maps compact line labels to exact text after library placeholders expand.
  /// One resource can expand into several lines. If whole-field deduplication
  /// removed a repeated resource, accept only lines whose contents still match.
  static List<PromptBlock> fromDraw(
    Map<String, dynamic>? source,
    Map<String, dynamic>? expanded,
    String Function(String) expandLine, {
    Map<String, Map<String, String>>? recoverWith,
  }) {
    final output = <PromptBlock>[];
    if (source == null || expanded == null) return output;
    List<PromptBlock>? recovered;
    void readField(Map original, Map resolved, int character, String field) {
      final meta = original['blocks'];
      final labels = meta is Map ? meta[field] : null;
      final raw = original[field], finalText = resolved[field];
      if (raw is! String || finalText is! String) return;
      final lines = raw.split('\n');
      if (labels is! List ||
          labels.length != lines.where((l) => l.trim().isNotEmpty).length) {
        if (recoverWith != null && raw.trim().isNotEmpty) {
          recovered ??= fromKnownParts(
            expanded,
            recoverWith,
            recoverSplitLines: true,
          );
          final known = recovered!.where(
            (b) =>
                b.character == character && b.negative == (field == 'negative'),
          );
          // A character's unlabelled exclusion field has a definite owner even
          // when its single positive block uses a more descriptive nickname.
          final role = character >= 0 && field == 'negative'
              ? output
                    .where(
                      (b) =>
                          b.character == character &&
                          !b.negative &&
                          b.kind == PromptBlockKind.character,
                    )
                    .singleOrNull
              : null;
          for (final block in known) {
            output.add(
              role == null || block.kind != PromptBlockKind.character
                  ? block
                  : block._withLabel(role.name, role.icon),
            );
          }
        }
        return;
      }
      final projected = lines.map(expandLine).toList();
      final actual = projected.join('\n') == finalText
          ? projected
          : finalText.split('\n');
      if (actual.length != projected.length) return;
      var offset = 0, labelIndex = 0;
      for (var i = 0; i < lines.length; i++) {
        final lineStart = offset;
        offset += actual[i].length + 1;
        if (lines[i].trim().isEmpty) continue;
        final label = labels[labelIndex++];
        if (label is! String || actual[i] != projected[i]) continue;
        final split = label.indexOf(_labelSeparator);
        if (split < 1) continue;
        final type = label.substring(0, split).trim();
        final kind = PromptBlockKind.values
            .where((x) => x.label == (type == '其他' ? '其它' : type))
            .firstOrNull;
        var name = label.substring(split + 1).trim();
        // Existing names can contain dots. Only a registered final key is metadata.
        final suffix = name.lastIndexOf(_labelSeparator);
        final icon = suffix > 0
            ? canonicalTagIconKey(name.substring(suffix + 1))
            : null;
        if (icon != null) name = name.substring(0, suffix).trim();
        final trimmed = actual[i].trimLeft();
        final body = trimmed.replaceFirst(_trailingComma, '');
        if (kind == null || !_validName(name) || body.isEmpty) continue;
        output.add(
          PromptBlock(
            kind: kind,
            name: name,
            text: body,
            icon: icon,
            start: lineStart + actual[i].length - trimmed.length,
            character: character,
            negative: field == 'negative',
          ),
        );
      }
    }

    void read(Map a, Map b, int character) {
      readField(a, b, character, 'positive');
      readField(a, b, character, 'negative');
    }

    read(source, expanded, -1);
    final original = source['characters'], resolved = expanded['characters'];
    if (original is List &&
        resolved is List &&
        original.length == resolved.length) {
      for (var i = 0; i < original.length; i++) {
        if (original[i] is Map && resolved[i] is Map) {
          read(original[i], resolved[i], i);
        }
      }
    }
    // If only the negative side supplied a label, its icon takes priority
    // over the positive side's keyword guess in the shared chip.
    if (recovered case final known?) {
      final inferred = known.toSet();
      for (var i = 0; i < output.length; i++) {
        final block = output[i];
        if (block.negative || !inferred.contains(block)) continue;
        final partner = block.counterpartIn(output);
        if (partner?.icon case final icon? when icon != block.icon) {
          output[i] = block._withLabel(block.name, icon);
        }
      }
    }
    return output;
  }
}
