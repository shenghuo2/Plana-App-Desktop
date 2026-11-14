import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../gallery_output_folder.dart';
import 'gallery_toolbar_button.dart';

/// The archive folder is shared by the library overview and its image browser.
class GalleryOutputFolderButton extends ConsumerStatefulWidget {
  const GalleryOutputFolderButton({super.key});

  @override
  ConsumerState<GalleryOutputFolderButton> createState() =>
      _GalleryOutputFolderButtonState();
}

class _GalleryOutputFolderButtonState
    extends ConsumerState<GalleryOutputFolderButton> {
  bool get _visible => TickerMode.getValuesNotifier(context).value.enabled;

  Future<void> _open() async {
    final store = ref.read(appStoresProvider).desktopOutput;
    try {
      await ref.read(galleryOutputFolderProvider.notifier).open();
      if (mounted && _visible && store.lastMigration?.hasErrors == true) {
        hintSnack(context, '部分旧作品未能迁移，仍保留在原目录；图库历史可正常使用');
      }
    } on TimeoutException {
      if (mounted && _visible) hintSnack(context, '打开作品文件夹超时，请稍后重试');
    } catch (_) {
      if (mounted && _visible) {
        hintSnack(context, '无法打开作品文件夹，请检查目录是否可用：${store.root.path}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final opening = ref.watch(galleryOutputFolderProvider);
    return Tooltip(
      message: '自动保存：${ref.read(appStoresProvider).desktopOutput.root.path}',
      child: GalleryToolbarButton(
        key: const ValueKey('desktop-gallery-folder'),
        onPressed: opening ? null : _open,
        icon: Icons.folder_open_outlined,
        label: opening ? '正在打开…' : '作品文件夹',
      ),
    );
  }
}
