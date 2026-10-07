import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plana_app/core/net/external_image_push_client.dart';
import 'package:plana_app/core/net/external_image_push_config.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/external_image_push.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/profile/cloud_storage_page.dart';
import 'package:plana_app/features/shell/desktop_task_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late ResultImage image;
  late Completer<http.StreamedResponse> gate;
  late int calls;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('plana_remote_ui');
    stores = await AppStores.open(rootOverride: root);
    gate = Completer<http.StreamedResponse>();
    calls = 0;
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        externalImagePushClientProvider.overrideWithValue(
          ExternalImagePushClient(
            requestSender: (_) {
              calls++;
              return gate.future;
            },
          ),
        ),
      ],
    );
    await container.read(externalImagePushSettingsProvider.future);
    await container
        .read(externalImagePushSettingsProvider.notifier)
        .save(
          endpoint: 'https://images.example',
          sourceName: 'PlanaAPP',
          token: 'test-token',
        );
    image = container
        .read(galleryProvider.notifier)
        .addResult(
          bytes: File('assets/app_icon.png').readAsBytesSync(),
          width: 512,
          height: 512,
          seed: 7,
        );
    await stores.flushForExit();
  });
  tearDown(() async {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
  }

  Future<void> completeUpload(
    WidgetTester tester, {
    bool failure = false,
  }) async {
    expect(
      container.read(externalImagePushUploadsProvider).pending,
      contains(image.id),
    );
    await tester.runAsync(() async {
      gate.complete(
        http.StreamedResponse(
          Stream.value(
            utf8.encode(
              failure
                  ? '{"error":{"message":"暂时不可用"}}'
                  : '{"id":"asset-1","deduplicated":false}',
            ),
          ),
          failure ? 503 : 201,
        ),
      );
    });
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (container
        .read(externalImagePushUploadsProvider)
        .pending
        .contains(image.id)) {
      if (DateTime.now().isAfter(deadline)) fail('Upload did not settle');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    var flushed = false;
    await tester.runAsync(() async {
      unawaited(
        stores.flushForExit().then((_) {
          flushed = true;
        }),
      );
    });
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!flushed) {
      if (DateTime.now().isAfter(deadline)) fail('Stores did not settle');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump();
    }
  }

  testWidgets('画布按钮默认远端上传,开启后替换为收藏且收藏状态实时变化', (tester) async {
    await mount(
      tester,
      ResultActions(result: image, canvasBar: CanvasActionBar.top),
    );
    expect(key('image-remote-upload-action'), findsOneWidget);
    expect(key('image-favorite-action'), findsNothing);
    await tester.runAsync(
      () => container.read(favoriteAutoUploadProvider.notifier).set(true),
    );
    await tester.pump();
    expect(key('image-remote-upload-action'), findsNothing);
    expect(key('image-favorite-action'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    await tester.runAsync(() => tester.tap(key('image-favorite-action')));
    expect(container.read(galleryProvider).selected?.favorite, isTrue);
    await completeUpload(tester);
    expect(calls, 1);
    expect(find.text('已收藏'), findsOneWidget);
    await tester.runAsync(() => tester.tap(key('image-favorite-action')));
    await tester.pump();
    expect(container.read(galleryProvider).selected?.favorite, isFalse);
    expect(calls, 1);
    await finish(tester);
  });

  testWidgets('看图浮层同样显示远端按钮,手动上传不修改收藏', (tester) async {
    await mount(tester, ResultActions(result: image, detailsPanel: true));
    expect(key('image-remote-upload-action'), findsOneWidget);
    await tester.runAsync(() => tester.tap(key('image-remote-upload-action')));
    await tester.pump();
    expect(find.text('上传中'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(key('image-remote-upload-action'))
          .onPressed,
      isNull,
    );
    await completeUpload(tester);
    expect(calls, 1);
    expect(container.read(galleryProvider).selected?.favorite, isFalse);
    await finish(tester);
  });

  testWidgets('配置页收藏开关落盘,已存 Token 不回填输入框,无效 URL 有提示', (tester) async {
    await mount(tester, const CloudStoragePage());
    expect(
      tester.widget<TextField>(key('remote-token-input')).controller?.text,
      isEmpty,
    );
    expect(
      tester.widget<TextField>(key('remote-token-input')).obscureText,
      isTrue,
    );
    await tester.runAsync(() => tester.tap(key('favorite-auto-upload')));
    await tester.runAsync(() => stores.prefs.idle);
    await tester.pump();
    expect(container.read(favoriteAutoUploadProvider), isTrue);
    final restarted = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    expect(restarted.read(favoriteAutoUploadProvider), isTrue);
    restarted.dispose();
    await tester.ensureVisible(key('remote-api-endpoint'));
    await tester.enterText(key('remote-api-endpoint'), 'invalid');
    await tester.ensureVisible(key('save-remote-config'));
    await tester.tap(key('save-remote-config'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的 http 或 https API 地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('上传失败在任务面板显示重试,重试成功后入口消失', (tester) async {
    await mount(
      tester,
      Column(
        children: [
          const DesktopTaskStatusButton(),
          ResultActions(result: image, canvasBar: CanvasActionBar.top),
        ],
      ),
    );
    await tester.runAsync(() => tester.tap(key('image-remote-upload-action')));
    await completeUpload(tester, failure: true);
    expect(key('desktop-task-button'), findsOneWidget);
    await tester.tap(key('desktop-task-button'));
    await tester.pumpAndSettle();
    final retry = key('retry-image-upload-${image.id}');
    expect(retry, findsOneWidget);
    await tester.runAsync(() async {
      gate = Completer<http.StreamedResponse>();
    });
    await tester.runAsync(() => tester.tap(retry));
    await completeUpload(tester);
    expect(calls, 2);
    expect(key('desktop-task-button'), findsNothing);
    expect(find.text('当前没有任务'), findsOneWidget);
    await finish(tester);
  });
}
