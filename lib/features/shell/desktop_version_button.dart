import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/desktop_popover.dart';
import '../update/desktop_update.dart';
import '../update/macos_update_controller.dart';
import '../update/update_sheet.dart';

class DesktopVersionButton extends ConsumerWidget {
  const DesktopVersionButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(
      desktopUpdateProvider.select((status) => status.release),
    );
    return Tooltip(
      message: release == null
          ? '版本信息与更新 · 构建 $kAppBuild'
          : '发现新版本 ${release.display}',
      child: TextButton(
        key: const ValueKey('desktop-version-button'),
        onPressed: () => showDesktopPopover(
          context,
          width: 340,
          builder: (_) => const _VersionPanel(),
        ),
        style: TextButton.styleFrom(
          foregroundColor: context.scheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('v$kAppVersion', style: TextStyle(fontSize: 11)),
            if (release != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.upgrade,
                key: const ValueKey('desktop-update-marker'),
                color: context.scheme.tertiary,
                size: 18,
                semanticLabel: '有新版本',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VersionPanel extends ConsumerWidget {
  const _VersionPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(desktopUpdateProvider);
    final update = ref.watch(macOSUpdateProvider);
    final release = status.release;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(kAppName, style: context.texts.titleMedium),
          const SizedBox(height: 6),
          Text('版本 $kAppVersion · 构建 $kAppBuild'),
          const SizedBox(height: 16),
          Text(
            release != null
                ? '新版本 ${release.display}'
                : status.checkedAt != null
                ? '暂未发现新版本'
                : '尚未检查更新',
            style: TextStyle(
              color: release != null
                  ? context.scheme.tertiary
                  : context.scheme.onSurfaceVariant,
            ),
          ),
          if (status.error != null) ...[
            const SizedBox(height: 8),
            Text(status.error!, style: TextStyle(color: context.scheme.error)),
          ],
          if (update.message != null) ...[
            const SizedBox(height: 8),
            Text(update.message!),
          ],
          if (update.busy) ...[
            const SizedBox(height: 8),
            Text(
              update.stage == MacOSUpdateStage.downloading
                  ? '更新包下载中 · ${update.percent}%'
                  : '正在准备更新…',
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (release != null)
                FilledButton.tonalIcon(
                  onPressed: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    unawaited(
                      showUpdateSheet(
                        navigator.context,
                        status.check,
                        desktop: true,
                      ),
                    );
                  },
                  icon: const Icon(Icons.system_update_alt, size: 18),
                  label: const Text('查看更新'),
                ),
              TextButton.icon(
                key: const ValueKey('desktop-check-update'),
                onPressed: status.checking
                    ? null
                    : () async {
                        try {
                          await ref
                              .read(desktopUpdateProvider.notifier)
                              .check();
                        } catch (_) {
                          // 错误保存在共享状态,在面板内显示。
                        }
                      },
                icon: status.checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(status.checking ? '检查中…' : '检查更新'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
