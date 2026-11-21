import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop_directory.dart';
import '../../core/store/app_stores.dart';

/// Both the overview and album toolbar share this operation. A kept-alive page
/// or a newly mounted album must not launch a second Explorer while it is busy.
final galleryOutputFolderProvider =
    NotifierProvider<GalleryOutputFolderNotifier, bool>(
      GalleryOutputFolderNotifier.new,
    );

class GalleryOutputFolderNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> open() async {
    if (state) return;
    final root = ref.read(appStoresProvider).desktopOutput.root;
    final launcher = ref.read(desktopDirectoryLauncherProvider);
    var current = true;
    state = true;
    try {
      // Legacy migration already runs as boot maintenance. Opening the folder
      // must not wait for a whole archive, pending save, or offline old path.
      await launcher
          .open(root, isCurrent: () => current && ref.mounted)
          .timeout(const Duration(seconds: 10));
    } finally {
      // A timed-out filesystem preparation must not launch a late window.
      current = false;
      if (ref.mounted) state = false;
    }
  }
}
