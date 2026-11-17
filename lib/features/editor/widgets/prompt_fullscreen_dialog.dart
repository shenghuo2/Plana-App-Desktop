import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared desktop workspace for a prompt or a folded block's contents.
/// Preserve the caller's provider scope so block edits stay in that session.
Future<void> showPromptFullscreenDialog(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final container = ProviderScope.containerOf(context);
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<void>(
    context: context,
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      return UncontrolledProviderScope(
        container: container,
        child: Dialog(
          key: const ValueKey('prompt-fullscreen-dialog'),
          insetPadding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: size.width - 48,
            height: size.height - 48,
            child: Builder(builder: builder),
          ),
        ),
      );
    },
  );
}
