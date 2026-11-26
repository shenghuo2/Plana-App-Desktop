import 'package:flutter/material.dart' show IconData, Icons;

/// 自定义类别可选的图标。键名同 web 注册表的 lucide 图标名(`Shirt` 是 app 加的)。
const kTagCategoryIcons = <String, IconData>{
  'Shirt': Icons.checkroom_outlined,
  'Sparkles': Icons.auto_awesome_outlined,
  'Sun': Icons.wb_sunny_outlined,
  'Moon': Icons.dark_mode_outlined,
  'Heart': Icons.favorite_border,
  'Star': Icons.star_outline,
  'Camera': Icons.photo_camera_outlined,
  'Flame': Icons.local_fire_department_outlined,
  'Leaf': Icons.eco_outlined,
  'Flower': Icons.local_florist_outlined,
  'Crown': Icons.workspace_premium_outlined,
  'Gem': Icons.diamond_outlined,
  'Hand': Icons.back_hand_outlined,
  'Eye': Icons.visibility_outlined,
  'Smile': Icons.sentiment_satisfied_outlined,
  'PersonStanding': Icons.accessibility_new,
  'Music': Icons.music_note_outlined,
  'Brush': Icons.brush_outlined,
  'Wand': Icons.auto_fix_high_outlined,
  'Zap': Icons.bolt_outlined,
  'Cloud': Icons.cloud_outlined,
  'Snowflake': Icons.ac_unit,
  'Droplet': Icons.water_drop_outlined,
  'Tag': Icons.sell_outlined,
};

String _iconLookupKey(String name) =>
    name.trim().toLowerCase().replaceAll('_', '');

final _canonicalIconKeys = {
  for (final name in kTagCategoryIcons.keys) _iconLookupKey(name): name,
};

/// Convert a model-supplied spelling to the key used by the icon registry.
String? canonicalTagIconKey(Object? value) =>
    value is String ? _canonicalIconKeys[_iconLookupKey(value)] : null;
