import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/selection_bar.dart';
import '../../../l10n/l10n.dart';

class DesktopInspirationSelectionBar extends StatelessWidget {
  const DesktopInspirationSelectionBar({
    super.key,
    required this.count,
    required this.busy,
    required this.onPrompt,
    required this.onCharacters,
    required this.onClear,
    this.menu,
  });

  final int count;
  final bool busy;
  final VoidCallback onPrompt, onClear;
  final VoidCallback? onCharacters;
  final Widget? menu;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
    child: Align(
      alignment: Alignment.center,
      heightFactor: 1,
      child: Material(
        key: const ValueKey('desktop-inspiration-selection'),
        color: context.scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: context.scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                context.l10n.selectedItems(count),
                style: context.texts.labelLarge,
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('inspiration-selection-prompt'),
                onPressed: busy ? null : onPrompt,
                icon: const Icon(Icons.bolt_outlined, size: 18),
                label: Text(context.l10n.desktopMainPrompt),
              ),
              if (onCharacters != null)
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onCharacters,
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: Text(context.l10n.desktopAddCharacter),
                ),
              ?menu,
              if (menu == null)
                TextButton.icon(
                  onPressed: busy ? null : onClear,
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(context.l10n.clearSelection),
                )
              else
                IconButton(
                  tooltip: context.l10n.clearSelection,
                  onPressed: busy ? null : onClear,
                  icon: const Icon(Icons.close, size: 20),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class InspirationApplyActions extends StatelessWidget {
  const InspirationApplyActions({
    super.key,
    required this.count,
    required this.busy,
    required this.onPrompt,
    required this.onCharacters,
  });

  final int count;
  final bool busy;
  final VoidCallback onPrompt;
  final VoidCallback? onCharacters;

  @override
  Widget build(BuildContext context) {
    if (onCharacters == null) {
      return FilledButton.icon(
        onPressed: busy ? null : onPrompt,
        icon: const Icon(Icons.check, size: 18),
        label: Text(context.l10n.confirmSelectionN(count)),
        style: selectionPrimaryStyle(),
      );
    }
    final scheme = context.scheme;
    final bg = scheme.primary;
    final fg = scheme.onPrimary;
    Widget seg({
      required int flex,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) => Expanded(
      flex: flex,
      child: Material(
        color: bg,
        child: InkWell(
          onTap: busy ? null : onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelLarge!.copyWith(
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      height: kSelectionActionHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kSelectionActionRadius),
        child: Row(
          children: [
            seg(
              flex: 5,
              icon: Icons.bolt_outlined,
              label: context.l10n.desktopMainPrompt,
              onTap: onPrompt,
            ),
            Container(width: 1.5, color: scheme.surfaceContainer),
            seg(
              flex: 6,
              icon: Icons.person_add_alt,
              label: context.l10n.desktopAddCharacter,
              onTap: onCharacters!,
            ),
          ],
        ),
      ),
    );
  }
}
