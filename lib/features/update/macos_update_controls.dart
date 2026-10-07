import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../inpaint/inpaint_overlay.dart';
import '../shell/desktop_work_state.dart';
import 'desktop_update.dart';
import 'macos_update_controller.dart';
import 'macos_update_service.dart';
import 'update_service.dart';

class MacOSUpdateControls extends ConsumerWidget {
  const MacOSUpdateControls({super.key, required this.release});
  final GithubRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(macOSUpdateProvider);
    final controller = ref.read(macOSUpdateProvider.notifier);
    final asset = macOSUpdateAsset(release, macOSArchitecture);
    final busy = ref.watch(desktopWorkBusyProvider);
    final editing = ref.watch(inpaintSessionProvider) != null;
    final ready = state.downloaded?.release.tag == release.tag;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.error != null) ...[
          Text(state.error!, style: TextStyle(color: context.scheme.error)),
          const SizedBox(height: 10),
        ],
        if (state.stage == MacOSUpdateStage.downloading) ...[
          LinearProgressIndicator(
            value: state.total > 0 ? state.received / state.total : null,
          ),
          const SizedBox(height: 8),
          Text('下载更新 · ${state.percent}%'),
          TextButton(
            onPressed: controller.cancelDownload,
            child: const Text('取消下载'),
          ),
        ] else if (state.stage == MacOSUpdateStage.installing) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('正在准备更新,完成后将重新启动…'),
        ] else if (ready) ...[
          const Text('更新包已下载,安装后将重新启动应用。'),
          if (busy || editing)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('请先结束生成、排队、助手任务及图片编辑。'),
            ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const ValueKey('macos-install-update'),
            onPressed: busy || editing ? null : controller.install,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('安装并重新启动'),
          ),
        ] else if (asset != null)
          FilledButton.icon(
            key: const ValueKey('macos-download-update'),
            onPressed: () => controller.download(release),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('下载更新'),
          )
        else
          const Text('此版本需从发布页下载。'),
      ],
    );
  }
}
