import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../store/gen_settings.dart';
import '../store/prefs_store.dart';
import '../util/log.dart';
import 'auth_mode.dart';
import 'secure_storage.dart';

typedef MacOsKeychainKeyLister = Future<List<String>?> Function();
typedef MacOsActivateForPrompt = Future<void> Function();

class CredentialVaultStatus {
  const CredentialVaultStatus({
    this.enabled = false,
    this.unlocked = false,
    this.needsAuthorization = false,
    this.entryCount = 0,
    this.lastError,
  });

  final bool enabled;
  final bool unlocked;
  final bool needsAuthorization;
  final int entryCount;
  final String? lastError;
}

class CredentialVaultUnlockResult {
  const CredentialVaultUnlockResult({
    required this.ok,
    this.entryCount = 0,
    this.migratedCount = 0,
    this.error,
  });

  final bool ok;
  final int entryCount;
  final int migratedCount;
  final String? error;
}

/// 凭据(NAI Key、Bot 会话、助手自填接口)的读写出口。桌面沿用平台加密存储;
/// Android 被证实留不住 Keystore 之后才改存支持目录里的 [fileName]。
///
/// **为什么要这条退路**:flutter_secure_storage 冷启动解不开 Keystore 里的密钥时,
/// 默认的 `resetOnError` 会把整份加密存储清空,而且不报错。有的机型每次冷启动
/// 都这样:进程内一切正常,一清后台凭据就没了。
///
/// **怎么认出来**:`settings.json` 与加密存储各放一份同样的随机暗号([canaryKey]),
/// 启动时两边对不上(加密存储那份没了或读不出来)就是被清过。升级上来的第一次
/// 启动还没有暗号,改用「引导走完过,接入方式却没能从加密存储迁出来」认 ——
/// 正是改之前反复弹引导的那个现场。
///
/// 继承 [FlutterSecureStorage] 只为让各读写点(都经 [secureStorageProvider])
/// 一行不改。加密档原样转给 [_secure];各读写点从不传平台参数,这里也不往下传。
class CredentialStore extends FlutterSecureStorage {
  CredentialStore._(
    this._secure,
    this._file, {
    this._prefs,
    this._lost = false,
    this._singleVault = false,
    String? vaultKey,
    this._listKeys,
    this._activateForPrompt,
  }) : _vaultKey = vaultKey ?? macOsVaultKey {
    vaultStatus = ValueNotifier(CredentialVaultStatus(enabled: _singleVault));
  }

  final FlutterSecureStorage _secure;
  final PrefsStore? _prefs;
  final bool _singleVault;
  final String _vaultKey;
  final MacOsKeychainKeyLister? _listKeys;
  final MacOsActivateForPrompt? _activateForPrompt;

  late final ValueNotifier<CredentialVaultStatus> vaultStatus;
  Map<String, String>? _vaultCache;
  bool _vaultPersisted = false;
  int _lastMigratedCount = 0;
  Future<void> _vaultQueue = Future.value();

  /// 非空 = 已改存文件(复用 [PrefsStore] 的整表读写:原子落盘、串行写)。
  final PrefsStore? _file;

  bool _lost;

  /// `settings.json` 里的标记:改存文件后记 `file`,此后每次启动直接走文件。
  static const backendKey = 'cred_backend';

  /// 暗号,`settings.json` 与加密存储里各一份。
  static const canaryKey = 'cred_canary';

  static const fileName = 'credentials.json';

  /// Single Keychain item holding all macOS credentials so ad-hoc updates
  /// trigger at most one Keychain authorization prompt.
  static const macOsVaultKey = 'plana_desktop_vault_v1';
  static const macOsVaultMigratedKey = 'macos_vault_migrated_v1';
  static const macOsKeychainChannelName = 'plana/macos_keychain';
  static const _smokeTestKey = '__plana_macos_keychain_smoke_test__';

  static const macOsLegacySecretKeys = <String>[
    'nai_access_keys',
    'nai_access_token',
    'nai_login_access_key',
    'bot_session',
    'assistant_endpoints',
    'chatgpt_plan_profiles_v1',
    'desktop_google_drive_client',
    'desktop_google_drive_authorized_client',
    'desktop_google_drive_refresh',
    'external_image_push_token',
  ];

  bool get usesFile => _file != null;
  bool get usesSingleVault => _singleVault;
  bool get needsAuthorization => vaultStatus.value.needsAuthorization;
  bool get isVaultUnlocked => vaultStatus.value.unlocked;

  /// 本次启动认定「加密存储被清过,且什么都没救回来」时为真;取一次就清掉,
  /// 只提示一次。
  bool takeLostNotice() {
    final v = _lost;
    _lost = false;
    return v;
  }

  static String describeKeychainError(Object error) {
    if (error is PlatformException) {
      final code = _extractOsStatus(error);
      switch (code) {
        case -128:
          return '已取消系统钥匙串授权';
        case -25293:
          return '钥匙串访问被拒绝，请在系统弹窗中选择「始终允许」或「允许」';
        case -25308:
          return '钥匙串已锁定或当前不允许交互，请先在「钥匙串访问」解锁登录钥匙串';
        case -50:
          return '钥匙串查询参数错误 (-50)';
      }
      final msg = error.message?.trim();
      if (msg != null && msg.isNotEmpty) return msg;
    }
    return '$error';
  }

  static int? _extractOsStatus(PlatformException error) {
    if (error.details is int) return error.details as int;
    final msg = '${error.code} ${error.message ?? ''} ${error.details ?? ''}';
    final match = RegExp(r'(?<!\d)(-\d{2,6})(?!\d)').firstMatch(msg);
    if (match != null) return int.tryParse(match.group(1)!);
    return null;
  }

  static Future<List<String>?> _defaultListKeys() async {
    const channel = MethodChannel(macOsKeychainChannelName);
    try {
      final list = await channel.invokeListMethod<String>('listKeys', {
        'service': kMacOsSecureStorageService,
      });
      return list;
    } on MissingPluginException {
      return null;
    } catch (e) {
      logi('[cred] macOS keychain attribute listing failed: $e');
      return null;
    }
  }

  static Future<void> _defaultActivateForPrompt() async {
    const channel = MethodChannel(macOsKeychainChannelName);
    try {
      await channel.invokeMethod<void>('activateForPrompt');
    } catch (_) {}
  }

  /// 必须在 [PrefsStore.open] 之后:判定要用到它刚从加密存储迁出来的接入方式。
  /// 任何一步出意外都照旧用加密存储,不挡启动。
  static Future<CredentialStore> open(
    PrefsStore prefs, {
    Directory? root,
    FlutterSecureStorage secure = kSecureStorage,
    bool? allowFileFallback,
    bool? useSingleVault,
    MacOsKeychainKeyLister? listKeys,
    MacOsActivateForPrompt? activateForPrompt,
    String? vaultKeyOverride,
  }) async {
    // Desktop credentials stay in the platform's encrypted store. Android's
    // Keystore recovery must never turn a desktop key into a plaintext file.
    if (!(allowFileFallback ?? Platform.isAndroid)) {
      if (useSingleVault ?? Platform.isMacOS) {
        final store = CredentialStore._(
          secure,
          null,
          prefs: prefs,
          singleVault: true,
          vaultKey: vaultKeyOverride,
          listKeys: listKeys ?? (Platform.isMacOS ? _defaultListKeys : null),
          activateForPrompt:
              activateForPrompt ??
              (Platform.isMacOS ? _defaultActivateForPrompt : null),
        );
        try {
          await store._warmSingleVault();
        } catch (e) {
          // Allow startup even if Keychain access is canceled or denied;
          // _vaultCache stays null so subsequent writes cannot clobber data.
          store._setNeedsAuthorization(e);
          logi(
            '[cred] macOS single vault startup load deferred: ${e.runtimeType}',
          );
        }
        return store;
      }
      return CredentialStore._(secure, null);
    }
    try {
      final dir = root ?? await getApplicationSupportDirectory();
      final file = File('${dir.path}/$fileName');
      if (prefs.get(backendKey) == 'file') {
        return CredentialStore._(secure, await PrefsStore.openFile(file));
      }
      final mark = prefs.get(canaryKey);
      String? seen;
      var unreadable = false;
      try {
        seen = await secure.read(key: canaryKey);
      } catch (_) {
        unreadable = true;
      }
      final wiped = mark != null
          ? unreadable || seen != mark
          : notifyPrimedIn(prefs) && prefs.get(kAuthModeKey) == null;
      if (!wiped && await _plant(prefs, secure, mark)) {
        return CredentialStore._(secure, null);
      }
      return await _fallBack(prefs, secure, file, wiped: wiped);
    } catch (e) {
      logi('[cred] 启动检查失败,照旧用加密存储: ${e.runtimeType}');
      return CredentialStore._(secure, null);
    }
  }

  /// 没种过就种上。先写加密存储、再写 `settings.json` —— 反过来的话,前一笔
  /// 没写成会在下次启动被误判成「被清过」。加密存储写不进去说明这台机的
  /// Keystore 用不了,返回 false 改走文件。
  static Future<bool> _plant(
    PrefsStore prefs,
    FlutterSecureStorage secure,
    String? mark,
  ) async {
    if (mark != null) return true;
    final rnd = Random.secure();
    final v = [
      for (var i = 0; i < 16; i++)
        rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    try {
      await secure.write(key: canaryKey, value: v);
    } catch (_) {
      return false;
    }
    await prefs.write(key: canaryKey, value: v);
    return true;
  }

  static Future<CredentialStore> _fallBack(
    PrefsStore prefs,
    FlutterSecureStorage secure,
    File file, {
    required bool wiped,
  }) async {
    final store = await PrefsStore.openFile(file);
    // 读得出来的先搬过来:暗号对不上也可能只是种暗号那次进程被杀(加密存储的
    // 落盘慢半拍),那时数据其实都还在,不该让用户重填。
    var rescued = 0;
    try {
      for (final e in (await secure.readAll()).entries) {
        if (e.key == canaryKey) continue;
        if (e.key == kAuthModeKey) {
          // 没能迁进 settings.json 的接入方式,归位到它该在的地方
          if (prefs.get(kAuthModeKey) == null) {
            await prefs.write(key: kAuthModeKey, value: e.value);
          }
          continue;
        }
        // 还没迁走的老设置项归 PrefsStore 管,它每次启动自己会再试
        if (PrefsStore.migrateKeys.contains(e.key)) continue;
        await store.write(key: e.key, value: e.value);
        rescued++;
      }
    } catch (_) {}
    await prefs.write(key: backendKey, value: 'file');
    final primed = notifyPrimedIn(prefs);
    // 走完过引导的人,接入方式也跟着没了:按直连补上,免得再走一遍引导。
    // Bot 用户去「账号与接入」切回去即可。
    if (primed && prefs.get(kAuthModeKey) == null) {
      await prefs.write(key: kAuthModeKey, value: AuthMode.token.name);
    }
    logi('[cred] 加密存储${wiped ? '被清过' : '写不进去'},凭据改存本机文件(救回 $rescued 项)');
    return CredentialStore._(
      secure,
      store,
      lost: wiped && primed && rescued == 0,
    );
  }

  void _setUnlocked(int count) {
    vaultStatus.value = CredentialVaultStatus(
      enabled: _singleVault,
      unlocked: true,
      needsAuthorization: false,
      entryCount: count,
    );
  }

  void _setNeedsAuthorization(Object error, {int? entryCount}) {
    vaultStatus.value = CredentialVaultStatus(
      enabled: _singleVault,
      unlocked: false,
      needsAuthorization: true,
      entryCount: entryCount ?? _vaultCache?.length ?? 0,
      lastError: describeKeychainError(error),
    );
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
  }) => _runVaultOrDirect(
    () async => (await _loadSingleVaultLocked())[key],
    () => _file?.read(key: key) ?? _secure.read(key: key),
  );

  String _encodeVault(Map<String, String> entries) =>
      jsonEncode({'v': 1, 'entries': entries});

  Map<String, String> _decodeVault(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['entries'] is! Map) {
      throw const FormatException('corrupt macOS credential vault');
    }
    final out = <String, String>{};
    for (final e in (decoded['entries'] as Map).entries) {
      if (e.key is String && e.value is String) {
        out[e.key as String] = e.value as String;
      }
    }
    return out;
  }

  Future<T> _runVaultOp<T>(Future<T> Function() action) {
    final next = _vaultQueue.then((_) => action());
    _vaultQueue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<T> _runVaultOrDirect<T>(
    Future<T> Function() vaultAction,
    Future<T> Function() directAction,
  ) => _singleVault ? _runVaultOp(vaultAction) : directAction();

  Future<void> _warmSingleVault() => _runVaultOp(_loadSingleVaultLocked);

  /// Explicitly requests or re-verifies macOS Keychain access and reloads the
  /// cached single vault from Keychain.
  Future<CredentialVaultUnlockResult> requestKeychainAccess() async {
    if (!_singleVault) {
      return const CredentialVaultUnlockResult(ok: true);
    }
    return _runVaultOp(() async {
      await _activateForPrompt?.call();
      _vaultCache = null;
      try {
        final entries = await _loadSingleVaultLocked();
        if (!_vaultPersisted) {
          final encoded = _encodeVault(entries);
          await _secure.write(key: _vaultKey, value: encoded);
          final verify = await _secure.read(key: _vaultKey);
          if (verify != encoded) {
            throw StateError('vault verification mismatch');
          }
          _vaultPersisted = true;
        }
        _setUnlocked(entries.length);
        return CredentialVaultUnlockResult(
          ok: true,
          entryCount: entries.length,
          migratedCount: _lastMigratedCount,
        );
      } catch (e) {
        _setNeedsAuthorization(e);
        return CredentialVaultUnlockResult(
          ok: false,
          error: describeKeychainError(e),
        );
      }
    });
  }

  Iterable<String> _discoverExternalOcLegacyKeys() sync* {
    final dir = _prefs?.supportDirectory;
    if (dir == null) return;
    final extDir = Directory('${dir.path}${Platform.pathSeparator}external_oc');
    try {
      if (!extDir.existsSync()) return;
      for (final entity in extDir.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .lastOrNull;
        if (name == null || name.startsWith('.')) continue;
        yield 'external_oc_$name';
        yield 'external_oc_session_$name';
      }
    } catch (_) {}
  }

  Future<List<String>> _discoverLegacyKeys() async {
    final listed = await _listKeys?.call();
    if (listed != null) {
      final seen = <String>{};
      return [
        for (final k in listed)
          if (seen.add(k)) k,
      ];
    }
    final candidates = <String>{
      ...macOsLegacySecretKeys,
      ..._discoverExternalOcLegacyKeys(),
      ...PrefsStore.migrateKeys,
    };
    final found = <String>[];
    for (final k in candidates) {
      if (await _secure.containsKey(key: k)) {
        found.add(k);
      }
    }
    return found;
  }

  Future<Map<String, String>> _loadSingleVaultLocked() async {
    if (_vaultCache != null) return _vaultCache!;
    _lastMigratedCount = 0;

    final String? rawVault;
    try {
      rawVault = await _secure.read(key: _vaultKey);
    } catch (e) {
      _setNeedsAuthorization(e);
      rethrow;
    }

    final entries = rawVault == null
        ? <String, String>{}
        : _decodeVault(rawVault);
    if (rawVault != null) _vaultPersisted = true;

    final prefs = _prefs;
    if (prefs?.get(macOsVaultMigratedKey) != '1') {
      final List<String> legacyCandidates;
      try {
        legacyCandidates = await _discoverLegacyKeys();
      } catch (e) {
        _setNeedsAuthorization(e, entryCount: entries.length);
        rethrow;
      }

      final legacySecretKeys = <String>[];
      final legacyPrefKeys = <String>[];
      var hadReadError = false;
      Object? firstReadError;
      final skipSmokeKey = _vaultKey == macOsVaultKey;

      for (final k in legacyCandidates) {
        if (k == _vaultKey ||
            k == macOsVaultKey ||
            k == canaryKey ||
            (skipSmokeKey && k == _smokeTestKey)) {
          continue;
        }
        try {
          final value = await _secure.read(key: k);
          if (value == null) continue;
          if (PrefsStore.migrateKeys.contains(k)) {
            legacyPrefKeys.add(k);
            if (prefs != null && prefs.get(k) == null && value.isNotEmpty) {
              await prefs.write(key: k, value: value);
            }
            continue;
          }
          legacySecretKeys.add(k);
          // Existing vault entries take precedence over leftover legacy items.
          entries.putIfAbsent(k, () => value);
        } catch (e) {
          hadReadError = true;
          firstReadError ??= e;
        }
      }

      if (legacySecretKeys.isNotEmpty) {
        try {
          final encoded = _encodeVault(entries);
          await _secure.write(key: _vaultKey, value: encoded);
          final verify = await _secure.read(key: _vaultKey);
          if (verify != encoded) {
            throw StateError('vault verification mismatch');
          }
          _vaultPersisted = true;
          _lastMigratedCount = legacySecretKeys.length;
        } catch (e) {
          _setNeedsAuthorization(e, entryCount: entries.length);
          rethrow;
        }
      }

      var allDeleted = true;
      for (final k in [...legacySecretKeys, ...legacyPrefKeys]) {
        try {
          await _secure.delete(key: k);
        } catch (_) {
          allDeleted = false;
        }
      }

      if (hadReadError) {
        final error = firstReadError!;
        _setNeedsAuthorization(error, entryCount: entries.length);
        throw error;
      }

      if (allDeleted && _prefs != null) {
        await _prefs.write(key: macOsVaultMigratedKey, value: '1');
      }
    }

    _vaultCache = entries;
    _setUnlocked(entries.length);
    return entries;
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
  }) {
    if (value == null) return delete(key: key);
    return _runVaultOrDirect(
      () async {
        final current = await _loadSingleVaultLocked();
        if (current[key] == value && _vaultPersisted) return;
        final next = Map<String, String>.of(current)..[key] = value;
        await _secure.write(key: _vaultKey, value: _encodeVault(next));
        _vaultCache = next;
        _vaultPersisted = true;
        _setUnlocked(next.length);
      },
      () =>
          _file?.write(key: key, value: value) ??
          _secure.write(key: key, value: value),
    );
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
  }) => _runVaultOrDirect(() async {
    final current = await _loadSingleVaultLocked();
    if (!current.containsKey(key)) return;
    final next = Map<String, String>.of(current)..remove(key);
    // Keep the empty vault item so macOS Keychain retains the Always Allow ACL.
    if (_vaultPersisted || next.isNotEmpty) {
      await _secure.write(key: _vaultKey, value: _encodeVault(next));
      _vaultPersisted = true;
    }
    _vaultCache = next;
    _setUnlocked(next.length);
  }, () => _file?.delete(key: key) ?? _secure.delete(key: key));

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _runVaultOrDirect(
    () async => (await _loadSingleVaultLocked()).containsKey(key),
    () async {
      final f = _file;
      if (f != null) return f.get(key) != null;
      return _secure.containsKey(key: key);
    },
  );

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _runVaultOrDirect(
    () async => Map<String, String>.of(await _loadSingleVaultLocked()),
    () async {
      final f = _file;
      if (f != null) return f.snapshot();
      return {...await _secure.readAll()}..remove(canaryKey);
    },
  );

  /// 加密档逐条删、留下暗号 —— 整份清掉的话,下次启动会被当成「被系统清过」。
  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _runVaultOrDirect(
    () async {
      final current = await _loadSingleVaultLocked();
      if (current.isEmpty) return;
      final next = <String, String>{};
      if (_vaultPersisted) {
        await _secure.write(key: _vaultKey, value: _encodeVault(next));
      }
      _vaultCache = next;
      _setUnlocked(0);
    },
    () async {
      final f = _file;
      if (f != null) return f.clear();
      for (final k in [...(await _secure.readAll()).keys]) {
        if (k != canaryKey) await _secure.delete(key: k);
      }
    },
  );
}
