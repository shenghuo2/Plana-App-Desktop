import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';
import 'package:flutter/material.dart';

/// Keep the secondary controls aligned in height alongside the desktop generate button.
class DesktopGenerationActions extends StatelessWidget {
  const DesktopGenerationActions({
    super.key,
    required this.generateButton,
    required this.loopActive,
    required this.onLoop,
    required this.onImport,
  });

  final Widget generateButton;
  final bool loopActive;
  final VoidCallback onLoop;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final secondaryShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return Row(
      children: [
        Expanded(child: generateButton),
        const SizedBox(width: 6),
        SizedBox.square(
          dimension: 44,
          child: IconButton.filledTonal(
            tooltip: l10nNow.loopGenerate,
            onPressed: onLoop,
            isSelected: loopActive,
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: secondaryShape,
              backgroundColor: loopActive
                  ? scheme.primaryContainer
                  : scheme.surfaceContainer,
              foregroundColor: loopActive
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
              side: BorderSide(
                color: loopActive
                    ? scheme.primary.withValues(alpha: .5)
                    : scheme.outlineVariant,
              ),
            ),
            icon: const Icon(Icons.autorenew, size: 20),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox.square(
          dimension: 44,
          child: IconButton.outlined(
            tooltip: l10nNow.importImage,
            onPressed: onImport,
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: secondaryShape,
              backgroundColor: scheme.surfaceContainer,
              foregroundColor: scheme.onSurfaceVariant,
              side: BorderSide(color: scheme.outlineVariant),
            ),
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
          ),
        ),
      ],
    );
  }
}
