import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A flat settings field with a menu anchored below its full width.
class DesktopSettingsDropdown<T> extends StatelessWidget {
  const DesktopSettingsDropdown({
    super.key,
    required this.id,
    required this.label,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.enabled = true,
    this.optionEnabled,
    this.optionNote,
  });

  final String id;
  final String label;
  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final bool Function(T)? optionEnabled;
  final String? Function(T)? optionNote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium!.copyWith(fontSize: 13, color: scheme.onSurface);
    return DesktopSettingsMenu(
      id: id,
      label: label,
      summary: labelOf(value),
      enabled: enabled,
      menu: (_) => [
        for (final option in options)
          MenuItemButton(
            key: ValueKey('$id-option-$option'),
            autofocus: option == value,
            onPressed: (optionEnabled?.call(option) ?? true)
                ? () {
                    if (enabled && option != value) {
                      onChanged(option);
                    }
                  }
                : null,
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
              visualDensity: VisualDensity.standard,
              backgroundColor: option == value
                  ? WidgetStatePropertyAll(
                      scheme.primary.withValues(alpha: .08),
                    )
                  : null,
              textStyle: WidgetStatePropertyAll(textStyle),
            ),
            trailingIcon: option == value
                ? Icon(Icons.check, size: 18, color: scheme.primary)
                : const SizedBox(width: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(labelOf(option)),
                if (optionNote?.call(option) case final String note)
                  Text(note, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
      ],
    );
  }
}

class DesktopSettingsMenu extends StatefulWidget {
  const DesktopSettingsMenu({
    super.key,
    required this.id,
    required this.label,
    required this.summary,
    required this.menu,
    this.enabled = true,
  });
  final String id, label, summary;
  final List<Widget> Function(double availableHeight) menu;
  final bool enabled;
  @override
  State<DesktopSettingsMenu> createState() => _DesktopSettingsMenuState();
}

class _DesktopSettingsMenuState extends State<DesktopSettingsMenu> {
  final _menu = MenuController();
  final _focus = FocusNode();
  final _anchor = GlobalKey();
  double _menuHeight = 280;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _open() {
    if (!widget.enabled) return;
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final media = MediaQuery.of(context);
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      final room = media.size.height - media.padding.bottom - bottom - 14;
      // Keep the menu below the field and scroll when space is limited.
      // At the very bottom of a small window, allow Flutter's edge fallback.
      setState(() => _menuHeight = room >= 64 ? math.min(280, room) : 280);
    }
    _menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium!.copyWith(fontSize: 13, color: scheme.onSurface);
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        controller: _menu,
        childFocusNode: _focus,
        useRootOverlay: true,
        consumeOutsideTap: true,
        crossAxisUnconstrained: false,
        alignmentOffset: const Offset(0, 6),
        style: MenuStyle(
          alignment: AlignmentDirectional.bottomStart,
          visualDensity: VisualDensity.standard,
          minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
          maximumSize: WidgetStatePropertyAll(
            Size(constraints.maxWidth, _menuHeight),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
          elevation: const WidgetStatePropertyAll(0),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        menuChildren: widget.menu(_menuHeight - 8),
        builder: (context, controller, _) => Focus(
          onKeyEvent: (_, event) {
            if (widget.enabled &&
                event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.arrowDown &&
                !controller.isOpen) {
              _open();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
            key: _anchor,
            width: double.infinity,
            child: OutlinedButton(
              key: ValueKey(widget.id),
              focusNode: _focus,
              onPressed: widget.enabled
                  ? () => controller.isOpen ? controller.close() : _open()
                  : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                visualDensity: VisualDensity.standard,
                elevation: 0,
                shadowColor: Colors.transparent,
                backgroundColor: scheme.surfaceContainerLow,
                foregroundColor: scheme.onSurface,
                side: BorderSide(color: scheme.outlineVariant),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: textStyle,
              ),
              child: Semantics(
                label: widget.label,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.expand_more, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
