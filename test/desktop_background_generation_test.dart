import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/main.dart';

import 'support/pump_until.dart';

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

class _Frames extends NaiClient {
  final requests = <StreamController<NaiFrame>>[];

  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) {
    final frames = StreamController<NaiFrame>();
    requests.add(frames);
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
}

void main() {
  late AppStores stores;
  late ProviderContainer c;
  late _Frames client;
  late Uint8List bytes;
  late String oldId;
  var disposed = false;

  setUp(() async {
    stores = AppStores.ephemeral();
    disposed = false;
    client = _Frames();
    bytes = Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 96)));
    await stores.prefs.write(
      key: 'editor_settings',
      value: '{"enableCompletion":false}',
    );
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        authModeProvider.overrideWith(_Auth.new),
        naiKeysStoreProvider.overrideWith(_Keys.new),
        naiClientProvider.overrideWith((ref, base) => client),
      ],
    );
    await c.read(authModeProvider.future);
    await c.read(naiKeysStoreProvider.future);
    c.read(desktopLibraryProvider.notifier).choose(null);
    final gallery = c.read(galleryProvider.notifier);
    for (var i = 0; i < 8; i++) {
      final result = gallery.addResult(
        bytes: bytes,
        width: 64,
        height: 96,
        seed: i,
      );
      if (i == 2) oldId = result.id;
    }
    gallery.select(oldId);
    await stores.gallery.idle;
  });

  tearDown(() {
    for (final frames in client.requests) {
      unawaited(frames.close());
    }
    if (!disposed) c.dispose();
    stores.flushNow();
  });

  Future<void> settle(WidgetTester tester) => pumpUntil(
    tester,
    () => !tester.binding.hasScheduledFrame,
    reason: 'Desktop layout, image decoding and pending storage must settle',
  );

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const PlanaApp()),
    );
    await settle(tester);
  }

  void expectCanvas(WidgetTester tester, String id) {
    expect(c.read(galleryProvider).selectedId, id);
    expect(tester.widget<FilmStrip>(find.byType(FilmStrip)).selectedId, id);
    expect(
      tester.widget<ResultChrome>(find.byType(ResultChrome)).result.id,
      id,
    );
    final view = tester.widget<PageView>(find.byType(PageView));
    final images = c.read(galleryViewProvider).results;
    expect(
      view.controller!.page!.round(),
      images.indexWhere((r) => r.id == id),
    );
    expect(tester.takeException(), isNull);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpUntilComplete(tester, stores.flushForExit());
    c.dispose();
    disposed = true;
  }

  for (final destination in [kTabGallery, kTabProfile]) {
    for (final resize in [false, true]) {
      testWidgets(
        'returning from tab $destination after background generation shows the completed image (resize: $resize)',
        (tester) async {
          await mount(tester);
          expectCanvas(tester, oldId);
          final work = c
              .read(generationProvider.notifier)
              .generate(using: GenerateState.initial());
          await pumpUntil(tester, () => client.requests.isNotEmpty);
          c.read(shellIndexProvider.notifier).select(destination);
          await settle(tester);
          if (resize) {
            tester.view.physicalSize = const Size(1000, 800);
            await settle(tester);
          }
          client.requests.single.add((step: 28, isFinal: true, bytes: bytes));
          expect(await pumpUntilComplete(tester, work), GenOutcome.ok);
          final result = c.read(galleryProvider).results.first;
          expect(c.read(shellIndexProvider), destination);
          c.read(shellIndexProvider.notifier).select(kTabCreate);
          await settle(tester);
          expectCanvas(tester, result.id);
          await finish(tester);
        },
      );
    }
  }

  testWidgets(
    'queued results completed in a hidden date library keep the followed result',
    (tester) async {
      final albums = c.read(albumsProvider.notifier);
      final id = dailyAlbumId(DateTime.now());
      await tester.runAsync(() async {
        await albums.ensureDailyAlbum(id);
        await albums.organize(
          c.read(galleryProvider).results.map((r) => r.id).toSet(),
          {id},
        );
      });
      c.read(desktopLibraryProvider.notifier).choose(id);
      await mount(tester);
      expectCanvas(tester, oldId);
      final jobs = [
        for (var i = 0; i < 5; i++)
          c
              .read(generationProvider.notifier)
              .generate(using: GenerateState.initial()),
      ];
      await pumpUntil(tester, () => client.requests.isNotEmpty);
      c.read(shellIndexProvider.notifier).select(kTabProfile);
      await settle(tester);
      for (var i = 0; i < jobs.length; i++) {
        await pumpUntil(tester, () => client.requests.length > i);
        client.requests[i].add((step: 28, isFinal: true, bytes: bytes));
        expect(await pumpUntilComplete(tester, jobs[i]), GenOutcome.ok);
      }
      final result = c.read(galleryProvider).results.first;
      expect(c.read(galleryProvider).selectedId, result.id);
      c.read(shellIndexProvider.notifier).select(kTabCreate);
      await settle(tester);
      expectCanvas(tester, result.id);
      await finish(tester);
    },
  );

  testWidgets(
    'a history swipe suspended by switching tabs cannot overwrite a completed result',
    (tester) async {
      await mount(tester);
      final pages = find.byType(PageView);
      await tester.fling(pages, const Offset(-200, 0), 1500);
      await tester.pump(const Duration(milliseconds: 16));
      final work = c
          .read(generationProvider.notifier)
          .generate(using: GenerateState.initial());
      c.read(shellIndexProvider.notifier).select(kTabProfile);
      await tester.pump();
      await pumpUntil(tester, () => client.requests.isNotEmpty);
      client.requests.single.add((step: 28, isFinal: true, bytes: bytes));
      expect(await pumpUntilComplete(tester, work), GenOutcome.ok);
      final result = c.read(galleryProvider).results.first;
      expect(c.read(galleryProvider).selectedId, result.id);
      c.read(shellIndexProvider.notifier).select(kTabCreate);
      await settle(tester);
      expectCanvas(tester, result.id);
      await finish(tester);
    },
  );

  testWidgets(
    'a deferred page correction in the hidden canvas does not replace a completed result',
    (tester) async {
      await mount(tester);
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      final work = c
          .read(generationProvider.notifier)
          .generate(using: GenerateState.initial());
      await pumpUntil(tester, () => client.requests.isNotEmpty);
      c.read(shellIndexProvider.notifier).select(kTabProfile);
      await settle(tester);
      client.requests.single.add((step: 28, isFinal: true, bytes: bytes));
      expect(await pumpUntilComplete(tester, work), GenOutcome.ok);
      final result = c.read(galleryProvider).results.first;
      expect(c.read(galleryProvider).selectedId, result.id);
      // ScrollPosition can report a delayed correction after the data changes.
      // Drive its real notification path while the pane's consumers are paused.
      controller.jumpToPage(3);
      await tester.pump();
      c.read(shellIndexProvider.notifier).select(kTabCreate);
      await settle(tester);
      expectCanvas(tester, result.id);
      await finish(tester);
    },
  );
  for (final viaPicker in [false, true]) {
    testWidgets(
      'browsing another album during generation preserves the completed canvas result (picker: $viaPicker)',
      (tester) async {
        final albums = c.read(albumsProvider.notifier);
        late String target, browsing;
        await tester.runAsync(() async {
          target = await albums.create('生成目标');
          browsing = await albums.create('浏览旧图');
          final images = c.read(galleryProvider).results;
          await albums.organize(images.skip(4).map((r) => r.id).toSet(), {
            target,
          });
          await albums.organize(images.take(4).map((r) => r.id).toSet(), {
            browsing,
          });
        });
        c.read(desktopLibraryProvider.notifier).choose(target);
        await mount(tester);
        expectCanvas(tester, oldId);
        final work = c
            .read(generationProvider.notifier)
            .generate(using: GenerateState.initial());
        await pumpUntil(tester, () => client.requests.isNotEmpty);
        if (viaPicker) {
          await tester.tap(
            find.byKey(const ValueKey('desktop-library-picker')),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(ValueKey('desktop-album-$browsing')));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(
            find.byKey(const ValueKey('desktop-nav-$kTabProfile')),
          );
        } else {
          await tester.tap(
            find.byKey(const ValueKey('desktop-nav-$kTabGallery')),
          );
          await settle(tester);
          await tester.tap(
            find.byKey(ValueKey('desktop-library-card-$browsing')),
          );
        }
        await settle(tester);
        expect(c.read(galleryBrowseAlbumProvider), browsing);
        client.requests.single.add((step: 28, isFinal: true, bytes: bytes));
        expect(await pumpUntilComplete(tester, work), GenOutcome.ok);
        final result = c.read(galleryProvider).results.first;
        expect(c.read(albumsProvider).ofImage(result.id), {target});
        expect(
          c.read(shellIndexProvider),
          viaPicker ? kTabProfile : kTabGallery,
        );
        await tester.tap(find.byKey(const ValueKey('desktop-nav-$kTabCreate')));
        await settle(tester);
        expect(
          tester.widget<ResultChrome>(find.byType(ResultChrome)).result.id,
          result.id,
        );
        expect(c.read(galleryResultPreviewProvider)?.imageId, result.id);
        expect(c.read(galleryBrowseAlbumProvider), browsing);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'choosing history before switching tabs remains selected after background generation',
    (tester) async {
      await mount(tester);
      final work = c
          .read(generationProvider.notifier)
          .generate(using: GenerateState.initial());
      await pumpUntil(tester, () => client.requests.isNotEmpty);
      tester.widget<FilmStrip>(find.byType(FilmStrip)).onSelect(oldId);
      await tester.pump();
      c.read(shellIndexProvider.notifier).select(kTabProfile);
      await settle(tester);
      client.requests.single.add((step: 28, isFinal: true, bytes: bytes));
      expect(await pumpUntilComplete(tester, work), GenOutcome.ok);
      c.read(shellIndexProvider.notifier).select(kTabCreate);
      await settle(tester);
      expectCanvas(tester, oldId);
      await finish(tester);
    },
  );
}
