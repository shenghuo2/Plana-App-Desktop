import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';
import '../../../core/ui/setting_row.dart';
import '../../generate/widgets/common.dart' show dropFocusSoon;

/// Composer choices share the same anchored desktop menu and mobile sheet.
Future<T?> showAssistantChoiceSheet<T>(
  BuildContext anchor, {
  required String title,
  required T current,
  required List<T> choices,
  required String Function(T) label,
  required IconData Function(T) icon,
  bool preferAbove = false,
}) async {
  final desktop = ProviderScope.containerOf(
    anchor,
    listen: false,
  ).read(desktopModeProvider);
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final items = [
      for (final choice in choices)
        ListTile(
          dense: desktop,
          selected: choice == current,
          selectedTileColor: scheme.primaryContainer.withValues(alpha: .35),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Icon(
            choice == current ? Icons.check_circle : icon(choice),
            size: 21,
          ),
          title: Text(
            label(choice),
            style: context.texts.bodyLarge!.copyWith(
              fontWeight: choice == current ? FontWeight.w700 : FontWeight.w500,
              color: choice == current ? scheme.primary : null,
            ),
          ),
          onTap: () => Navigator.pop(context, choice),
        ),
    ];
    if (!desktop) return SettingSheet(title: title, children: items);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(
              children: [
                Expanded(child: Text(title)),
                const CloseButton(),
              ],
            ),
          ),
          ...items,
        ],
      ),
    );
  }

  if (desktop) {
    return showDesktopPopover<T>(
      anchor,
      width: 280,
      maxHeight: 80.0 + choices.length * 52,
      preferAbove: preferAbove,
      builder: build,
    );
  }
  final picked = await showModalBottomSheet<T>(
    context: anchor,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: build,
  );
  dropFocusSoon();
  return picked;
}
