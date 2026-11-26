import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

TextField buildDesktopInspirationSearch(
  BuildContext context, {
  required Key key,
  required TextEditingController controller,
  required ValueChanged<String> onChanged,
  required String hint,
  FocusNode? focusNode,
}) {
  final scheme = context.scheme;
  final outline = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );
  return TextField(
    key: key,
    controller: controller,
    focusNode: focusNode,
    onChanged: onChanged,
    style: context.texts.bodyMedium,
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: const Icon(Icons.search, size: 20),
      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: outline,
      enabledBorder: outline,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
  );
}
