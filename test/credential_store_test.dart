import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/credential_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';

/// 加密存储留不住数据的机型(每次冷启动整份被清)要改存
/// 文件,正常机型照旧走加密存储。两边判错都要命:漏判 = 每次冷启动丢 Key;
/// 误判 = 好好的机器丢了 Keystore 这层保护,还白白提示一次「Key 被清了」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_cred');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  /// 一次冷启动重新读 `settings.json`(迁移那步不碰加密存储)。
  Future<PrefsStore> boot() => PrefsStore.open(
    root,
    legacyRead: (_) async => null,
    legacyDelete: (_) async {},
  );

  Future<CredentialStore> open(PrefsStore p, {FlutterSecureStorage? secure}) =>
      CredentialStore.open(
        p,
        root: root,
        allowFileFallback: true,
        secure: secure ?? const FlutterSecureStorage(),
      );

  const keystore = FlutterSecureStorage();
  const primed = '{"notifyPrimed":true}';

  /// 用过一阵的老用户:种过暗号、走完过引导、选的直连。
  Future<PrefsStore> veteran() async {
    final p = await boot();
    await p.write(key: CredentialStore.canaryKey, value: 'abc');
    await p.write(key: 'gen_settings', value: primed);
    await p.write(key: kAuthModeKey, value: 'token');
    return p;
  }

  test('全新安装:种下暗号,照旧走加密存储', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final p = await boot();
    final c = await open(p);

    expect(c.usesFile, isFalse);
    final mark = p.get(CredentialStore.canaryKey);
    expect(mark, isNotNull);
    expect(await keystore.read(key: CredentialStore.canaryKey), mark);
    await c.write(key: 'nai_access_keys', value: '[1]');
    expect(await keystore.read(key: 'nai_access_keys'), '[1]');
    expect(c.takeLostNotice(), isFalse);
  });

  test('暗号对得上:照旧走加密存储', () async {
    final p = await veteran();
    FlutterSecureStorage.setMockInitialValues({
      CredentialStore.canaryKey: 'abc',
      'nai_access_keys': '[1]',
    });
    final c = await open(p);

    expect(c.usesFile, isFalse);
    expect(await c.read(key: 'nai_access_keys'), '[1]');
    expect(c.takeLostNotice(), isFalse);
  });

  test('加密存储整份被清:改存文件、提示一次,此后一直走文件', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final c = await open(await veteran());

    expect(c.usesFile, isTrue);
    expect(c.takeLostNotice(), isTrue);
    expect(c.takeLostNotice(), isFalse, reason: '只提示一次');
    await c.write(key: 'nai_access_keys', value: '[1]');

    // 下一次冷启动加密存储照样被清,Key 还在,也不再提示
    FlutterSecureStorage.setMockInitialValues({});
    final again = await open(await boot());
    expect(again.usesFile, isTrue);
    expect(await again.read(key: 'nai_access_keys'), '[1]');
    expect(again.takeLostNotice(), isFalse);
  });

  test('升级后头一次启动:引导走完过却没有接入方式 → 认定被清,补上直连', () async {
    final p = await boot();
    await p.write(key: 'gen_settings', value: primed);
    FlutterSecureStorage.setMockInitialValues({});
    final c = await open(p);

    expect(c.usesFile, isTrue);
    expect(p.get(kAuthModeKey), 'token', reason: '不补的话又被踢回引导页');
    expect(c.takeLostNotice(), isTrue);
  });

  test('升级后头一次启动,加密存储正常:种暗号,不改存', () async {
    final p = await boot();
    await p.write(key: 'gen_settings', value: primed);
    await p.write(key: kAuthModeKey, value: 'bot'); // 刚从加密存储迁出来
    FlutterSecureStorage.setMockInitialValues({'bot_session': '{}'});
    final c = await open(p);

    expect(c.usesFile, isFalse);
    expect(p.get(CredentialStore.canaryKey), isNotNull);
    expect(p.get(kAuthModeKey), 'bot');
    expect(await c.read(key: 'bot_session'), '{}');
  });

  test('自己 deleteAll 不算「被系统清过」:暗号留着,下次照旧走加密存储', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final p = await boot();
    final c = await open(p);
    await c.write(key: 'nai_access_keys', value: '[1]');
    await c.deleteAll();

    expect(await c.readAll(), isEmpty, reason: '暗号不对外露');
    expect(await keystore.read(key: 'nai_access_keys'), isNull);
    final again = await open(await boot());
    expect(again.usesFile, isFalse);
    expect(again.takeLostNotice(), isFalse);
  });

  test('暗号对不上但数据都在(种暗号那次进程被杀):搬进文件,不提示', () async {
    final p = await veteran();
    FlutterSecureStorage.setMockInitialValues({'nai_access_keys': '[1]'});
    final c = await open(p);

    expect(c.usesFile, isTrue);
    expect(await c.read(key: 'nai_access_keys'), '[1]');
    expect(c.takeLostNotice(), isFalse);
  });

  test('加密存储一碰就抛:改存文件,照常读写', () async {
    final c = await open(await veteran(), secure: _Broken());

    expect(c.usesFile, isTrue);
    expect(c.takeLostNotice(), isTrue);
    await c.write(key: 'bot_session', value: 's');
    expect(await c.read(key: 'bot_session'), 's');
  });

  test('全新安装就写不进加密存储:直接走文件,不提示', () async {
    final c = await open(await boot(), secure: _Broken());

    expect(c.usesFile, isTrue);
    expect(c.takeLostNotice(), isFalse);
  });

  test('桌面加密存储报错时保留错误，不写明文退路', () async {
    final p = await veteran();
    final c = await CredentialStore.open(
      p,
      root: root,
      secure: _Broken(),
      allowFileFallback: false,
    );
    expect(c.usesFile, isFalse);
    await expectLater(
      c.write(key: 'nai_access_keys', value: 'test-only'),
      throwsStateError,
    );
    expect(
      File('${root.path}/${CredentialStore.fileName}').existsSync(),
      isFalse,
    );
    expect(p.get(CredentialStore.backendKey), isNull);
  });

  test('接入方式存在 settings.json,不进加密存储', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(c.dispose);

    await c.read(authModeProvider.future);
    await c.read(authModeProvider.notifier).set(AuthMode.bot);
    expect(stores.prefs.get(kAuthModeKey), 'bot');
    expect(await keystore.read(key: kAuthModeKey), isNull);
  });

  registerMacOsVaultTests(boot, () => root);
}

/// Keystore 彻底用不了的机器:读写都抛。
class _Broken extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('keystore');

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
  }) async => throw StateError('keystore');

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('keystore');
}

class _SpySecureStorage extends FlutterSecureStorage {
  _SpySecureStorage([Map<String, String>? initial])
    : data = Map<String, String>.of(initial ?? const {});

  final Map<String, String> data;
  final List<String> readCalls = [];
  final List<String> writeCalls = [];
  final List<String> deleteCalls = [];
  int readAllCalls = 0;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  bool forbidReadAll = false;
  String? failReadKey;

  void resetCounts() {
    readCalls.clear();
    writeCalls.clear();
    deleteCalls.clear();
    readAllCalls = 0;
  }

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
    readCalls.add(key);
    if (failRead || key == failReadKey) throw StateError('keychain denied');
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
    writeCalls.add(key);
    if (failWrite) throw StateError('keychain write error');
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
    deleteCalls.add(key);
    if (failDelete) throw StateError('keychain delete error');
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
  }) async {
    readCalls.add(key);
    return data.containsKey(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readAllCalls++;
    if (forbidReadAll) {
      throw StateError('macOS classic Keychain forbids readAll');
    }
    if (failRead) throw StateError('keychain denied');
    return Map<String, String>.of(data);
  }
}

void registerMacOsVaultTests(
  Future<PrefsStore> Function() boot,
  Directory Function() getRoot,
) {
  group('macOS 单条目钥匙串合并存储', () {
    test('全新安装写入多项凭据仅存单条目，重启后仅一次底层读取且不落明文文件', () async {
      final spy = _SpySecureStorage()..forbidReadAll = true;
      final p1 = await boot();
      final c1 = await CredentialStore.open(
        p1,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );
      expect(c1.usesSingleVault, isTrue);
      expect(c1.usesFile, isFalse);
      expect(c1.needsAuthorization, isFalse);
      expect(spy.readAllCalls, 0);
      expect(spy.writeCalls, isEmpty);
      expect(p1.get(CredentialStore.macOsVaultMigratedKey), '1');

      await c1.write(key: 'nai_access_keys', value: '["k1"]');
      await c1.write(key: 'bot_session', value: '{"sessionId":"b1"}');
      await c1.write(key: 'chatgpt_plan_profiles_v1', value: '{"profiles":{}}');
      await c1.write(key: 'external_oc_abc', value: 'pw');
      await c1.write(key: 'external_image_push_token', value: 'img-tok');
      expect(spy.data.keys.toList(), [CredentialStore.macOsVaultKey]);
      expect(
        File('${getRoot().path}/${CredentialStore.fileName}').existsSync(),
        isFalse,
      );

      // Cold restart with fresh store instances only reads the single vault key once.
      spy.resetCounts();
      final p2 = await boot();
      final c2 = await CredentialStore.open(
        p2,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );
      expect(spy.readAllCalls, 0);
      expect(spy.readCalls, [CredentialStore.macOsVaultKey]);

      expect(await c2.read(key: 'nai_access_keys'), '["k1"]');
      expect(await c2.read(key: 'bot_session'), '{"sessionId":"b1"}');
      expect(await c2.read(key: 'chatgpt_plan_profiles_v1'), '{"profiles":{}}');
      expect(await c2.read(key: 'external_oc_abc'), 'pw');
      expect(await c2.read(key: 'external_image_push_token'), 'img-tok');
      expect(spy.readCalls, [CredentialStore.macOsVaultKey]);
    });

    test('老版本多条目钥匙串经属性枚举迁入单条目、清除旧条目且绝不调用 readAll', () async {
      final spy = _SpySecureStorage({
        'nai_access_keys': '["k1"]',
        'bot_session': '{"sessionId":"b2"}',
        'assistant_endpoints': '[{"id":"e1"}]',
        'drive_tokens': '{"access":"tok"}',
        'theme_settings': '{"mode":"dark"}',
        '__plana_macos_keychain_smoke_test__': 'smoke',
      })..forbidReadAll = true;
      final p1 = await boot();
      final c1 = await CredentialStore.open(
        p1,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );

      expect(spy.readAllCalls, 0);
      expect(p1.get('theme_settings'), '{"mode":"dark"}');
      expect(p1.get(CredentialStore.macOsVaultMigratedKey), '1');
      expect(spy.data.keys.toSet(), {
        CredentialStore.macOsVaultKey,
        '__plana_macos_keychain_smoke_test__',
      });
      expect(await c1.read(key: 'nai_access_keys'), '["k1"]');
      expect(await c1.read(key: 'bot_session'), '{"sessionId":"b2"}');
      expect(await c1.read(key: 'assistant_endpoints'), '[{"id":"e1"}]');
      expect(await c1.read(key: 'drive_tokens'), '{"access":"tok"}');

      spy.resetCounts();
      final p2 = await boot();
      final c2 = await CredentialStore.open(
        p2,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );
      expect(spy.readAllCalls, 0);
      expect(spy.readCalls, [CredentialStore.macOsVaultKey]);
      expect(await c2.read(key: 'drive_tokens'), '{"access":"tok"}');
    });

    test('属性枚举不可用时回退 containsKey 探测迁移已知旧键及外置角色库密钥', () async {
      await Directory(
        '${getRoot().path}/external_oc/oc123',
      ).create(recursive: true);
      final spy = _SpySecureStorage({
        'nai_access_keys': '["k_fallback"]',
        'external_oc_oc123': 'oc-secret',
        'external_oc_session_oc123': 'cookie-1',
      })..forbidReadAll = true;
      final p = await boot();
      final c = await CredentialStore.open(
        p,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => null,
      );

      expect(spy.readAllCalls, 0);
      expect(c.needsAuthorization, isFalse);
      expect(await c.read(key: 'nai_access_keys'), '["k_fallback"]');
      expect(await c.read(key: 'external_oc_oc123'), 'oc-secret');
      expect(await c.read(key: 'external_oc_session_oc123'), 'cookie-1');
      expect(spy.data.keys.toList(), [CredentialStore.macOsVaultKey]);
    });

    test('启动读取钥匙串被拒绝后标记需要授权，主动申请授权后可解锁并恢复全部凭据', () async {
      var activated = 0;
      final spy =
          _SpySecureStorage({
              CredentialStore.macOsVaultKey: jsonEncode({
                'v': 1,
                'entries': {'nai_access_keys': 'existing'},
              }),
            })
            ..forbidReadAll = true
            ..failRead = true;
      final p = await boot();
      final c = await CredentialStore.open(
        p,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
        activateForPrompt: () async {
          activated++;
        },
      );

      expect(c.needsAuthorization, isTrue);
      expect(c.isVaultUnlocked, isFalse);
      expect(p.get(CredentialStore.macOsVaultMigratedKey), isNull);
      await expectLater(
        c.write(key: 'nai_access_keys', value: 'new'),
        throwsStateError,
      );
      expect(spy.writeCalls, isEmpty);

      spy.failRead = false;
      final unlock = await c.requestKeychainAccess();
      expect(activated, 1);
      expect(unlock.ok, isTrue);
      expect(unlock.entryCount, 1);
      expect(c.needsAuthorization, isFalse);
      expect(c.isVaultUnlocked, isTrue);
      expect(await c.read(key: 'nai_access_keys'), 'existing');
    });

    test('部分老条目读取被拒绝时保留未完成迁移标记，授权完成后补迁全部旧条目', () async {
      final spy =
          _SpySecureStorage({
              'nai_access_keys': '["k1"]',
              'bot_session': '{"sessionId":"b1"}',
            })
            ..forbidReadAll = true
            ..failReadKey = 'bot_session';
      final p = await boot();
      final c = await CredentialStore.open(
        p,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );

      expect(c.needsAuthorization, isTrue);
      expect(p.get(CredentialStore.macOsVaultMigratedKey), isNull);
      expect(spy.data.containsKey('bot_session'), isTrue);
      expect(spy.data.containsKey(CredentialStore.macOsVaultKey), isTrue);

      spy.failReadKey = null;
      final unlock = await c.requestKeychainAccess();
      expect(unlock.ok, isTrue);
      expect(unlock.entryCount, 2);
      expect(c.needsAuthorization, isFalse);
      expect(p.get(CredentialStore.macOsVaultMigratedKey), '1');
      expect(spy.data.keys.toList(), [CredentialStore.macOsVaultKey]);
      expect(await c.read(key: 'nai_access_keys'), '["k1"]');
      expect(await c.read(key: 'bot_session'), '{"sessionId":"b1"}');
    });

    test('全新安装调用 requestKeychainAccess 会落盘校验单条目以预申请读写授权', () async {
      final spy = _SpySecureStorage()..forbidReadAll = true;
      final p = await boot();
      final c = await CredentialStore.open(
        p,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );

      final result = await c.requestKeychainAccess();
      expect(result.ok, isTrue);
      expect(result.entryCount, 0);
      expect(spy.data.containsKey(CredentialStore.macOsVaultKey), isTrue);
      expect(c.isVaultUnlocked, isTrue);
      expect(c.needsAuthorization, isFalse);
    });

    test('迁移写入失败时不删除旧钥匙串条目也不标记已迁移', () async {
      final spy =
          _SpySecureStorage({
              'nai_access_keys': '["k1"]',
              'bot_session': '{"sessionId":"b1"}',
            })
            ..forbidReadAll = true
            ..failWrite = true;
      final p = await boot();
      final c = await CredentialStore.open(
        p,
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );

      expect(c.needsAuthorization, isTrue);
      expect(spy.deleteCalls, isEmpty);
      expect(p.get(CredentialStore.macOsVaultMigratedKey), isNull);
      expect(spy.data['nai_access_keys'], '["k1"]');
      expect(spy.data['bot_session'], '{"sessionId":"b1"}');
    });

    test('describeKeychainError 准确映射常见 macOS 钥匙串错误码', () {
      expect(
        CredentialStore.describeKeychainError(
          PlatformException(
            code: 'Unexpected security result code',
            details: -25293,
          ),
        ),
        contains('始终允许'),
      );
      expect(
        CredentialStore.describeKeychainError(
          PlatformException(
            code: 'Unexpected security result code',
            details: -128,
          ),
        ),
        contains('取消'),
      );
      expect(
        CredentialStore.describeKeychainError(
          PlatformException(
            code: 'Unexpected security result code',
            details: -25308,
          ),
        ),
        contains('锁定'),
      );
    });

    test('并发写入多项凭据均完整落入同一单条目', () async {
      final spy = _SpySecureStorage()..forbidReadAll = true;
      final c = await CredentialStore.open(
        await boot(),
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );

      await Future.wait([
        c.write(key: 'k1', value: 'v1'),
        c.write(key: 'k2', value: 'v2'),
        c.write(key: 'k3', value: 'v3'),
      ]);

      expect(await c.readAll(), {'k1': 'v1', 'k2': 'v2', 'k3': 'v3'});
      final persisted =
          jsonDecode(spy.data[CredentialStore.macOsVaultKey]!) as Map;
      expect(persisted['entries'], {'k1': 'v1', 'k2': 'v2', 'k3': 'v3'});
    });

    test('delete 与 deleteAll 清空条目后保留单条目外壳以维持授权', () async {
      final spy = _SpySecureStorage()..forbidReadAll = true;
      final c = await CredentialStore.open(
        await boot(),
        root: getRoot(),
        secure: spy,
        allowFileFallback: false,
        useSingleVault: true,
        listKeys: () async => spy.data.keys.toList(),
      );
      await c.write(key: 'a', value: '1');
      await c.write(key: 'b', value: '2');

      await c.delete(key: 'a');
      expect(await c.containsKey(key: 'a'), isFalse);
      expect(await c.read(key: 'b'), '2');

      await c.deleteAll();
      expect(await c.readAll(), isEmpty);
      expect(spy.data.containsKey(CredentialStore.macOsVaultKey), isTrue);
      expect(spy.deleteCalls, isEmpty);
    });
  });
}
