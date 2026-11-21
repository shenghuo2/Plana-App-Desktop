import 'package:flutter/material.dart';

import '../../../core/ui/desktop_popover.dart';
import '../../../l10n/l10n.dart';

/// Empty string selects automatic sizing. Dismissing returns null.
Future<String?> showImageOptionMenu(
  BuildContext anchor, {
  required String title,
  required List<String> options,
  required String current,
  bool auto = true,
  String Function(String)? labelOf,
}) => showDesktopPopover<String>(
  anchor,
  width: 180,
  maxHeight: 304,
  preferAbove: true,
  builder: (context) => Semantics(
    label: title,
    child: ListView(
      shrinkWrap: true,
      primary: false,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final value in [if (auto) '', ...options])
          ListTile(
            dense: true,
            selected: value == current,
            title: Text(
              value.isEmpty
                  ? context.l10n.imageAuto
                  : (labelOf?.call(value) ?? value),
            ),
            trailing: value == current
                ? const Icon(Icons.check, size: 18)
                : null,
            onTap: () => Navigator.pop(context, value),
          ),
      ],
    ),
  ),
);
