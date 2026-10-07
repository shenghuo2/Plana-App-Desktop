import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/external_image_push_config.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PrefsStore prefs;
  late ProviderContainer container;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('plana_remote_config');
    prefs = PrefsStore.emptyForTest(root);
    container = ProviderContainer(
      overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    );
  });
  tearDown(() async {
    container.dispose();
    await prefs.idle;
    root.deleteSync(recursive: true);
  });

  test('Token 只存加密存储,保留凭据编辑配置,重启恢复收藏开关', () async {
    expect(container.read(favoriteAutoUploadProvider), isFalse);
    await container.read(externalImagePushSettingsProvider.future);
    final notifier = container.read(externalImagePushSettingsProvider.notifier);
    await notifier.save(
      endpoint: 'https://images.example/base/api/v1/assets/',
      sourceName: '桌面',
      token: 'test-secret-token',
    );
    expect(
      container.read(externalImagePushSettingsProvider).value?.isConfigured,
      isTrue,
    );
    expect((await notifier.credentials())?.token, 'test-secret-token');
    expect(
      (await notifier.credentials())?.endpoint,
      'https://images.example/base',
    );
    await notifier.save(endpoint: 'https://images.example', sourceName: '新的来源');
    expect((await notifier.credentials())?.token, 'test-secret-token');
    await container.read(favoriteAutoUploadProvider.notifier).set(true);
    final plain = File('${root.path}/settings.json').readAsStringSync();
    expect(plain, isNot(contains('test-secret-token')));
    expect(plain, isNot(contains('external_image_push_token')));
    final reopened = await PrefsStore.open(
      root,
      legacyRead: (_) async => null,
      legacyDelete: (_) async {},
    );
    final restarted = ProviderContainer(
      overrides: [prefsStoreProvider.overrideWithValue(reopened)],
    );
    try {
      expect(restarted.read(favoriteAutoUploadProvider), isTrue);
      expect(
        (await restarted.read(
          externalImagePushSettingsProvider.future,
        )).sourceName,
        '新的来源',
      );
    } finally {
      restarted.dispose();
    }
    await notifier.clearToken();
    expect(await notifier.credentials(), isNull);
    expect(
      container.read(externalImagePushSettingsProvider).value?.hasToken,
      isFalse,
    );
  });

  test('无效 API 统一返回可显示的配置异常,不修改已保存配置', () async {
    await container.read(externalImagePushSettingsProvider.future);
    final notifier = container.read(externalImagePushSettingsProvider.notifier);
    await notifier.save(
      endpoint: 'https://images.example',
      sourceName: 'PlanaAPP',
      token: 'test-token',
    );
    for (final endpoint in [
      'invalid',
      'https://token@images.example',
      'https://images.example/?token=x',
    ]) {
      await expectLater(
        notifier.save(endpoint: endpoint, sourceName: 'PlanaAPP'),
        throwsA(isA<ExternalImagePushConfigException>()),
      );
    }
    expect(
      container.read(externalImagePushSettingsProvider).value?.endpoint,
      'https://images.example',
    );
  });
}
