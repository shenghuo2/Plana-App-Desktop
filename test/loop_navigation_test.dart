import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/gen_queue.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/loop_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/shell/shell_state.dart';

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

class _Keys extends NaiKeysNotifier {
  @override
  Future<List<NaiKey>> build() async => [
    const NaiKey(id: 'test', token: 'local-test-only', primary: true),
  ];
}

class _Client extends NaiClient {
  final _started = StreamController<StreamController<NaiFrame>>();
  late final _requests = StreamIterator(_started.stream);
  final _frames = <StreamController<NaiFrame>>[];
  bool _closed = false;

  Future<StreamController<NaiFrame>> nextImage() async {
    if (!await _requests.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('没有新的生成请求');
    }
    return _requests.current;
  }

  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) {
    if (_closed) return const Stream.empty();
    final frames = StreamController<NaiFrame>();
    _frames.add(frames);
    _started.add(frames);
    return frames.stream;
  }

  @override
  Future<NaiSubscription> subscription(String token) async => (
    anlas: 10000,
    fixedAnlas: 10000,
    purchasedAnlas: 0,
    isOpus: true,
    tier: 3,
    usage: null,
  );

  Future<void> close() async {
    _closed = true;
    for (final frames in _frames) {
      await frames.close();
    }
    await _requests.cancel();
    await _started.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late _Client client;
  late ProviderContainer c;
  late Uint8List bytes;

  setUp(() async {
    stores = AppStores.ephemeral();
    client = _Client();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        authModeProvider.overrideWith(_Auth.new),
        naiKeysStoreProvider.overrideWith(_Keys.new),
        naiClientProvider.overrideWith((ref, base) => client),
      ],
    );
    await c.read(authModeProvider.future);
    await c.read(naiKeysStoreProvider.future);
    bytes = await File('assets/app_icon.png').readAsBytes();
  });

  tearDown(() async {
    try {
      await client.close();
      stores.flushNow();
      await Future.wait([
        stores.workspace.idle,
        stores.gallery.idle,
        stores.albums.idle,
        stores.ledger.idle,
      ]);
    } finally {
      c.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    test('循环启动按平台导航,续张和转入队列尊重用户切页: ${platform.name}', () async {
      debugDefaultTargetPlatformOverride = platform;
      final desktop = platform != TargetPlatform.android;
      final pages = <int>[];
      c.listen<int>(shellIndexProvider, (_, page) => pages.add(page));
      c.read(generateProvider.notifier).setLoop(LoopCount.x4);

      final work = c.read(loopStatusProvider.notifier).start();
      expect(c.read(loopStatusProvider).active, isTrue);
      expect(c.read(shellIndexProvider), desktop ? kTabCreate : kTabGallery);
      final first = await client.nextImage();
      expect(c.read(shellIndexProvider), desktop ? kTabCreate : kTabGallery);

      c.read(shellIndexProvider.notifier).select(kTabInspiration);
      final queue = c.read(genQueueProvider.notifier);
      expect(queue.enqueue(), isTrue);
      await queue.maybeStart();
      expect(c.read(genQueueProvider).active, isFalse);
      final queueDone = Completer<void>();
      c.listen<GenQueueState>(genQueueProvider, (before, after) {
        if (before?.active == true && !after.active) queueDone.complete();
      });

      for (var i = 0; i < LoopCount.x4.count; i++) {
        final frames = i == 0 ? first : await client.nextImage();
        expect(c.read(shellIndexProvider), kTabInspiration);
        frames.add((step: 28, isFinal: true, bytes: bytes));
      }
      await work.timeout(const Duration(seconds: 10));
      expect(c.read(loopStatusProvider).active, isFalse);

      final queued = await client.nextImage();
      expect(c.read(genQueueProvider).active, isTrue);
      expect(c.read(shellIndexProvider), kTabInspiration);
      queued.add((step: 28, isFinal: true, bytes: bytes));
      await queueDone.future.timeout(const Duration(seconds: 10));

      expect(c.read(shellIndexProvider), kTabInspiration);
      expect(pages, [if (!desktop) kTabGallery, kTabInspiration]);
      expect(c.read(galleryProvider).results, hasLength(5));
      expect(c.read(generationProvider).jobs, isEmpty);
      expect(c.read(genQueueProvider).items, isEmpty);
    });
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    test('桌面队列启动和续张不切页: ${platform.name}', () async {
      debugDefaultTargetPlatformOverride = platform;
      c.read(shellIndexProvider.notifier).select(kTabInspiration);
      final pages = <int>[];
      c.listen<int>(shellIndexProvider, (_, page) => pages.add(page));
      final queue = c.read(genQueueProvider.notifier);
      expect(queue.enqueue(), isTrue);
      expect(queue.enqueue(), isTrue);

      final work = queue.maybeStart();
      final first = await client.nextImage();
      expect(c.read(shellIndexProvider), kTabInspiration);
      c.read(shellIndexProvider.notifier).select(kTabGallery);
      first.add((step: 28, isFinal: true, bytes: bytes));
      final second = await client.nextImage();
      expect(c.read(shellIndexProvider), kTabGallery);
      second.add((step: 28, isFinal: true, bytes: bytes));
      await work.timeout(const Duration(seconds: 10));

      expect(pages, [kTabGallery]);
      expect(c.read(shellIndexProvider), kTabGallery);
      expect(c.read(galleryProvider).results, hasLength(2));
      expect(c.read(generationProvider).jobs, isEmpty);
      expect(c.read(genQueueProvider).active, isFalse);
    });
  }
}
