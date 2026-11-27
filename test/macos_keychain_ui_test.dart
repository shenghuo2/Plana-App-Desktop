import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/auth/credential_store.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/auth/secure_storage.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/profile/account_page.dart';
import 'package:plana_app/features/shell/app_shell.dart';
import 'package:plana_app/features/update/desktop_update.dart';

class _IdleAssistant extends AssistantNotifier {
  @override
  AssistantState build() => const AssistantState();
}

class _MockSecureStorage extends FlutterSecureStorage {
  _MockSecureStorage(this.data);

  final Map<String, String> data;
  bool deny = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (deny) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'Code: -25293, Message: User interaction is not allowed.',
        details: -25293,
      );
    }
    return data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (deny) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'Code: -25293, Message: User interaction is not allowed.',
        details: -25293,
      );
    }
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('readAll forbidden on macOS classic keychain');
}

void main() {
  late Directory root;
  late AppStores stores;
  late _MockSecureStorage spy;
  late CredentialStore creds;
  late ProviderContainer container;
  var disposed = false;

  Future<void> setUpHarness({required bool denyAtBoot}) async {
    disposed = false;
    root = Directory.systemTemp.createTempSync('plana_kc_ui_');
    stores = AppStores.ephemeral();
    spy = _MockSecureStorage({
      'nai_access_keys': jsonEncode([
        {
          'id': 'k1',
          'token': 'pst-test-secret-token',
          'label': '主力账号',
          'primary': true,
        },
      ]),
      'bot_session': jsonEncode({
        'sessionId': 'bot-sess-1',
        'botUserId': 'u-1',
      }),
    })..deny = denyAtBoot;
    creds = await CredentialStore.open(
      stores.prefs,
      root: root,
      secure: spy,
      allowFileFallback: false,
      useSingleVault: true,
      listKeys: () async => spy.data.keys.toList(),
    );
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        secureStorageProvider.overrideWithValue(creds),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
        assistantProvider.overrideWith(_IdleAssistant.new),
        updateReleaseFetcherProvider.overrideWithValue(
          (
            current, {
            String repo = '',
            TargetPlatform? platform,
            String? architecture,
          }) async => null,
        ),
      ],
    );
  }

  Future<void> tearDownHarness(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    disposed = true;
    await tester.pump(const Duration(seconds: 2));
    stores.flushNow();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  tearDown(() {
    if (!disposed) {
      container.dispose();
      stores.flushNow();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  testWidgets('启动时钥匙串被拒后顶部横幅出现，点申请权限后隐藏横幅并重载凭据', (tester) async {
    await setUpHarness(denyAtBoot: true);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('macos-keychain-banner')), findsOneWidget);
    expect(container.read(naiKeysStoreProvider).value, isEmpty);
    expect(container.read(botSessionProvider).value, isNull);

    spy.deny = false;
    await tester.tap(
      find.byKey(const ValueKey('macos-keychain-banner-authorize')),
    );
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      if (!creds.needsAuthorization &&
          (container.read(naiKeysStoreProvider).value?.isNotEmpty ?? false) &&
          container.read(botSessionProvider).value != null) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(creds.needsAuthorization, isFalse);

    expect(find.byKey(const ValueKey('macos-keychain-banner')), findsNothing);
    expect(container.read(naiKeysStoreProvider).value, hasLength(1));
    expect(container.read(naiKeysStoreProvider).value!.first.label, '主力账号');
    expect(container.read(botSessionProvider).value?.sessionId, 'bot-sess-1');

    await tearDownHarness(tester);
  });

  testWidgets('账号与接入页在未授权与已授权状态均提供可点击的钥匙串授权按钮', (tester) async {
    await setUpHarness(denyAtBoot: true);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const AccountPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final authBtn = find.byKey(const ValueKey('macos-keychain-authorize'));
    expect(authBtn, findsOneWidget);
    expect(find.text('申请钥匙串权限'), findsOneWidget);
    expect(find.text('需要授权'), findsOneWidget);

    spy.deny = false;
    await tester.tap(authBtn);
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      if (!creds.needsAuthorization &&
          (container.read(naiKeysStoreProvider).value?.isNotEmpty ?? false) &&
          find.text('重新验证权限').evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(creds.needsAuthorization, isFalse);

    expect(find.text('重新验证权限'), findsOneWidget);
    expect(find.text('已授权 · 2 项'), findsOneWidget);
    expect(container.read(naiKeysStoreProvider).value, hasLength(1));

    await tearDownHarness(tester);
  });
}
