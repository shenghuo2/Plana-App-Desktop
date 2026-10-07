/// Persisted configuration for the external image push API.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/secure_storage.dart';
import '../store/app_stores.dart';
import '../store/prefs_store.dart';
import 'external_image_push_client.dart';

const kDefaultExternalImagePushSourceName = 'PlanaAPP';

const _endpointKey = 'external_image_push_endpoint';
const _sourceNameKey = 'external_image_push_source_name';
const _tokenKey = 'external_image_push_token';
const _autoFavoritesKey = 'external_image_push_favorite_auto_upload';

/// Independent of asynchronous credential loading so the favorite gesture and
/// action label always agree. Only future additions to favorites are uploaded.
final favoriteAutoUploadProvider =
    NotifierProvider<FavoriteAutoUploadNotifier, bool>(
      FavoriteAutoUploadNotifier.new,
    );

class FavoriteAutoUploadNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(prefsStoreProvider).get(_autoFavoritesKey) == 'true';

  Future<void> set(bool value) async {
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _autoFavoritesKey, value: value.toString());
    } catch (_) {
      throw const ExternalImagePushConfigException('保存收藏自动上传设置失败，请重试');
    }
    if (ref.mounted) state = value;
  }
}

/// Non-secret state safe to expose to widgets. The raw token never enters it.
class ExternalImagePushSettings {
  const ExternalImagePushSettings({
    required this.endpoint,
    required this.sourceName,
    required this.hasToken,
  });

  final String endpoint;
  final String sourceName;
  final bool hasToken;

  bool get hasValidEndpoint {
    if (endpoint.isEmpty) return false;
    try {
      externalImagePushAssetUri(endpoint);
      return true;
    } on ExternalImagePushException {
      return false;
    }
  }

  bool get isConfigured => hasToken && hasValidEndpoint;
}

/// Short-lived credentials retrieved only at the moment an upload begins.
class ExternalImagePushCredentials {
  const ExternalImagePushCredentials({
    required this.endpoint,
    required this.token,
    required this.sourceName,
  });

  final String endpoint;
  final String token;
  final String sourceName;
}

class ExternalImagePushConfigException implements Exception {
  const ExternalImagePushConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

final externalImagePushSettingsProvider =
    AsyncNotifierProvider<
      ExternalImagePushSettingsNotifier,
      ExternalImagePushSettings
    >(ExternalImagePushSettingsNotifier.new);

class ExternalImagePushSettingsNotifier
    extends AsyncNotifier<ExternalImagePushSettings> {
  PrefsStore get _prefs => ref.read(prefsStoreProvider);
  FlutterSecureStorage get _secureStorage => ref.read(secureStorageProvider);

  @override
  Future<ExternalImagePushSettings> build() async {
    final prefs = _prefs;
    final secure = _secureStorage;
    final endpoint = (await prefs.read(key: _endpointKey))?.trim() ?? '';
    final sourceName = _readSourceName(await prefs.read(key: _sourceNameKey));
    try {
      final token = await secure.read(key: _tokenKey);
      return ExternalImagePushSettings(
        endpoint: endpoint,
        sourceName: sourceName,
        hasToken: token != null && token.trim().isNotEmpty,
      );
    } catch (_) {
      return ExternalImagePushSettings(
        endpoint: endpoint,
        sourceName: sourceName,
        hasToken: false,
      );
    }
  }

  /// Saves the endpoint and source name. A null [token] deliberately means
  /// "keep the existing token" so an obscured form field cannot erase it.
  Future<void> save({
    required String endpoint,
    required String sourceName,
    String? token,
  }) async {
    final normalizedEndpoint = _normalizeEndpoint(endpoint);
    final normalizedSourceName = normalizeExternalImagePushSourceName(
      sourceName,
    );
    final cleanToken = token?.trim();
    if (cleanToken != null && cleanToken.isEmpty) {
      throw const ExternalImagePushConfigException('Token 不能为空');
    }

    final old = state.value;
    final prefs = _prefs;
    final secure = _secureStorage;
    try {
      if (cleanToken != null) {
        await secure.write(key: _tokenKey, value: cleanToken);
      }
      await prefs.write(key: _endpointKey, value: normalizedEndpoint);
      await prefs.write(key: _sourceNameKey, value: normalizedSourceName);
      if (!ref.mounted) return;
      state = AsyncData(
        ExternalImagePushSettings(
          endpoint: normalizedEndpoint,
          sourceName: normalizedSourceName,
          hasToken: cleanToken != null || (old?.hasToken ?? false),
        ),
      );
    } catch (_) {
      throw const ExternalImagePushConfigException('保存云存储配置失败,请重试');
    }
  }

  Future<void> clearToken() async {
    try {
      await _secureStorage.delete(key: _tokenKey);
    } catch (_) {
      throw const ExternalImagePushConfigException('清除 Token 失败,请重试');
    }
    if (!ref.mounted) return;
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        ExternalImagePushSettings(
          endpoint: current.endpoint,
          sourceName: current.sourceName,
          hasToken: false,
        ),
      );
    }
  }

  /// Returns a raw Token only to the upload path; never put this value in
  /// provider state, UI text, exceptions, or logs.
  Future<ExternalImagePushCredentials?> credentials() async {
    final current = state.value;
    if (current == null || !current.hasValidEndpoint || !current.hasToken) {
      return null;
    }
    try {
      final token = (await _secureStorage.read(key: _tokenKey))?.trim() ?? '';
      if (token.isEmpty) return null;
      return ExternalImagePushCredentials(
        endpoint: current.endpoint,
        token: token,
        sourceName: current.sourceName,
      );
    } catch (_) {
      return null;
    }
  }

  static String _normalizeEndpoint(String value) {
    final Uri uploadUri;
    try {
      uploadUri = externalImagePushAssetUri(value);
    } on ExternalImagePushException catch (e) {
      throw ExternalImagePushConfigException(e.message);
    }
    const suffix = '/api/v1/assets';
    var path = uploadUri.path;
    if (path.endsWith(suffix)) {
      path = path.substring(0, path.length - suffix.length);
    }
    return uploadUri.replace(path: path).toString();
  }

  static String _readSourceName(String? value) {
    try {
      return normalizeExternalImagePushSourceName(value ?? '');
    } on ExternalImagePushConfigException {
      return kDefaultExternalImagePushSourceName;
    }
  }
}

String normalizeExternalImagePushSourceName(String value) {
  final sourceName = value.trim().isEmpty
      ? kDefaultExternalImagePushSourceName
      : value.trim();
  if (sourceName.runes.length > 64 ||
      sourceName.runes.any((r) => r < 0x20 || r == 0x7f)) {
    throw const ExternalImagePushConfigException('来源名称需为 1 到 64 个非控制字符');
  }
  return sourceName;
}

/// Accepts the convenient `<token>:<source-name>` form some deployments hand
/// out, while keeping normal Bearer tokens intact. Only the documented `pmat_`
/// token family is split so an unrelated credential containing `:` is never
/// silently changed.
({String token, String? sourceName}) splitExternalImagePushTokenInput(
  String value,
) {
  final raw = value.trim();
  final colon = raw.lastIndexOf(':');
  if (!raw.startsWith('pmat_') || colon <= 5 || colon == raw.length - 1) {
    return (token: raw, sourceName: null);
  }
  final token = raw.substring(0, colon);
  final sourceName = raw.substring(colon + 1);
  if (token.contains(':')) return (token: raw, sourceName: null);
  try {
    return (
      token: token,
      sourceName: normalizeExternalImagePushSourceName(sourceName),
    );
  } on ExternalImagePushConfigException {
    return (token: raw, sourceName: null);
  }
}
