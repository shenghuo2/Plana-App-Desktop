import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/features/director/director_models.dart';
import 'package:plana_app/features/director/director_page.dart';
import 'package:plana_app/features/director/director_service.dart';
import 'package:plana_app/features/director/director_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/import/desktop_image_drop.dart';

class _Balance extends AnlasNotifier {
  @override
  Future<NaiSubscription?> build() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(() async {
    for (final font in [
      ('Microsoft YaHei', 'C:/Windows/Fonts/msyh.ttc'),
      ('Segoe UI', 'C:/Windows/Fonts/segoeui.ttf'),
      (
        'MaterialIcons',
        'D:/Android/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ]) {
      final file = File(font.$2);
      if (await file.exists()) {
        await (FontLoader(
          font.$1,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  setUp(() {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryBrowseAlbumProvider.overrideWithValue(null),
        directorAccessProvider.overrideWithValue(
          const DirectorAccess(
            key: NaiKey(id: 'main', token: 'test-only'),
          ),
        ),
        anlasProvider.overrideWith(_Balance.new),
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopClipboard.channel, (_) async => null);
  });
  tearDown(() async {
    c.dispose();
    await stores.flushForExit();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopClipboard.channel, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      if (c.read(directorProvider).inputs.isEmpty) {
        final source = img.Image(width: 192, height: 256, numChannels: 4);
        for (final p in source) {
          p.setRgba(80 + p.x ~/ 2, 120 + p.y ~/ 3, 200, p.x < 28 ? 0 : 255);
        }
        final bytes = Uint8List.fromList(img.encodePng(source));
        final image = await c
            .read(galleryProvider.notifier)
            .addResultToGallery(
              bytes: bytes,
              width: 192,
              height: 256,
              seed: 123,
              target: const GallerySaveTarget.all(),
            );
        await c.read(directorProvider.notifier).addHistory(image);
        c.read(directorProvider.notifier).selectPreview(image);
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: (dark ? AppTheme.dark() : AppTheme.light()).copyWith(
              platform: TargetPlatform.windows,
              textTheme: (dark ? AppTheme.dark() : AppTheme.light()).textTheme
                  .apply(
                    fontFamily: 'Microsoft YaHei',
                    fontFamilyFallback: const ['Segoe UI'],
                  ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: DesktopImageDropHost(child: child!),
            ),
            home: const DirectorPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final context = tester.element(find.byType(DirectorPage));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, context);
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    final directory = Platform.environment['PLANA_DIRECTOR_CAPTURE'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$directory/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final variant in [
    (const Size(1280, 720), 1.4, false),
    (const Size(1440, 900), 1.0, false),
    (const Size(1920, 1080), 1.0, true),
    (const Size(800, 600), 1.0, false),
  ]) {
    testWidgets(
      'workbench fits ${variant.$1} text ${variant.$2} dark ${variant.$3}',
      (tester) async {
        await mount(
          tester,
          size: variant.$1,
          scale: variant.$2,
          dark: variant.$3,
        );
        expect(tester.takeException(), isNull);
        c
            .read(directorProvider.notifier)
            .options(const DirectorOptions(tool: DirectorTool.emotion));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('director-source')), findsOneWidget);
        expect(find.byKey(const ValueKey('director-result')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('director-transform')).hitTestable(),
          findsOneWidget,
        );
        await screenshot(tester, 'workbench-${variant.$1.width.toInt()}');
        c
            .read(directorProvider.notifier)
            .options(
              const DirectorOptions(
                tool: DirectorTool.pixelSnap,
                palette: DirectorPalette.custom,
              ),
            );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'drag history to source adds input and keeps history and main canvas selection',
    (tester) async {
      await mount(tester);
      final selected = c.read(galleryProvider).selectedId;
      final history = find.byType(GalleryImageDrag).first;
      final destination = tester.getCenter(
        find.byKey(const ValueKey('director-source')),
      );
      final drag = await tester.startGesture(
        tester.getCenter(history),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(-20, 0));
      await tester.pump();
      await drag.moveTo(destination);
      await tester.pump();
      await drag.up();
      for (
        var i = 0;
        i < 30 && c.read(directorProvider).inputs.length < 2;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(c.read(directorProvider).inputs.length, 2);
      expect(c.read(galleryProvider).results.length, 1);
      expect(c.read(galleryProvider).selectedId, selected);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'emotion dropdown opens beneath its anchor and maps Chinese selection',
    (tester) async {
      await mount(tester);
      c
          .read(directorProvider.notifier)
          .options(const DirectorOptions(tool: DirectorTool.emotion));
      await tester.pumpAndSettle();
      final anchor = find.byKey(const ValueKey('director-emotion'));
      await tester.tap(anchor);
      await tester.pumpAndSettle();
      final happy = find.text('开心');
      expect(happy, findsOneWidget);
      // Menus keep the anchor and select an explicit value, not a cycling button.
      await tester.ensureVisible(happy);
      await tester.tap(happy);
      await tester.pumpAndSettle();
      expect(c.read(directorProvider).options.emotion, 'happy');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
