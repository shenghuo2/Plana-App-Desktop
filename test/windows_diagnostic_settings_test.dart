import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/network_proxy.dart';
import 'package:plana_app/core/platform/desktop_directory.dart';
import 'package:plana_app/core/platform/windows_diagnostics.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/util/log.dart';
import 'package:plana_app/core/util/runtime_diagnostics.dart';
import 'package:plana_app/features/profile/widgets/diagnostic_settings.dart';
import 'package:plana_app/features/shell/shell_state.dart';

class _Folder extends DesktopDirectoryLauncher {
  String? opened;
  @override
  Future<void> open(
    Directory directory, {
    required bool Function() isCurrent,
  }) async {
    if (isCurrent()) opened = directory.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('plana/diagnostics');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory logs;
  late WindowsDiagnostics service;
  late bool nativeEnabled;
  late bool denyWrite;

  setUp(() {
    root = Directory.systemTemp.createTempSync('plana-diagnostic-settings-');
    logs = Directory('${root.path}/logs');
    service = WindowsDiagnostics();
    nativeEnabled = false;
    denyWrite = false;
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'status':
          return {'enabled': nativeEnabled, 'directory': logs.path};
        case 'setEnabled':
          if (denyWrite) {
            throw PlatformException(code: 'preference-write-failed');
          }
          nativeEnabled = call.arguments as bool;
          return null;
        case 'displayAdapters':
          return ['QA Graphics'];
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    RuntimeDiagnostics.current?.dispose();
    service.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'opt-in records safe events immediately and both settings survive restart',
    () async {
      await service.initialize();
      expect(service.enabled, isFalse);
      expect(logs.existsSync(), isFalse);
      await service.setEnabled(true);
      final log = RuntimeDiagnostics.current!;
      final tabs = ProviderContainer();
      addTearDown(tabs.dispose);
      tabs.read(shellIndexProvider.notifier).select(kTabGallery);
      expect(
        log.file.readAsStringSync(),
        contains('"event":"tab-selected","detail":"gallery"'),
      );
      logi('private-prompt-canary', diagnosticEvent: 'bot-task-failed');
      log.error(
        'test-failure',
        StateError('private-cookie-canary'),
        StackTrace.fromString(
          '#0 method (package:plana_app/example.dart:11:2)\nC:/private-user-name/path',
        ),
      );
      expect(log.file.readAsStringSync(), contains('bot-task-failed'));
      expect(log.file.readAsStringSync(), contains('example.dart:11:2'));
      expect(log.file.readAsStringSync(), isNot(contains('private-')));
      log.dispose();
      final next = WindowsDiagnostics();
      addTearDown(next.dispose);
      await next.initialize();
      expect(next.enabled, isTrue);
      final last = RuntimeDiagnostics.current!.file;
      await next.setEnabled(false);
      final end = last.readAsStringSync();
      logi('after switch', diagnosticEvent: 'event-after-switch');
      expect(last.readAsStringSync(), end);
      expect(RuntimeDiagnostics.current, isNull);
      await service.initialize();
      expect(service.enabled, isFalse);
    },
  );

  test('failed preference write leaves the Dart writer off', () async {
    denyWrite = true;
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<PlatformException>()),
    );
    expect(service.enabled, isFalse);
    expect(service.busy, isFalse);
    expect(RuntimeDiagnostics.current, isNull);
    expect(logs.existsSync(), isFalse);
  });

  test('unwritable text directory rolls back the runner preference', () async {
    File(logs.path).writeAsStringSync('occupied');
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<FileSystemException>()),
    );
    expect(nativeEnabled, isFalse);
    expect(service.enabled, isFalse);
    expect(RuntimeDiagnostics.current, isNull);
  });

  testWidgets(
    'About controls open the profile folder and copy only service status',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'auth_mode': 'bot',
        'bot_session':
            '{"sessionId":"private-cookie-canary","botUserId":"private-user-canary"}',
        'assistant_endpoints':
            '[{"id":"a","apiKey":"private-key-canary","baseUrl":"https://private-address.test"},{"id":"b","enabled":false}]',
      });
      String? clipboard;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final launcher = _Folder();
      final stores = AppStores.ephemeral();
      await tester.runAsync(
        () => stores.prefs.write(key: 'auth_mode', value: 'bot'),
      );
      addTearDown(() async {
        stores.flushNow();
        await stores.prefs.idle;
        await stores.desktopOutput.root.parent.delete(recursive: true);
      });
      await service.initialize();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            windowsDiagnosticsProvider.overrideWithValue(service),
            desktopDirectoryLauncherProvider.overrideWithValue(launcher),
            networkProxyRuntimeProvider.overrideWithValue(
              NetworkProxyOverrides(const NetworkProxySettings()),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: DiagnosticSettings())),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      expect(launcher.opened, logs.path);
      expect(service.enabled, isFalse);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.text('复制'));
      await tester.pump();
      expect(clipboard, contains('显卡 = QA Graphics'));
      expect(clipboard, contains('账号接入方式 = Bot'));
      expect(clipboard, contains('Bot 本地授权 = 已配置'));
      expect(clipboard, contains('已启用的 AI 接口数量 = 1'));
      expect(clipboard, contains('写入日志文件 = 开'));
      expect(clipboard, isNot(contains('private-')));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(RuntimeDiagnostics.current, isNull);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );
}
