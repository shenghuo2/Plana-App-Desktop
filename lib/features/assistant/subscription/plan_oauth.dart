import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:url_launcher/url_launcher.dart';

const planResource = 'https://api.openai.com/v1';
const _issuer = 'https://auth.openai.com';
const _dynamicClient = 'dynamic_agent_client';
const _permission = 'chatgpt.tokens.use.direct';
const _scope =
    'openid profile email offline_access resource.invoke $_permission';

class PlanAuthException implements Exception {
  const PlanAuthException(this.message, {this.expired = false});
  final String message;
  final bool expired;
  @override
  String toString() => message;
}

String _randomUrl() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

String newPlanHostId() {
  final bytes = base64Url
      .decode(base64Url.normalize(_randomUrl()))
      .take(16)
      .toList();
  bytes[6] = bytes[6] & 15 | 64;
  bytes[8] = bytes[8] & 63 | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class PlanGrant {
  const PlanGrant(
    this.access,
    this.refresh,
    this.idToken,
    this.expires,
    this.scopes,
  );
  final String access, refresh, idToken;
  final int expires;
  final String scopes;

  factory PlanGrant.fromJson(Map json) => PlanGrant(
    json['access'] as String,
    json['refresh'] as String,
    json['idToken'] as String,
    json['expires'] as int,
    json['scopes'] as String,
  );
  Map<String, Object> toJson() => {
    'access': access,
    'refresh': refresh,
    'idToken': idToken,
    'expires': expires,
    'scopes': scopes,
  };
}

typedef PlanIdentity = ({String subject, String email});
typedef PlanLogin = ({String clientId, PlanIdentity identity, PlanGrant grant});

class PlanOAuth {
  PlanOAuth(this.client, {this.openBrowser = _open});
  final http.Client client;
  final Future<bool> Function(Uri) openBrowser;
  static Future<bool> _open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<PlanLogin?> authorize({
    required String host,
    String? existingClient,
    String? subject,
    String? email,
    String? hint,
    Future<void>? cancel,
  }) async {
    final state = _randomUrl(), nonce = _randomUrl(), verifier = _randomUrl();
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = Uri.http('127.0.0.1:${listener.port}', '/auth/callback');
    final callback = Completer<Map<String, String>?>();
    var cancelled = false;
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          cancelled = true;
          if (!callback.isCompleted) callback.complete(null);
        }),
      );
    }
    final sub = listener.listen((req) async {
      final q = req.uri.queryParameters;
      final ok =
          req.method == 'GET' &&
          req.uri.path == redirect.path &&
          q['state'] == state &&
          (q.containsKey('error') || (q['code']?.isNotEmpty ?? false));
      req.response
        ..statusCode = ok ? 200 : 400
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..headers.set('cache-control', 'no-store')
        ..write(
          ok
              ? '可以关闭此页，返回 Plana。 You can return to Plana.'
              : 'Invalid authorization response.',
        );
      try {
        await req.response.close();
      } on SocketException {
        /* The browser may close first. */
      }
      if (ok && !callback.isCompleted) callback.complete(q);
    });
    try {
      final auth = Uri.parse('$_issuer/api/accounts/authorize').replace(
        queryParameters: {
          'client_id': existingClient ?? _dynamicClient,
          if (existingClient == null) 'agent_name_hint': 'Plana',
          'ext_agent_host_id': host,
          'response_type': 'code',
          'redirect_uri': redirect.toString(),
          'scope': _scope,
          'resource': planResource,
          'state': state,
          'nonce': nonce,
          'code_challenge_method': 'S256',
          'code_challenge': base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', ''),
          if (existingClient != null && hint != null) 'id_token_hint': hint,
          if (existingClient != null && email != null && email.isNotEmpty)
            'login_hint': email,
        },
      );
      try {
        if (!await openBrowser(auth)) {
          throw const PlanAuthException('无法打开系统浏览器');
        }
      } on Exception {
        // Browser launch errors can include the URL and its private id_token_hint.
        throw const PlanAuthException('无法打开系统浏览器');
      }
      final q = await callback.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw const PlanAuthException('登录已超时，请再次登录'),
      );
      if (q == null || q['error'] == 'access_denied') return null;
      if (q.containsKey('error')) throw const PlanAuthException('OpenAI 登录未完成');
      final id = q['client_id'] ?? existingClient;
      if (id == null ||
          id.isEmpty ||
          id == _dynamicClient ||
          (existingClient != null && id != existingClient)) {
        throw const PlanAuthException('OpenAI 返回的工作区注册信息无效');
      }
      final json = await _exchange({
        'grant_type': 'authorization_code',
        'client_id': id,
        'code': q['code']!,
        'code_verifier': verifier,
        'redirect_uri': redirect.toString(),
      });
      final grant = _grant(json);
      final identity = await verifyIdentity(grant.idToken, id, nonce: nonce);
      if (subject != null && identity.subject != subject) {
        throw const PlanAuthException('登录身份与所选账户不一致');
      }
      return cancelled
          ? null
          : (clientId: id, identity: identity, grant: grant);
    } finally {
      await listener.close(force: true);
      await sub.cancel();
    }
  }

  Future<PlanIdentity> verifyIdentity(
    String token,
    String audience, {
    String? nonce,
  }) async {
    const invalid = PlanAuthException('无法验证 OpenAI 登录身份');
    try {
      final parts = token.split('.');
      if (parts.length != 3) throw invalid;
      Map part(int i) =>
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[i]))),
              )
              as Map;
      final hdr = part(0);
      if (hdr['alg'] != 'RS256' || hdr['kid'] is! String) throw invalid;
      final response = await client
          .get(Uri.parse('$_issuer/.well-known/jwks.json'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw invalid;
      final keys = jsonDecode(utf8.decode(response.bodyBytes))['keys'] as List;
      final key = keys
          .whereType<Map<String, dynamic>>()
          .where(
            (k) =>
                k['kid'] == hdr['kid'] &&
                k['kty'] == 'RSA' &&
                (k['use'] == null || k['use'] == 'sig') &&
                (k['alg'] == null || k['alg'] == 'RS256'),
          )
          .single;
      if (!JsonWebKey.fromJson(key).verify(
        ascii.encode('${parts[0]}.${parts[1]}'),
        base64Url.decode(base64Url.normalize(parts[2])),
        algorithm: 'RS256',
      )) {
        throw invalid;
      }
      final claims = part(1),
          now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final aud = claims['aud'];
      final audiences = aud is List ? aud : [aud];
      if (claims['iss'] != _issuer ||
          !audiences.contains(audience) ||
          ((audiences.length > 1 || claims.containsKey('azp')) &&
              claims['azp'] != audience) ||
          claims['exp'] is! num ||
          claims['exp'] <= now ||
          (claims['nbf'] is num && claims['nbf'] > now + 30) ||
          (nonce != null && claims['nonce'] != nonce) ||
          claims['sub'] is! String ||
          (claims['sub'] as String).isEmpty) {
        throw invalid;
      }
      return (
        subject: claims['sub'] as String,
        email: claims['email'] is String ? claims['email'] as String : '',
      );
    } catch (_) {
      throw invalid;
    }
  }

  Future<http.Response> _postForm(
    String endpoint,
    Map<String, String> fields,
    Duration timeout,
  ) {
    final request =
        http.Request('POST', Uri.parse('$_issuer/api/accounts/oauth/$endpoint'))
          ..followRedirects = false
          ..bodyFields = fields;
    return client.send(request).then(http.Response.fromStream).timeout(timeout);
  }

  Future<Map> _exchange(Map<String, String> fields) async {
    final response = await _postForm('token', {
      ...fields,
      'resource': planResource,
    }, const Duration(seconds: 25));
    if (response.statusCode != 200) {
      String? code;
      try {
        final body = jsonDecode(response.body);
        code = body['error'] is Map ? body['error']['code'] : body['error'];
      } catch (_) {}
      final terminal =
          fields['grant_type'] == 'refresh_token' &&
          const {
            'invalid_grant',
            'invalid_refresh_token',
            'token_expired',
            'refresh_token_expired',
            'refresh_token_invalidated',
            'refresh_token_reused',
          }.contains(code);
      throw PlanAuthException(
        terminal
            ? '授权已失效，请重新登录此工作区'
            : 'OpenAI 授权失败（HTTP ${response.statusCode}）',
        expired: terminal,
      );
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map) return body;
    } on FormatException {
      /* Token response contents must stay out of diagnostics. */
    }
    throw const PlanAuthException('OpenAI 授权响应无法读取');
  }

  PlanGrant _grant(Map json, [PlanGrant? previous]) {
    final scopes = json['scope'] ?? previous?.scopes;
    if (scopes is! String || !scopes.split(' ').contains(_permission)) {
      throw const PlanAuthException(
        '此工作区未授权 Plana 使用 ChatGPT 套餐',
        expired: true,
      );
    }
    final id = json['id_token'] ?? previous?.idToken;
    final access = json['access_token'],
        refresh = json['refresh_token'],
        ttl = json['expires_in'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty ||
        id is! String ||
        id.isEmpty ||
        ttl is! int ||
        ttl <= 0 ||
        json['token_type']?.toString().toLowerCase() != 'bearer') {
      throw const PlanAuthException('OpenAI 授权信息不完整');
    }
    return PlanGrant(
      access,
      refresh,
      id,
      DateTime.now().millisecondsSinceEpoch + ttl * 1000,
      scopes,
    );
  }

  Future<PlanGrant> renew(String id, String subject, PlanGrant current) async {
    final data = await _exchange({
      'grant_type': 'refresh_token',
      'client_id': id,
      'refresh_token': current.refresh,
    });
    final next = _grant(data, current);
    if (next.idToken != current.idToken &&
        (await verifyIdentity(next.idToken, id)).subject != subject) {
      throw const PlanAuthException('刷新授权时账户发生变化，请重新登录', expired: true);
    }
    return next;
  }

  Future<bool> revoke(String id, String refresh) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _postForm('revoke', {
          'token': refresh,
          'token_type_hint': 'refresh_token',
          'client_id': id,
        }, const Duration(seconds: 8));
        if (response.statusCode == 200) return true;
        if (response.statusCode < 500) return false;
      } on Exception {
        /* Retry a transient network failure once. */
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    return false;
  }
}
