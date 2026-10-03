import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/secure_storage.dart';

void main() {
  test('macOS ad-hoc builds use the classic login Keychain', () {
    final options = kSecureStorage.mOptions as MacOsOptions;

    expect(options.accountName, kMacOsSecureStorageService);
    expect(options.groupId, isNull);
    expect(options.synchronizable, isFalse);
    expect(options.usesDataProtectionKeychain, isFalse);
  });
}
