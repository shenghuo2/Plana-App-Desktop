import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/secure_storage.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/widgets/endpoint_sheet.dart';

class _FlakyStorage extends FlutterSecureStorage {
  String? stored;
  bool failRead = false;
  bool failWrite = true;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failRead) throw StateError('secure storage unavailable');
    return stored;
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
  }) async {
    if (failWrite) throw StateError('secure storage unavailable');
    stored = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed endpoint write preserves the previous list and retries',
    () async {
      final storage = _FlakyStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      expect(await container.read(customEndpointsProvider.future), isEmpty);
      const endpoint = CustomEndpoint(
        id: 'test',
        name: 'Test',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'secret',
        model: 'model',
      );
      await expectLater(
        container.read(customEndpointsProvider.notifier).put(endpoint),
        throwsStateError,
      );
      expect(container.read(customEndpointsProvider).value, isEmpty);
      storage.failWrite = false;
      await container.read(customEndpointsProvider.notifier).put(endpoint);
      expect(container.read(customEndpointsProvider).value, [endpoint]);
      storage.failWrite = true;
      await expectLater(
        container.read(customEndpointsProvider.notifier).remove(endpoint.id),
        throwsStateError,
      );
      expect(container.read(customEndpointsProvider).value, [endpoint]);
      storage.failWrite = false;
      await container
          .read(customEndpointsProvider.notifier)
          .remove(endpoint.id);
      expect(container.read(customEndpointsProvider).value, isEmpty);
    },
  );

  test('failed read cannot replace stored endpoints', () async {
    final storage = _FlakyStorage()
      ..stored = '[{"id":"existing","apiKey":"secret","model":"old"}]'
      ..failRead = true
      ..failWrite = false;
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(customEndpointsProvider.future),
      throwsStateError,
    );
    await expectLater(
      container
          .read(customEndpointsProvider.notifier)
          .put(
            const CustomEndpoint(
              id: 'new',
              name: 'New',
              format: AgentApiFormat.openai,
              baseUrl: '',
              apiKey: 'key',
              model: 'model',
            ),
          ),
      throwsStateError,
    );
    expect(storage.stored, contains('existing'));
  });

  test('concurrent endpoint saves retain both edits', () async {
    final storage = _FlakyStorage()..failWrite = false;
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(customEndpointsProvider.future);
    CustomEndpoint endpoint(String id) => CustomEndpoint(
      id: id,
      name: id,
      format: AgentApiFormat.openai,
      baseUrl: '',
      apiKey: 'key',
      model: 'model',
    );
    await Future.wait([
      container.read(customEndpointsProvider.notifier).put(endpoint('one')),
      container.read(customEndpointsProvider.notifier).put(endpoint('two')),
    ]);
    expect(container.read(customEndpointsProvider).value?.map((e) => e.id), [
      'one',
      'two',
    ]);
  });

  testWidgets(
    'endpoint sheet stays open with entered values after failed save',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _FlakyStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await container.read(customEndpointsProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showEndpointSheet(context),
                  child: const Text('打开接口表单'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开接口表单'));
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(field('API Key'), 'secret');
      await tester.enterText(field('模型'), 'model');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请检查安全存储后重试'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('API Key')).controller?.text,
        'secret',
      );
      expect(container.read(customEndpointsProvider).value, isEmpty);

      storage.failWrite = false;
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('添加接口'), findsNothing);
      expect(
        container.read(customEndpointsProvider).value?.single.model,
        'model',
      );
    },
  );
}
