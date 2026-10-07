import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/desktop_edition.dart';
import '../../core/store/app_stores.dart';
import 'update_service.dart';

/// 顶栏、关于页和后台检查共用结果,避免并发请求及互相覆盖。
final desktopUpdateProvider =
    NotifierProvider<DesktopUpdateNotifier, DesktopUpdateStatus>(
      DesktopUpdateNotifier.new,
    );

final updateReleaseFetcherProvider = Provider((ref) => fetchLatestRelease);

String get macOSArchitecture =>
    Abi.current() == Abi.macosArm64 ? 'arm64' : 'x64';

class DesktopUpdateStatus {
  const DesktopUpdateStatus({
    this.release,
    this.checkedAt,
    this.checking = false,
    this.error,
  });

  final GithubRelease? release;
  final DateTime? checkedAt;
  final bool checking;
  final String? error;

  UpdateCheck get check => UpdateCheck(
    installed: InstalledInfo(
      versionName: kAppVersion,
      versionCode: int.parse(kAppBuild),
    ),
    release: release,
  );
}

class DesktopUpdateNotifier extends Notifier<DesktopUpdateStatus> {
  Future<UpdateCheck>? _inFlight;
  String get _key => 'desktop_update_${defaultTargetPlatform.name}';

  @override
  DesktopUpdateStatus build() {
    // 缓存按平台和已装版本隔离;升级后重新查,24h 节流期间保留更新标记。
    final saved = ref.read(prefsStoreProvider).get(_key);
    if (saved == null) return const DesktopUpdateStatus();
    try {
      final json = jsonDecode(saved) as Map<String, dynamic>;
      if (json['version'] != kAppVersion) return const DesktopUpdateStatus();
      if ((json['edition'] ?? DesktopEdition.standard.name) !=
          kDesktopEdition.name) {
        return const DesktopUpdateStatus();
      }
      if (defaultTargetPlatform == TargetPlatform.macOS &&
          json['architecture'] != macOSArchitecture) {
        return const DesktopUpdateStatus();
      }
      final checkedAt = DateTime.fromMillisecondsSinceEpoch(
        json['checkedAt'] as int,
      );
      final value = json['release'];
      final release = value == null
          ? null
          : GithubRelease.fromJson(value as Map<String, dynamic>);
      if (value != null &&
          (release == null ||
              !release.supportsPlatform(
                defaultTargetPlatform,
                edition: kDesktopEdition,
                architecture: defaultTargetPlatform == TargetPlatform.macOS
                    ? macOSArchitecture
                    : null,
              ) ||
              compareSemver(release.tag, kAppVersion) <= 0)) {
        return const DesktopUpdateStatus();
      }
      return DesktopUpdateStatus(release: release, checkedAt: checkedAt);
    } catch (_) {
      return const DesktopUpdateStatus();
    }
  }

  bool get shouldAutoCheck {
    final last = state.checkedAt;
    return last == null ||
        DateTime.now().difference(last) >= const Duration(hours: 24);
  }

  Future<UpdateCheck> check() =>
      _inFlight ??= _check().whenComplete(() => _inFlight = null);

  Future<UpdateCheck> _check() async {
    final previous = state;
    final prefs = ref.read(prefsStoreProvider);
    final fetch = ref.read(updateReleaseFetcherProvider);
    final platform = defaultTargetPlatform;
    final architecture = platform == TargetPlatform.macOS
        ? macOSArchitecture
        : null;
    final key = _key;
    state = DesktopUpdateStatus(
      release: previous.release,
      checkedAt: previous.checkedAt,
      checking: true,
    );
    try {
      final release = await fetch(
        kAppVersion,
        platform: platform,
        architecture: architecture,
      );
      final result = DesktopUpdateStatus(
        release: release,
        checkedAt: DateTime.now(),
      );
      if (ref.mounted) state = result;
      try {
        await prefs.write(
          key: key,
          value: jsonEncode({
            'version': kAppVersion,
            'edition': kDesktopEdition.name,
            'architecture': architecture,
            'checkedAt': result.checkedAt!.millisecondsSinceEpoch,
            'release': release?.toJson(),
          }),
        );
      } catch (_) {
        // 缓存写失败不影响本次的检查结果。
      }
      return result.check;
    } catch (e) {
      if (ref.mounted) {
        state = DesktopUpdateStatus(
          release: previous.release,
          checkedAt: previous.checkedAt,
          error: '$e',
        );
      }
      rethrow;
    }
  }
}
