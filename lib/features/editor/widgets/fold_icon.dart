import 'package:flutter/material.dart';

import '../../../core/ui/tag_category_icons.dart';
import '../editor_models.dart';

/// AI fold names begin with a one-character category marker. The editable
/// reference keeps that stable marker even if the proposal chooses another icon.
Map<String, IconData> foldIconsOf(List<PromptFoldLink> links) => {
  for (final link in links)
    if (link.temporaryCategory != null)
      if (kTagCategoryIcons[link.temporaryIcon] case final icon?)
        for (final name in [link.positiveName, link.negativeName])
          if (name.length > 2 && name[1] == ' ') name: icon,
};

TextSpan foldLabelSpan(String name, IconData? icon, {bool hash = false}) {
  final prefix = hash ? '#' : '';
  if (icon == null) return TextSpan(text: '$prefix$name');
  return TextSpan(
    children: [
      if (hash) const TextSpan(text: '#'),
      TextSpan(
        text: String.fromCharCode(icon.codePoint),
        semanticsLabel: '',
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
        ),
      ),
      TextSpan(text: name.substring(1)),
    ],
  );
}
