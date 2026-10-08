import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/desktop_edition.dart';
import '../../core/store/app_stores.dart';
import '../inpaint/inpaint_overlay.dart';
import '../editor/editor_state.dart';
import '../shell/desktop_work_state.dart';
import 'desktop_update.dart';
import 'macos_update_service.dart';
import 'update_service.dart';

enum MacOSUpdateStage { idle, downloading, ready, installing }

class MacOSUpdateState {
  const MacOSUpdateState({
    this.stage = MacOSUpdateStage.idle,
    this.received = 0,
    this.total = 0,
    this.downloaded,
    this.error,
    this.message,
  });
  final MacOSUpdateStage stage;
  final int received;
  final int total;
  final DownloadedMacOSUpdate? downloaded;
  final String? error;
  final String? message;
  int get percent => total > 0 ? (received * 100 ~/ total).clamp(0, 100) : 0;
  bool get busy =>
      stage == MacOSUpdateStage.downloading ||
      stage == MacOSUpdateStage.installing;
}

final macOSUpdateServiceProvider = Provider(
  (ref) => MacOSUpdateService(edition: kDesktopEdition),
);
final macOSUpdateProvider =
    NotifierProvider<MacOSUpdateNotifier, MacOSUpdateState>(
      MacOSUpdateNotifier.new,
    );

class MacOSUpdateNotifier extends Notifier<MacOSUpdateState> {
  @override
  MacOSUpdateState build() {
    final service = ref.read(macOSUpdateServiceProvider);
    ref.onDispose(service.cancelDownload);
    return const MacOSUpdateState();
  }

  Future<void> acknowledgeStartup() async {
    if (!Platform.isMacOS) return;
    try {
      final result = await ref
          .read(macOSUpdateServiceProvider)
          .acknowledgeStartup();
      if (result != null && ref.mounted) {
        state = MacOSUpdateState(
          message: result ? '上次更新已完成' : '上次更新未完成,当前版本已保留',
        );
      }
    } catch (_) {}
  }

  Future<void> download(GithubRelease release) async {
    if (state.busy) return;
    state = const MacOSUpdateState(stage: MacOSUpdateStage.downloading);
    var lastPercent = -1;
    try {
      final downloaded = await ref
          .read(macOSUpdateServiceProvider)
          .download(
            release,
            architecture: macOSArchitecture,
            onProgress: (received, total) {
              final percent = received * 100 ~/ total;
              if (!ref.mounted || percent == lastPercent) return;
              lastPercent = percent;
              state = MacOSUpdateState(
                stage: MacOSUpdateStage.downloading,
                received: received,
                total: total,
              );
            },
          );
      if (ref.mounted) {
        state = MacOSUpdateState(
          stage: MacOSUpdateStage.ready,
          downloaded: downloaded,
        );
      }
    } on UpdateDownloadCancelled {
      if (ref.mounted) state = const MacOSUpdateState();
    } catch (e) {
      if (ref.mounted) state = MacOSUpdateState(error: '$e');
    }
  }

  void cancelDownload() =>
      ref.read(macOSUpdateServiceProvider).cancelDownload();

  bool get _canInstall =>
      !ref.read(desktopWorkBusyProvider) &&
      ref.read(inpaintSessionProvider) == null;

  Future<void> install() async {
    if (state.busy || state.downloaded == null) return;
    final downloaded = state.downloaded!;
    if (!_canInstall) {
      state = MacOSUpdateState(
        stage: MacOSUpdateStage.ready,
        downloaded: downloaded,
        error: '请先结束生成、排队、助手任务及图片编辑',
      );
      return;
    }
    final stores = ref.read(appStoresProvider);
    state = MacOSUpdateState(
      stage: MacOSUpdateStage.installing,
      downloaded: downloaded,
    );
    try {
      await ref
          .read(macOSUpdateServiceProvider)
          .install(
            downloaded,
            architecture: macOSArchitecture,
            beforeExit: () async {
              if (!ref.mounted || !_canInstall) {
                throw const UpdateException('任务尚未结束,当前版本已保留');
              }
              ref.read(editorSessionsProvider).flushPending();
              await stores.flushForExit();
              if (!ref.mounted || !_canInstall) {
                throw const UpdateException('任务尚未结束,当前版本已保留');
              }
            },
          );
    } catch (e) {
      if (ref.mounted) {
        state = MacOSUpdateState(
          stage: MacOSUpdateStage.ready,
          downloaded: downloaded,
          error: '$e',
        );
      }
    }
  }
}
