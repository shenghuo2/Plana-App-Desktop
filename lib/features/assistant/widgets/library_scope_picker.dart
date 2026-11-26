import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../inspiration/external/oc_sources.dart';
import '../assistant_settings.dart';
import 'desktop_settings_dropdown.dart';

class LibraryScopePicker extends ConsumerWidget {
  const LibraryScopePicker({
    super.key,
    required this.selection,
    required this.botAuthorized,
    required this.onChanged,
  });

  final LibrarySelection selection;
  final bool botAuthorized;
  final ValueChanged<LibrarySelection> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(ocSourcesProvider).value ?? const <OcSource>[];
    final ids = sources.map((s) => s.id);
    final order = selection.available(ids);
    final l = context.l10n;
    final labels = {
      LibrarySelection.local: l.localLibrary,
      LibrarySelection.public: l.publicLibrary,
      for (final s in sources) s.id: s.label,
    };
    final active = selection.active(ids, botAuthorized: botAuthorized);
    return DesktopSettingsMenu(
      id: 'assistant-library-dropdown',
      label: l.libraryScope,
      summary: active.isEmpty
          ? l.librarySelectionOff
          : active.map((id) => labels[id]!).join(' › '),
      menu: (height) => [
        CheckboxListTile(
          key: const ValueKey('library-pause'),
          title: Text(l.librarySelectionOff),
          value: selection.paused,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (value) => onChanged(selection.withPause(value == true)),
        ),
        SizedBox(
          height: math.min(order.length * 48.0, math.max(48, height - 52)),
          child: ReorderableListView.builder(
            primary: false,
            buildDefaultDragHandles: false,
            padding: EdgeInsets.zero,
            itemExtent: 48,
            itemCount: order.length,
            onReorderItem: (from, to) {
              if (selection.paused) return;
              final next = [...order];
              next.insert(to, next.removeAt(from));
              onChanged(selection.withOrder(next));
            },
            itemBuilder: (context, index) {
              final id = order[index];
              final locked = id == LibrarySelection.public && !botAuthorized;
              final disabled = selection.paused || locked;
              return AnimatedOpacity(
                key: ValueKey('library-row-$id'),
                duration: const Duration(milliseconds: 150),
                opacity: disabled ? .42 : 1,
                child: CheckboxListTile(
                  key: ValueKey('library-check-$id'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    labels[id]!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: locked
                      ? Text(
                          l.desktopBotAuthorizationRequired,
                          style: const TextStyle(fontSize: 11),
                        )
                      : null,
                  value: selection.enabled.contains(id),
                  onChanged: disabled
                      ? null
                      : (_) => onChanged(selection.toggle(id)),
                  secondary: Tooltip(
                    message: l.librarySourcePriority,
                    child: ReorderableDragStartListener(
                      key: ValueKey('library-handle-$id'),
                      index: index,
                      enabled: !selection.paused,
                      child: const SizedBox(
                        width: 36,
                        height: 44,
                        child: Icon(Icons.drag_handle, size: 20),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
