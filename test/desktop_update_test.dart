import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/features/update/desktop_update.dart';
import 'package:plana_app/features/update/update_service.dart';

const _release = GithubRelease(
  tag: 'v1.1.1-desktop.46',
  name: '',
  notes: '更新说明',
  url: 'https://github.com/$kGithubRepo/releases/tag/v1.1.1-desktop.46',
  prerelease: false,
  assets: [
    GithubAsset(name: 'Plana-macOS.dmg'),
    GithubAsset(name: 'Plana-Windows-x64.zip'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PrefsStore prefs;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    root = Directory.systemTemp.createTempSync('plana_desktop_update');
    prefs = PrefsStore.emptyForTest(root);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    root.deleteSync(recursive: true);
  });

  ProviderContainer container(Future<GithubRelease?> Function() fetch) {
    final c = ProviderContainer(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        updateReleaseFetcherProvider.overrideWithValue((
          current, {
          String repo = kGithubRepo,
          TargetPlatform? platform,
          String? architecture,
        }) {
          expect(current, kAppVersion);
          expect(platform, defaultTargetPlatform);
          return fetch();
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('手动和自动检查同时触发时共用一次请求', () async {
    final pending = Completer<GithubRelease?>();
    var calls = 0;
    final c = container(() {
      calls++;
      return pending.future;
    });
    final updates = c.read(desktopUpdateProvider.notifier);
    final auto = updates.check();
    final manual = updates.check();
    expect(identical(auto, manual), isTrue);
    expect(c.read(desktopUpdateProvider).checking, isTrue);
    pending.complete(_release);
    final results = await Future.wait([auto, manual]);
    expect(calls, 1);
    expect(results.every((check) => check.hasUpdate), isTrue);
    expect(c.read(desktopUpdateProvider).checking, isFalse);
    expect(results.first.installed.versionCode, int.parse(kAppBuild));
  });

  test('重启仍保留新版本标记,24 小时内不重复自动检查', () async {
    final first = container(() async => _release);
    await first.read(desktopUpdateProvider.notifier).check();

    final restarted = container(() async => throw StateError('不该请求'));
    expect(restarted.read(desktopUpdateProvider).release?.tag, _release.tag);
    expect(restarted.read(desktopUpdateProvider).release?.notes, '更新说明');
    expect(
      restarted.read(desktopUpdateProvider.notifier).shouldAutoCheck,
      isFalse,
    );
  });

  test('网络失败保留已检测到的更新,失败首次检查不阻止下次重试', () async {
    final first = container(() async => _release);
    await first.read(desktopUpdateProvider.notifier).check();
    final failed = container(() async => throw const UpdateException('检查更新超时'));
    await expectLater(
      failed.read(desktopUpdateProvider.notifier).check(),
      throwsA(isA<UpdateException>()),
    );
    expect(failed.read(desktopUpdateProvider).release?.tag, _release.tag);
    expect(failed.read(desktopUpdateProvider).error, '检查更新超时');
    expect(failed.read(desktopUpdateProvider).checking, isFalse);

    await prefs.delete(key: 'desktop_update_macOS');
    final fresh = container(
      () async => throw const UpdateException('连不上 GitHub'),
    );
    await expectLater(
      fresh.read(desktopUpdateProvider.notifier).check(),
      throwsA(isA<UpdateException>()),
    );
    expect(fresh.read(desktopUpdateProvider.notifier).shouldAutoCheck, isTrue);
  });

  test('没有更新时清除旧标记,重启也不会恢复旧标记', () async {
    final first = container(() async => _release);
    await first.read(desktopUpdateProvider.notifier).check();
    final checked = container(() async => null);
    expect(
      (await checked.read(desktopUpdateProvider.notifier).check()).hasUpdate,
      isFalse,
    );
    final restarted = container(() async => null);
    expect(restarted.read(desktopUpdateProvider).release, isNull);
    expect(restarted.read(desktopUpdateProvider).checkedAt, isNotNull);
  });

  test('平台或当前版本变化不沿用旧缓存', () async {
    final first = container(() async => _release);
    await first.read(desktopUpdateProvider.notifier).check();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final windows = container(() async => _release);
    expect(windows.read(desktopUpdateProvider).release, isNull);
    expect(
      windows.read(desktopUpdateProvider.notifier).shouldAutoCheck,
      isTrue,
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final saved = jsonDecode(prefs.get('desktop_update_macOS')!) as Map;
    saved['version'] = '1.1.1-desktop.44';
    await prefs.write(key: 'desktop_update_macOS', value: jsonEncode(saved));
    final upgraded = container(() async => _release);
    expect(upgraded.read(desktopUpdateProvider).release, isNull);
    expect(
      upgraded.read(desktopUpdateProvider.notifier).shouldAutoCheck,
      isTrue,
    );
  });

  test('页面销毁时在途检查完成不会再写已销毁 provider 的状态', () async {
    final pending = Completer<GithubRelease?>();
    final c = container(() => pending.future);
    final checking = c.read(desktopUpdateProvider.notifier).check();
    c.dispose();
    pending.complete(_release);
    expect((await checking).hasUpdate, isTrue);
  });
}
