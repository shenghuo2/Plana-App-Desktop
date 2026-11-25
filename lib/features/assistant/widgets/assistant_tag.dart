import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';

class AssistantTag extends StatelessWidget {
  const AssistantTag(this.text, {super.key, this.active = false});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: active ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(
                Icons.check,
                size: 13,
                color: scheme.onPrimaryContainer,
                semanticLabel: context.l10n.inUse,
              ),
            ),
          Text(
            text,
            style: context.texts.labelSmall!.copyWith(
              color: active
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
