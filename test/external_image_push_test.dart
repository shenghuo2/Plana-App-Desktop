import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plana_app/core/net/external_image_push_client.dart';
import 'package:plana_app/core/net/external_image_push_config.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/external_image_push.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/shell/desktop_task_status.dart';
import 'package:plana_app/features/shell/desktop_work_state.dart';

http.StreamedResponse response([
  String body = '{"id":"asset-1","deduplicated":false}',
  int status = 201,
]) => http.StreamedResponse(Stream.value(utf8.encode(body)), status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late ResultImage image;
  late Uint8List bytes;
  late ExternalImagePushRequestSender sender;
  late List<http.MultipartRequest> requests;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('plana_remote_upload');
    stores = await AppStores.open(rootOverride: root);
    requests = [];
    sender = (_) async => response();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        externalImagePushClientProvider.overrideWithValue(
          ExternalImagePushClient(
            requestSender: (request) {
              requests.add(request);
              return sender(request);
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
    bytes = File('assets/app_icon.png').readAsBytesSync();
    image = container
        .read(galleryProvider.notifier)
        .addResult(bytes: bytes, width: 512, height: 768, seed: 42);
    await stores.flushForExit();
  });
  tearDown(() async {
    container.dispose();
    await stores.flushForExit();
    root.deleteSync(recursive: true);
  });

  test('首次异步读取前锁定图片,重复操作共用一次上传', () async {
    final gate = Completer<http.StreamedResponse>();
    final received = Completer<void>();
    sender = (_) {
      received.complete();
      return gate.future;
    };
    final uploads = container.read(externalImagePushUploadsProvider.notifier);
    final first = uploads.upload(image);
    final second = uploads.upload(image);
    expect(identical(first, second), isTrue);
    expect(container.read(externalImagePushUploadsProvider).pending, {
      image.id,
    });
    await received.future;
    expect(requests, hasLength(1));
    expect(container.read(desktopWorkBusyProvider), isTrue);
    expect(container.read(desktopTaskStatusProvider).label, contains('上传中 1'));
    gate.complete(response());
    expect(await first, isTrue);
    expect(container.read(externalImagePushUploadsProvider).busy, isFalse);
    expect(container.read(desktopWorkBusyProvider), isFalse);
  });

  test('开关默认关闭,收藏和取消收藏只改本地', () async {
    final gallery = container.read(galleryProvider.notifier);
    gallery.toggleFavorite(image.id);
    expect(container.read(galleryProvider).selected?.favorite, isTrue);
    gallery.toggleFavorite(image.id);
    await stores.flushForExit();
    expect(requests, isEmpty);
    expect(container.read(galleryProvider).selected?.favorite, isFalse);
  });

  test('快速取消再收藏期间只上传一次,取消收藏不发远端请求', () async {
    await container.read(favoriteAutoUploadProvider.notifier).set(true);
    final gate = Completer<http.StreamedResponse>();
    sender = (_) => gate.future;
    final gallery = container.read(galleryProvider.notifier);
    gallery.toggleFavorite(image.id);
    gallery.toggleFavorite(image.id);
    gallery.toggleFavorite(image.id);
    final pending = container
        .read(externalImagePushUploadsProvider.notifier)
        .upload(image);
    gate.complete(response());
    expect(await pending, isTrue);
    expect(requests, hasLength(1));
    gallery.toggleFavorite(image.id);
    await stores.flushForExit();
    expect(container.read(galleryProvider).selected?.favorite, isFalse);
    expect(requests, hasLength(1));
  });

  test('自动上传失败保留收藏,失败任务可重试且成功后清除', () async {
    await container.read(favoriteAutoUploadProvider.notifier).set(true);
    sender = (_) async => response('{"error":{"message":"Token 已撤销"}}', 401);
    container.read(galleryProvider.notifier).toggleFavorite(image.id);
    final uploads = container.read(externalImagePushUploadsProvider.notifier);
    expect(await uploads.upload(image), isFalse);
    expect(container.read(galleryProvider).selected?.favorite, isTrue);
    expect(
      container
          .read(externalImagePushUploadsProvider)
          .failures[image.id]
          ?.message,
      'Token 已撤销',
    );
    expect(container.read(genNoticeProvider), contains('任务状态中重试'));
    expect(container.read(desktopTaskStatusProvider).label, contains('上传失败 1'));
    sender = (_) async => response();
    expect(await uploads.retry(image.id), isTrue);
    expect(container.read(externalImagePushUploadsProvider).failures, isEmpty);
    expect(container.read(galleryProvider).selected?.favorite, isTrue);
    expect(requests, hasLength(2));
  });

  test('懒读原图上传同一张图,切换选择不改图片或来源元数据', () async {
    container
        .read(galleryProvider.notifier)
        .addResult(bytes: bytes, width: 256, height: 256, seed: 99);
    final uploads = container.read(externalImagePushUploadsProvider.notifier);
    expect(await uploads.upload(image.stripped()), isTrue);
    final request = requests.single;
    expect(await request.files.single.finalize().toBytes(), bytes);
    expect(request.files.single.filename, '${image.id}.png');
    final source = jsonDecode(request.fields['source']!) as Map;
    expect(source['seed_hint'], 42);
    expect(source['source_name'], 'PlanaAPP');
    expect(source['metadata']['gallery_id'], image.id);
    expect(source['metadata']['width'], 512);
    expect(
      source['captured_at'],
      DateTime.fromMillisecondsSinceEpoch(
        image.createdAt,
        isUtc: true,
      ).toIso8601String(),
    );
  });

  test('未配置或原图缺失会失败并清理忙碌状态', () async {
    final uploads = container.read(externalImagePushUploadsProvider.notifier);
    await container
        .read(externalImagePushSettingsProvider.notifier)
        .clearToken();
    expect(await uploads.upload(image), isFalse);
    expect(requests, isEmpty);
    expect(container.read(externalImagePushUploadsProvider).busy, isFalse);
    await container
        .read(externalImagePushSettingsProvider.notifier)
        .save(
          endpoint: 'https://images.example',
          sourceName: 'PlanaAPP',
          token: 'test-token',
        );
    expect(
      await uploads.upload(
        const ResultImage(id: 'missing', width: 1, height: 1, seed: 1),
      ),
      isFalse,
    );
    expect(
      container
          .read(externalImagePushUploadsProvider)
          .failures['missing']
          ?.message,
      contains('原图'),
    );
    uploads.dismissFailure('missing');
    expect(
      container
          .read(externalImagePushUploadsProvider)
          .failures
          .containsKey('missing'),
      isFalse,
    );
  });

  test('页面销毁后在途上传结束不访问已销毁 provider', () async {
    final gate = Completer<http.StreamedResponse>();
    final received = Completer<void>();
    sender = (_) {
      received.complete();
      return gate.future;
    };
    final pending = container
        .read(externalImagePushUploadsProvider.notifier)
        .upload(image);
    await received.future;
    container.dispose();
    gate.complete(response());
    expect(await pending, isTrue);
  });
}
