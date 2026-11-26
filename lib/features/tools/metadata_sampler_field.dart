import 'package:flutter/material.dart';

import '../../core/ui/editable_combo_field.dart';
import '../../l10n/l10n.dart';
import '../generate/models.dart' show samplers;
import '../generate/nai_request.dart' show naiSamplerId;

class MetadataSamplerField extends StatelessWidget {
  const MetadataSamplerField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.decoration,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => EditableComboField(
    controller: controller,
    enabled: enabled,
    decoration: decoration,
    onChanged: onChanged,
    options: {for (final name in samplers) name: naiSamplerId(name)},
    emptyLabel: context.l10n.noMatchingInCat(context.l10n.desktopSampler),
    fieldKey: const ValueKey('metadata-field-sampler'),
    menuKey: const ValueKey('metadata-sampler-options'),
    toggleKey: const ValueKey('metadata-sampler-toggle'),
  );
}
