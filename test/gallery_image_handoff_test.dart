import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;

  @override
  GalleryState build() =>
      GalleryState(results: images, selectedId: images[0].id);
}

Future<({Uint8List bytes, ui.Image image})> _frame(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 100);
  picture.dispose();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return (bytes: png!.buffer.asUint8List(), image: image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late List<({Uint8List bytes, ui.Image image})> frames;
  late List<ResultImage> images;
  late Map<String, Future<Uint8List?>> diskReads;
  final capture = GlobalKey();

  setUp(() async {
    stores = AppStores.ephemeral();
    diskReads = {};
    frames = [
      await _frame(const Color(0xffff0000)),
      await _frame(const Color(0xffffff00)),
      await _frame(const Color(0xffff00ff)),
      await _frame(const Color(0xff0000ff)),
      await _frame(const Color(0xff00ff00)),
    ];
    images = [
      for (var i = 0; i < frames.length; i++)
        ResultImage(
          id: 'frame-$i',
          width: 100,
          height: 100,
          seed: i,
          bytes: frames[i].bytes,
          badge: i < 3 ? ResultBadge.inpaint : ResultBadge.none,
        ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
        // Thumbnails must not resolve the same full-image cache key.
        galleryThumbProvider.overrideWith((ref, id) async => null),
        galleryImageProvider.overrideWith((ref, id) async => diskReads[id]),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
  });

  tearDown(() {
    container.dispose();
    stores.flushNow();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (final frame in frames) {
      frame.image.dispose();
    }
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: const GalleryPage(desktop: true),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        await tester.pump();
      }
    });
  }

  Future<List<int>> pixel(WidgetTester tester) async => (await tester.runAsync(
    () async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final at = (250 * image.width + 450) * 4;
      final rgb = data!.buffer.asUint8List().sublist(at, at + 3);
      image.dispose();
      return rgb;
    },
  ))!;

  Completer<ImageInfo> holdDecode(int index) {
    final ready = Completer<ImageInfo>();
    final provider = MemoryImage(frames[index].bytes);
    PaintingBinding.instance.imageCache.putIfAbsent(
      provider,
      () => OneFrameImageStreamCompleter(ready.future),
    );
    return ready;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'distant original keeps the last rendered image until decoding finishes',
    (tester) async {
      final ready = holdDecode(3);
      await mount(tester);
      expect(await pixel(tester), [255, 0, 0]);
      container.read(galleryProvider.notifier).select('frame-3');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          await pixel(tester),
          [255, 0, 0],
          reason: 'decode-pending frame $i must not show a blank canvas',
        );
      }
      ready.complete(ImageInfo(image: frames[3].image.clone()));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(await pixel(tester), [
          0,
          0,
          255,
        ], reason: 'decoded handoff frame $i');
      }
      expect(
        tester.widget<ResultChrome>(find.byType(ResultChrome)).result.id,
        'frame-3',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'late decode from an earlier click cannot replace the latest selection',
    (tester) async {
      final older = holdDecode(3);
      final latest = holdDecode(4);
      await mount(tester);
      container.read(galleryProvider.notifier).select('frame-3');
      await tester.pump();
      container.read(galleryProvider.notifier).select('frame-4');
      await tester.pump();
      expect(await pixel(tester), [255, 0, 0]);
      latest.complete(ImageInfo(image: frames[4].image.clone()));
      await tester.pump();
      await tester.pump();
      expect(await pixel(tester), [0, 255, 0]);
      older.complete(ImageInfo(image: frames[3].image.clone()));
      await tester.pump();
      await tester.pump();
      expect(await pixel(tester), [0, 255, 0]);
      expect(container.read(galleryProvider).selectedId, 'frame-4');
      await finish(tester);
    },
  );

  testWidgets('disk read and cold decoding both keep the previous full image', (
    tester,
  ) async {
    final read = Completer<Uint8List?>();
    diskReads['frame-3'] = read.future;
    images[3] = images[3].stripped();
    final decode = holdDecode(3);
    await mount(tester);
    container.read(galleryProvider.notifier).select('frame-3');
    await tester.pump();
    expect(await pixel(tester), [255, 0, 0]);
    read.complete(frames[3].bytes);
    await tester.pump();
    await tester.pump();
    expect(await pixel(tester), [
      255,
      0,
      0,
    ], reason: 'bytes ready still does not mean pixels ready');
    decode.complete(ImageInfo(image: frames[3].image.clone()));
    await tester.pump();
    await tester.pump();
    expect(await pixel(tester), [0, 0, 255]);
    await finish(tester);
  });

  testWidgets(
    'failed image shows an error instead of indefinitely keeping another picture',
    (tester) async {
      images[3] = const ResultImage(
        id: 'broken',
        width: 100,
        height: 100,
        seed: 9,
      );
      diskReads['broken'] = Future.value(Uint8List.fromList([1, 2, 3]));
      await mount(tester);
      container.read(galleryProvider.notifier).select('broken');
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          await tester.pump();
        }
      });
      expect(find.byTooltip('无法读取图片'), findsOneWidget);
      expect(await pixel(tester), isNot([255, 0, 0]));
      await finish(tester);
    },
  );
}
