import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class DriveException implements Exception {
  const DriveException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class DriveConsentRequired extends DriveException {
  const DriveConsentRequired() : super('Google 授权已失效，请重新连接');
}

/// Credentials from the "Desktop app" JSON downloaded from Google Cloud.
class DriveDesktopClient {
  const DriveDesktopClient(this.id, this.secret);
  final String id;
  final String? secret;

  static DriveDesktopClient? fromBuild({
    String id = const String.fromEnvironment('PLANA_GOOGLE_DESKTOP_CLIENT_ID'),
    String secret = const String.fromEnvironment(
      'PLANA_GOOGLE_DESKTOP_CLIENT_SECRET',
    ),
  }) {
    if (id.trim().isEmpty) return null;
    return DriveDesktopClient.parse(
      DriveDesktopClient(id.trim(), secret.isEmpty ? null : secret).encode(),
    );
  }

  factory DriveDesktopClient.parse(String source) {
    final json = jsonDecode(source);
    final installed = json is Map ? json['installed'] : null;
    final id = installed is Map ? installed['client_id'] : null;
    if (id is! String ||
        !RegExp(
          r'^[a-zA-Z0-9._-]+\.apps\.googleusercontent\.com$',
        ).hasMatch(id)) {
      throw const FormatException('请选择 Google Cloud 导出的桌面应用客户端 JSON');
    }
    final secret = installed['client_secret'];
    if (secret != null && secret is! String) {
      throw const FormatException('无效的 Google 客户端配置');
    }
    return DriveDesktopClient(id, secret as String?);
  }

  String encode() => jsonEncode({
    'installed': {'client_id': id, 'client_secret': ?secret},
  });
}

const kDriveScope = 'https://www.googleapis.com/auth/drive.appdata';

typedef DriveGrant = ({String access, String? refresh, DateTime expires});

class DesktopDriveOAuth {
  DesktopDriveOAuth(this.httpClient, {this.openBrowser = _open});
  final http.Client httpClient;
  final Future<bool> Function(Uri) openBrowser;

  static Future<bool> _open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static String _nonce() {
    final random = Random.secure();
    return _b64(List.generate(32, (_) => random.nextInt(256)));
  }

  Future<DriveGrant?> authorize(
    DriveDesktopClient client, {
    String? loginHint,
  }) async {
    final verifier = _nonce();
    final state = _nonce();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/',
    );
    final result = Completer<String?>();
    final subscription = server.listen((request) async {
      final query = request.uri.queryParameters;
      final matches =
          request.method == 'GET' &&
          request.uri.path == '/' &&
          query['state'] == state &&
          (query.containsKey('error') || (query['code']?.isNotEmpty ?? false));
      final response = request.response;
      response.headers.contentType = ContentType(
        'text',
        'plain',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.statusCode = matches ? HttpStatus.ok : HttpStatus.badRequest;
      response.write(
        matches
            ? '可以关闭此页，返回 Plana。 You can now return to Plana.'
            : 'Invalid authorization response.',
      );
      try {
        await response.close();
      } on SocketException {
        // A browser may close the callback tab after receiving its headers.
      } finally {
        if (matches && !result.isCompleted) {
          final error = query['error'];
          if (error != null && error != 'access_denied') {
            result.completeError(const DriveException('Google 授权失败，请重新连接'));
          } else {
            result.complete(error == null ? query['code'] : null);
          }
        }
      }
    });
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': client.id,
        'redirect_uri': redirect.toString(),
        'response_type': 'code',
        'scope': kDriveScope,
        'state': state,
        'code_challenge': _b64(sha256.convert(ascii.encode(verifier)).bytes),
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': loginHint == null ? 'select_account consent' : 'consent',
        'login_hint': ?loginHint,
      });
      if (!await openBrowser(uri)) throw const DriveException('无法打开系统浏览器');
      final code = await result.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw const DriveException('Google 授权超时，请重新连接'),
      );
      if (code == null) return null;
      return exchange(client, {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirect.toString(),
        'code_verifier': verifier,
      });
    } finally {
      await server.close(force: true);
      await subscription.cancel();
    }
  }

  Future<DriveGrant> exchange(
    DriveDesktopClient client,
    Map<String, String> values,
  ) async {
    final response = await httpClient
        .post(
          Uri.https('oauth2.googleapis.com', '/token'),
          body: {
            'client_id': client.id,
            'client_secret': ?client.secret,
            ...values,
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      if (response.statusCode == 400 &&
          values['grant_type'] == 'refresh_token') {
        try {
          if (jsonDecode(response.body) case {'error': 'invalid_grant'}) {
            throw const DriveConsentRequired();
          }
        } on FormatException {
          // A proxy or temporary server error can return a non-JSON response.
        }
      }
      throw DriveException(
        'Google 授权失败，请检查桌面客户端配置或重新连接',
        status: response.statusCode,
      );
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map ||
        body['access_token'] is! String ||
        body['expires_in'] is! num ||
        (body['access_token'] as String).isEmpty) {
      throw const DriveException('Google 返回了无效的访问令牌');
    }
    return (
      access: body['access_token'] as String,
      refresh: body['refresh_token'] as String?,
      expires: DateTime.now().add(
        Duration(seconds: (body['expires_in'] as num).toInt()),
      ),
    );
  }

  Future<String> accountLabel(String access) async {
    try {
      final res = await httpClient
          .get(
            Uri.https('www.googleapis.com', '/drive/v3/about', {
              'fields': 'user(emailAddress)',
            }),
            headers: {'Authorization': 'Bearer $access'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final email = jsonDecode(
          utf8.decode(res.bodyBytes),
        )['user']?['emailAddress'];
        if (email is String && email.isNotEmpty) return email;
      }
    } catch (_) {}
    return 'Google';
  }

  Future<void> revoke(String token) => httpClient
      .post(
        Uri.https('oauth2.googleapis.com', '/revoke'),
        body: {'token': token},
      )
      .timeout(const Duration(seconds: 15))
      .then<void>((_) {});
}
