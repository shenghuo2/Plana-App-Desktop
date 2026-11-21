import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:plana_app/core/net/google_drive.dart'
    show
        bundledDriveClientProvider,
        desktopDriveOAuthProvider,
        googleDriveAuthProvider;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/net/google_drive_oauth.dart';

const desktop = DriveDesktopClient(
  'example.apps.googleusercontent.com',
  'local-test',
);

class _Accounts extends DesktopDriveOAuth {
  _Accounts()
    : super(MockClient((_) async => throw StateError('Unexpected request')));

  final browsers = <({String id, String? hint})>[];
  final refreshes = <({String id, String? token})>[];
  final revoked = <String>[];
  String email = 'artist@example.test';
  bool expired = false;
  bool cancel = false;
  Completer<void>? opened;
  Completer<void>? waiting;

  @override
  Future<DriveGrant?> authorize(
    DriveDesktopClient client, {
    String? loginHint,
  }) async {
    browsers.add((id: client.id, hint: loginHint));
    opened?.complete();
    if (waiting case final gate?) await gate.future;
    return cancel ? null : _grant(refresh: 'new-refresh');
  }

  DriveGrant _grant({String? refresh}) => (
    access: 'new-access',
    refresh: refresh,
    expires: DateTime.now().add(const Duration(hours: 1)),
  );

  @override
  Future<DriveGrant> exchange(
    DriveDesktopClient client,
    Map<String, String> values,
  ) async {
    refreshes.add((id: client.id, token: values['refresh_token']));
    if (expired) throw const DriveConsentRequired();
    return _grant();
  }

  @override
  Future<String> accountLabel(String access) async => email;

  @override
  Future<void> revoke(String token) async => revoked.add(token);
}

ProviderContainer _app(
  AppStores stores,
  _Accounts accounts, {
  DriveDesktopClient? bundled = desktop,
}) {
  final app = ProviderContainer(
    overrides: [
      appStoresProvider.overrideWithValue(stores),
      bundledDriveClientProvider.overrideWithValue(bundled),
      desktopDriveOAuthProvider.overrideWithValue(accounts),
    ],
  );
  addTearDown(app.dispose);
  return app;
}

void main() {
  const personal = DriveDesktopClient(
    'personal.apps.googleusercontent.com',
    'personal-test',
  );

  test(
    'upgrading defaults to the upstream project without using or revoking an old grant',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'desktop_google_drive_client': personal.encode(),
        'desktop_google_drive_authorized_client': personal.encode(),
        'desktop_google_drive_refresh': 'old-private-refresh',
      });
      final stores = AppStores.ephemeral();
      await stores.prefs.write(
        key: 'google_drive_email',
        value: 'old@example.test',
      );
      final accounts = _Accounts()..cancel = true;
      final app = _app(stores, accounts);
      final auth = app.read(googleDriveAuthProvider.notifier);
      expect(app.read(googleDriveAuthProvider), isNull);
      await expectLater(
        auth.token(interactive: true),
        throwsA(isA<DriveException>()),
      );
      expect(await auth.connect(), isFalse);
      expect(accounts.browsers.single, (id: desktop.id, hint: null));
      expect(accounts.refreshes, isEmpty);
      expect(accounts.revoked, isEmpty);

      accounts.cancel = false;
      expect(await auth.connect(), isTrue);
      expect(app.read(googleDriveAuthProvider), accounts.email);
      final reopened = _app(stores, accounts);
      expect(reopened.read(googleDriveAuthProvider), accounts.email);
      expect(
        await reopened.read(googleDriveAuthProvider.notifier).token(),
        'new-access',
      );
      expect(accounts.refreshes.single, (id: desktop.id, token: 'new-refresh'));

      final changed = _app(stores, accounts, bundled: personal);
      expect(changed.read(googleDriveAuthProvider), isNull);
      await expectLater(
        changed.read(googleDriveAuthProvider.notifier).token(),
        throwsA(isA<DriveException>()),
      );
      expect(accounts.refreshes, hasLength(1));
    },
  );

  test(
    'an explicit personal selection persists until choosing the bundled client again',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final stores = AppStores.ephemeral();
      final accounts = _Accounts();
      final app = _app(stores, accounts);
      final auth = app.read(googleDriveAuthProvider.notifier);
      await auth.configure(personal.encode());
      await auth.connect();
      expect(accounts.browsers.single.id, personal.id);
      final reopened = _app(stores, accounts);
      expect(reopened.read(googleDriveAuthProvider), accounts.email);
      final restored = reopened.read(googleDriveAuthProvider.notifier);
      await restored.disconnect();
      expect(accounts.revoked, ['new-refresh']);
      await restored.useBundledClient();
      await restored.connect();
      expect(accounts.browsers.last.id, desktop.id);
    },
  );

  test(
    'expired consent is silent in background and foreground requests share one account-bound prompt',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final stores = AppStores.ephemeral();
      final accounts = _Accounts();
      await _app(
        stores,
        accounts,
      ).read(googleDriveAuthProvider.notifier).connect();
      final app = _app(stores, accounts);
      final auth = app.read(googleDriveAuthProvider.notifier);
      accounts.expired = true;
      await expectLater(auth.token(), throwsA(isA<DriveConsentRequired>()));
      expect(accounts.browsers, hasLength(1));
      accounts.cancel = true;
      await expectLater(
        auth.token(interactive: true),
        throwsA(
          isA<DriveException>().having(
            (e) => e.message,
            'message',
            contains('已取消'),
          ),
        ),
      );
      expect(app.read(googleDriveAuthProvider), accounts.email);
      accounts.cancel = false;
      final connectedEmail = accounts.email;
      accounts.email = 'someone-else@example.test';
      await expectLater(
        auth.token(interactive: true),
        throwsA(
          isA<DriveException>().having(
            (e) => e.message,
            'message',
            contains('原先连接'),
          ),
        ),
      );
      expect(app.read(googleDriveAuthProvider), connectedEmail);
      accounts.email = connectedEmail;
      final count = accounts.browsers.length;
      expect(
        await Future.wait([
          auth.token(interactive: true),
          auth.token(interactive: true),
        ]),
        ['new-access', 'new-access'],
      );
      expect(accounts.browsers.length, count + 1);
      expect(accounts.browsers.last, (id: desktop.id, hint: connectedEmail));
    },
  );

  test(
    'a pending Google consent cannot reconnect a disconnected account',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final stores = AppStores.ephemeral();
      final accounts = _Accounts();
      await _app(
        stores,
        accounts,
      ).read(googleDriveAuthProvider.notifier).connect();
      final app = _app(stores, accounts);
      final auth = app.read(googleDriveAuthProvider.notifier);
      accounts.expired = true;
      final opened = accounts.opened = Completer<void>();
      final gate = accounts.waiting = Completer<void>();
      final consent = expectLater(
        auth.token(interactive: true),
        throwsA(isA<DriveException>()),
      );
      await opened.future.timeout(const Duration(seconds: 5));
      await auth.disconnect();
      gate.complete();
      await consent;
      expect(app.read(googleDriveAuthProvider), isNull);
      expect(_app(stores, accounts).read(googleDriveAuthProvider), isNull);
    },
  );

  test('only a revoked refresh grant requests new consent', () async {
    final values = {'grant_type': 'refresh_token', 'refresh_token': 'example'};
    DesktopDriveOAuth endpoint(int status, String body) =>
        DesktopDriveOAuth(MockClient((_) async => http.Response(body, status)));
    await expectLater(
      endpoint(400, '{"error":"invalid_grant"}').exchange(desktop, values),
      throwsA(isA<DriveConsentRequired>()),
    );
    for (final api in [
      endpoint(503, 'temporary'),
      endpoint(400, '{"error":"invalid_client"}'),
      endpoint(400, 'not JSON'),
    ]) {
      await expectLater(
        api.exchange(desktop, values),
        throwsA(
          isA<DriveException>().having(
            (e) => e is DriveConsentRequired,
            'prompts',
            isFalse,
          ),
        ),
      );
    }
  });

  test(
    'a build can supply a Google desktop client without a per-user import',
    () {
      expect(DriveDesktopClient.fromBuild(id: '', secret: ''), isNull);
      final client = DriveDesktopClient.fromBuild(
        id: desktop.id,
        secret: 'desktop-value',
      )!;
      expect(client.id, desktop.id);
      expect(client.secret, 'desktop-value');
      expect(
        () => DriveDesktopClient.fromBuild(id: 'not-a-google-client'),
        throwsFormatException,
      );
    },
  );

  test(
    'an empty account store reports the missing desktop registration',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final app = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          bundledDriveClientProvider.overrideWithValue(null),
        ],
      );
      addTearDown(app.dispose);
      final auth = app.read(googleDriveAuthProvider.notifier);
      expect(await auth.hasClient(), isFalse);
      await expectLater(
        auth.connect(),
        throwsA(
          isA<DriveException>().having(
            (e) => e.message,
            'configuration notice',
            contains('尚未配置 Google 登录'),
          ),
        ),
      );
    },
  );

  test('desktop configuration round trips and rejects a web client', () {
    final value = DriveDesktopClient.parse(desktop.encode());
    expect(value.id, desktop.id);
    expect(value.secret, desktop.secret);
    expect(
      () => DriveDesktopClient.parse(
        jsonEncode({
          'web': {'client_id': desktop.id},
        }),
      ),
      throwsFormatException,
    );
  });

  test(
    'browser callback requires matching state and exchanges a PKCE code',
    () async {
      late Uri authorization;
      final exchange = MockClient((request) async {
        expect(request.url.toString(), 'https://oauth2.googleapis.com/token');
        final body = request.bodyFields;
        expect(body['grant_type'], 'authorization_code');
        expect(body['code'], 'unit-code');
        expect(
          body['redirect_uri'],
          authorization.queryParameters['redirect_uri'],
        );
        final digest = sha256
            .convert(ascii.encode(body['code_verifier']!))
            .bytes;
        expect(
          base64Url.encode(digest).replaceAll('=', ''),
          authorization.queryParameters['code_challenge'],
        );
        return http.Response(
          jsonEncode({
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_in': 3600,
          }),
          200,
        );
      });
      final browser = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => browser.close(force: true));
      final oauth = DesktopDriveOAuth(
        exchange,
        openBrowser: (uri) async {
          authorization = uri;
          expect(uri.host, 'accounts.google.com');
          expect(uri.queryParameters['scope'], kDriveScope);
          expect(uri.queryParameters['code_challenge_method'], 'S256');
          final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          expect(redirect.host, '127.0.0.1');
          for (final state in ['wrong-state', uri.queryParameters['state']!]) {
            final req = await browser.getUrl(
              redirect.replace(
                queryParameters: {'code': 'unit-code', 'state': state},
              ),
            );
            final res = await req.close();
            expect(res.statusCode, state == 'wrong-state' ? 400 : 200);
            await res.drain<void>();
          }
          return true;
        },
      );
      final grant = await oauth.authorize(desktop);
      expect(grant?.refresh, 'refresh');
    },
  );

  test('user cancellation does not exchange a code', () async {
    final browser = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => browser.close(force: true));
    final oauth = DesktopDriveOAuth(
      MockClient((_) => throw StateError('unexpected token exchange')),
      openBrowser: (uri) async {
        final cb = Uri.parse(uri.queryParameters['redirect_uri']!);
        final req = await browser.getUrl(
          cb.replace(
            queryParameters: {
              'error': 'access_denied',
              'state': uri.queryParameters['state']!,
            },
          ),
        );
        await (await req.close()).drain<void>();
        return true;
      },
    );
    expect(await oauth.authorize(desktop), isNull);
  });
}
