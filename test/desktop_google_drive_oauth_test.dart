import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:plana_app/core/net/google_drive.dart'
    show bundledDriveClientProvider, googleDriveAuthProvider;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/net/google_drive_oauth.dart';

const desktop = DriveDesktopClient(
  'example.apps.googleusercontent.com',
  'local-test',
);
void main() {
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
