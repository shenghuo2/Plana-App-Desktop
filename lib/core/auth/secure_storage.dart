import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全局唯一的加密存储**配置**(令牌 / bot 会话 / 后端地址 等设置共用)。
///
/// **任何读写点都必须用这个常量或下面的 provider,不要自己 `new` 一份。**
/// 现在各处配置相同,看不出差别;但一旦给它加上 `AndroidOptions`
/// (`resetOnError: false` 等,见 S1A-02),自建的那份会是**唯一没跟上的**,
/// 而且编译器和 lint 都不会提醒 —— 表现为「某一项设置莫名其妙被清空」。
///
/// 直接暴露常量是给 `main()` 用的:`loadThemeSettings()` 在 ProviderScope
/// 建立之前就要读盘,拿不到 ref。
///
/// macOS 的公开构建使用 ad-hoc 签名,不能携带 Data Protection Keychain 所需的
/// Keychain Sharing entitlement。这里显式改走传统登录钥匙串:内容仍由 macOS
/// Keychain 加密保管,但不再要求 Developer ID 或 provisioning profile。
const kMacOsSecureStorageService = 'com.sora214.plana.app.secure-storage';
const kSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(
    accountName: kMacOsSecureStorageService,
    usesDataProtectionKeychain: false,
  ),
);

/// CI 启动打包后的 App 时使用。测试值不是凭据,写入后会立即删除。
const kMacOsKeychainSmokeTestEnvironment = 'PLANA_MACOS_KEYCHAIN_SMOKE_TEST';

Future<void> runMacOsKeychainSmokeTest() async {
  const key = '__plana_macos_keychain_smoke_test__';
  final value = DateTime.now().microsecondsSinceEpoch.toString();
  await kSecureStorage.write(key: key, value: value);
  try {
    final stored = await kSecureStorage.read(key: key);
    if (stored != value) {
      throw StateError('macOS Keychain returned an unexpected value');
    }
  } finally {
    await kSecureStorage.delete(key: key);
  }
}

/// ProviderScope 内的读写统一走这里。
final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => kSecureStorage,
);
