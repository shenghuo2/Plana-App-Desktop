import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/ui_prefs.dart';
import '../../l10n/l10n.dart';
import '../shell/shell_state.dart';

/// A request also reaches a retained toolbox that is showing a detail route or
/// a batch. A newly mounted toolbox opens on its persisted tab in single mode.
final singleMetadataRequestProvider =
    NotifierProvider<SingleMetadataRequest, int>(SingleMetadataRequest.new);

class SingleMetadataRequest extends Notifier<int> {
  @override
  int build() => 0;

  void open() {
    ref.read(uiPrefsProvider.notifier).patch((p) => p.copyWith(toolsTab: 1));
    state++;
    ref.read(shellIndexProvider.notifier).select(kTabTools);
  }
}

class MetadataToolLink extends ConsumerWidget {
  const MetadataToolLink({super.key, this.beforeOpen});
  final VoidCallback? beforeOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const Icon(Icons.document_scanner_outlined),
    title: Text(context.l10n.customMetadata),
    subtitle: Text(context.l10n.toolboxMetadataSource),
    trailing: const Icon(Icons.chevron_right),
    onTap: () {
      final request = ref.read(singleMetadataRequestProvider.notifier);
      beforeOpen?.call();
      request.open();
    },
  );
}
