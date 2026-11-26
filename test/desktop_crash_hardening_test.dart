import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/desktop/desktop_album_reorder_grid.dart';
import 'package:plana_app/features/profile/manual/user_manual_entry.dart';
import 'package:plana_app/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const manualChannel = MethodChannel('plana/user_manual');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  testWidgets('离线手册通道缺失时关闭清理不抛未捕获异常且正常弹出失败提示', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('plana_manual_err');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return '${tempDir.path}/support';
      }
      if (call.method == 'getApplicationCacheDirectory') {
        return '${tempDir.path}/cache';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(manualChannel, (call) async {
      throw MissingPluginException('No implementation for ${call.method}');
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(manualChannel, null);
    });

    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: UserManualEntry()),
      ),
    );
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byType(UserManualEntry));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('无法打开使用手册'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离线手册关闭后迟到或畸形原生请求返回错误信封而非崩溃', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('plana_manual_req');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return '${tempDir.path}/support';
      }
      if (call.method == 'getApplicationCacheDirectory') {
        return '${tempDir.path}/cache';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(manualChannel, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(manualChannel, null);
    });

    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: UserManualEntry()),
      ),
    );
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byType(UserManualEntry));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);

    Future<Map<String, dynamic>?> sendRequest(Object? args) async {
      ByteData? reply;
      await tester.runAsync(() async {
        await messenger.handlePlatformMessage(
          manualChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('request', args),
          ),
          (data) => reply = data,
        );
      });
      if (reply == null) return null;
      final decoded =
          const StandardMethodCodec().decodeEnvelope(reply!) as String;
      return jsonDecode(decoded) as Map<String, dynamic>;
    }

    final badArgs = await sendRequest(123);
    expect(badArgs?['error'], '无法识别手册请求。');

    final badJson = await sendRequest('{broken');
    expect(badJson?['error'], isA<String>());

    final closeReply = await sendRequest(
      jsonEncode({'id': 'c1', 'method': 'back'}),
    );
    expect(closeReply?['id'], 'c1');
    expect(closeReply?.containsKey('error'), isFalse);

    final lateReply = await sendRequest(
      jsonEncode({'id': 'late1', 'method': 'load'}),
    );
    expect(lateReply, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面相册拖拽重排在保存失败时不泄露未捕获异步异常且恢复可拖拽状态', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: DesktopAlbumReorderGrid(
              ids: const [null, 'album-a', 'album-b'],
              feel: GalleryDragFeel.crisp,
              tile: (id) => SizedBox.expand(
                child: ColoredBox(
                  color: Colors.blueGrey,
                  child: Center(child: Text(id ?? 'all')),
                ),
              ),
              onReorder: (_, _, _) async {
                calls++;
                throw StateError('disk write failed');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final a = tester.getCenter(find.text('album-a'));
    final b = tester.getCenter(find.text('album-b'));
    final gesture = await tester.startGesture(a, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    await gesture.moveTo(b);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
