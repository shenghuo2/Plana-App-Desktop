import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';

import '../../core/store/atomic_file.dart';
import 'tag_models.dart';

const _examples = [
  (
    file: 'coastal-station',
    scene: '海边',
    prompt: '暖光',
    shape: '横图',
    sceneTags:
        'scenery, seaside, train station, ocean, sunset, clouds, no humans',
    promptTags: 'warm lighting, golden hour, sunset glow, long shadows',
  ),
  (
    file: 'greenhouse',
    scene: '花房',
    prompt: '柔光',
    shape: '方图',
    sceneTags:
        'scenery, greenhouse, flowers, plants, tea table, morning, no humans',
    promptTags:
        'soft lighting, sunlight, light rays, pastel colors, depth of field',
  ),
  (
    file: 'moonlit-waterfall',
    scene: '月瀑',
    prompt: '月光',
    shape: '竖图',
    sceneTags:
        'scenery, forest, waterfall, bridge, moon, fireflies, night, no humans',
    promptTags:
        'moonlight, blue lighting, glowing particles, atmospheric perspective',
  ),
];

/// Retired stock cards stay in backups. An edited or starred example is a
/// library item in its own right, even though it still has the original ID.
bool isStockInspirationExample(TagEntry entry) {
  if (entry.extra['previewExample'] != true ||
      (entry.category != TagCategory.scene &&
          entry.category != TagCategory.other) ||
      entry.origin != TagOrigin.local ||
      entry.isFavorite ||
      entry.publicId != null ||
      entry.negative.isNotEmpty ||
      entry.aliases.isNotEmpty ||
      entry.models.isNotEmpty ||
      entry.recipe != null ||
      entry.previews.length != 1) {
    return false;
  }
  final previewName = entry.previews.single
      .replaceAll('\\', '/')
      .split('/')
      .last;
  if (previewName != '${entry.id}.png') return false;
  final size = "${entry.extra['width']}×${entry.extra['height']}";
  final scene = entry.category == TagCategory.scene;
  for (final example in _examples) {
    if (entry.id ==
        'preview_example_20261002_${entry.category.name}_${example.file}') {
      return entry.name ==
              '${scene ? example.scene : example.prompt} · $size' &&
          entry.positive == (scene ? example.sceneTags : example.promptTags) &&
          listEquals(entry.tags, ['预览示例', example.shape, size]);
    }
  }
  return false;
}

/// Bundled, editable examples. Each entry owns its preview so deleting one
/// never removes the image used by the other category.
Future<List<TagEntry>> loadInspirationExamples({
  required TagCategory category,
  required Set<String> existingIds,
  required Directory support,
  AssetBundle? assets,
}) async {
  if (category != TagCategory.scene && category != TagCategory.other) return [];
  final bundle = assets ?? rootBundle;
  final entries = <TagEntry>[];
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final example in _examples) {
    final id = 'preview_example_20261002_${category.name}_${example.file}';
    if (existingIds.contains(id)) continue;
    final data = await bundle.load(
      'examples/inspiration-previews/${example.file}.png',
    );
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    final target = File('${support.path}/tag_previews/$id.png');
    await writeBytesAtomic(
      target,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final scene = category == TagCategory.scene;
    entries.add(
      TagEntry(
        id: id,
        category: category,
        name: '${scene ? example.scene : example.prompt} · $width×$height',
        positive: scene ? example.sceneTags : example.promptTags,
        tags: ['预览示例', example.shape, '$width×$height'],
        previews: [target.path],
        createdAt: now - entries.length,
        extra: {'previewExample': true, 'width': width, 'height': height},
      ),
    );
  }
  return entries;
}
