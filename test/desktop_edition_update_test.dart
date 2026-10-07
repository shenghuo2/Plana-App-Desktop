import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/core/desktop_edition.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/features/update/desktop_update.dart';
import 'package:plana_app/features/update/macos_update_service.dart';
import 'package:plana_app/features/update/update_service.dart';

const _standard = GithubAsset(
  name: 'Plana-macOS-arm64.dmg',
  url: 'standard',
  size: 1,
);
const _remote = GithubAsset(
  name: 'Plana-RemoteUpload-macOS-arm64.dmg',
  url: 'remote',
  size: 1,
);

GithubRelease _release(List<GithubAsset> assets) => GithubRelease(
  tag: 'v1.1.3-desktop',
  name: '',
  notes: '',
  url: 'https://example.com/release',
  prerelease: true,
  assets: assets,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('同一发布中两版按类型选包,不受资产上传顺序影响', () {
    for (final assets in [
      [_remote, _standard],
      [_standard, _remote],
    ]) {
      final release = _release(assets);
      expect(macOSUpdateAsset(release, 'arm64')?.url, 'standard');
      expect(
        macOSUpdateAsset(
          release,
          'arm64',
          edition: DesktopEdition.remoteUpload,
        )?.url,
        'remote',
      );
    }
  });

  test('缺少本版 DMG 时不提示或下载另一版', () {
    for (final edition in DesktopEdition.values) {
      final release = _release([
        edition == DesktopEdition.standard ? _remote : _standard,
      ]);
      expect(macOSUpdateAsset(release, 'arm64', edition: edition), isNull);
      expect(
        pickNewer(
          kAppVersion,
          [release.toJson()],
          platform: TargetPlatform.macOS,
          edition: edition,
        ),
        isNull,
      );
      final matching = _release([
        edition == DesktopEdition.standard ? _standard : _remote,
      ]);
      expect(
        pickNewer(
          kAppVersion,
          [matching.toJson()],
          platform: TargetPlatform.macOS,
          edition: edition,
        )?.tag,
        matching.tag,
      );
    }
  });

  test('另一版的更新缓存不抑制当前版重新检查', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final root = Directory.systemTemp.createTempSync('plana_edition');
    final prefs = PrefsStore.emptyForTest(root);
    final other = kDesktopEdition == DesktopEdition.standard
        ? DesktopEdition.remoteUpload
        : DesktopEdition.standard;
    try {
      await prefs.write(
        key: 'desktop_update_macOS',
        value: jsonEncode({
          'version': kAppVersion,
          'edition': other.name,
          'architecture': macOSArchitecture,
          'checkedAt': DateTime.now().millisecondsSinceEpoch,
          'release': _release([_standard, _remote]).toJson(),
        }),
      );
      final container = ProviderContainer(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
      );
      try {
        expect(container.read(desktopUpdateProvider).release, isNull);
        expect(
          container.read(desktopUpdateProvider.notifier).shouldAutoCheck,
          isTrue,
        );
      } finally {
        container.dispose();
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
      root.deleteSync(recursive: true);
    }
  });
}
