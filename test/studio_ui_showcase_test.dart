import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/assistant/agent_model.dart'
    show AgentModelChoice, assistantEndpointProvider, assistantModelProvider;
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/desktop/desktop_gallery_browser.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/main.dart';

const _showcaseOutDir =
    '/home/shenghuo2/.gemini/antigravity/brain/5f04fd08-bcc8-4237-9256-f07d243ea164/studio_showcase';

class _ShowcaseAssistant extends AssistantNotifier {
  @override
  AssistantState build() => const AssistantState(
    msgs: [
      AssistantMsg(
        id: 'demo-user-1',
        role: MsgRole.user,
        at: 1732620000000,
        text: '想画一张夜晚室内冷色调人像，突出清澈眼眸与干净的边缘轮廓光。',
      ),
      AssistantMsg(
        id: 'demo-ai-1',
        role: MsgRole.ai,
        at: 1732620005000,
        text: '建议用青蓝轮廓光搭配低饱和阴影衬托银发和瞳孔高光；主提示词已经收拢成景别、光影和质感三层，直接微调左侧参数就能试画。',
      ),
    ],
  );
}

Future<void> _loadFonts() async {
  const sdkFonts =
      '/home/shenghuo2/.cache/flutter-sdk-3.44.2/flutter/bin/cache/artifacts/material_fonts';
  const cjkFont = '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf';
  const monoRegular = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf';
  const monoBold = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf';

  final cache = <String, Uint8List>{};
  Future<ByteData?> readFont(String path) async {
    final existing = cache[path];
    if (existing != null) return ByteData.sublistView(existing);
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    cache[path] = bytes;
    return ByteData.sublistView(bytes);
  }

  Future<void> loadInto(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var count = 0;
    for (final path in paths) {
      final data = await readFont(path);
      if (data == null) continue;
      loader.addFont(Future.value(data));
      count++;
    }
    if (count > 0) await loader.load();
  }

  await loadInto('MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
  final sans = [
    '$sdkFonts/Roboto-Regular.ttf',
    '$sdkFonts/Roboto-Medium.ttf',
    '$sdkFonts/Roboto-Bold.ttf',
  ];
  await loadInto('Segoe UI', sans);
  await loadInto('Roboto', sans);
  await loadInto('Microsoft YaHei', [cjkFont]);
  await loadInto('monospace', [monoRegular, monoBold]);
}

Future<void> _settleFrame(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final disabled = debugDisableShadows;
  debugDisableShadows = false;
  for (final render in tester.allRenderObjects) {
    render.markNeedsPaint();
  }
  try {
    await _settleFrame(tester);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$_showcaseOutDir/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = disabled;
  }
}

Uint8List? _cropPng(
  img.Image? source, {
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  if (source == null) return null;
  final cropped = img.copyCrop(
    source,
    x: x,
    y: y,
    width: width,
    height: height,
  );
  return Uint8List.fromList(img.encodePng(cropped));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final enabled = Platform.environment['PLANA_STUDIO_SHOWCASE'] == '1';
  final artworks = <({Uint8List bytes, int width, int height})>[];

  setUpAll(() async {
    if (!enabled) return;
    await _loadFonts();

    final workspaceFile = File('screenshots/windows/workspace.png');
    final galleryFile = File('screenshots/windows/gallery.png');
    final workspaceImg = workspaceFile.existsSync()
        ? img.decodeImage(await workspaceFile.readAsBytes())
        : null;
    final galleryImg = galleryFile.existsSync()
        ? img.decodeImage(await galleryFile.readAsBytes())
        : null;

    final sunset = _cropPng(galleryImg, x: 235, y: 466, width: 170, height: 90);
    final garden = _cropPng(
      galleryImg,
      x: 427,
      y: 476,
      width: 170,
      height: 108,
    );
    final waterfall = _cropPng(
      galleryImg,
      x: 648,
      y: 438,
      width: 112,
      height: 144,
    );
    final hero = _cropPng(
      workspaceImg,
      x: 549,
      y: 101,
      width: 471,
      height: 709,
    );

    if (sunset != null) {
      artworks.add((bytes: sunset, width: 1216, height: 832));
    }
    if (garden != null) {
      artworks.add((bytes: garden, width: 1024, height: 1024));
    }
    if (waterfall != null) {
      artworks.add((bytes: waterfall, width: 832, height: 1216));
    }
    if (hero != null) {
      artworks.add((bytes: hero, width: 832, height: 1216));
    }
  });

  testWidgets(
    'captures 1440x900 Light/Dark/Focus Plana Studio showcase screenshots',
    skip: !enabled,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final stores = AppStores.ephemeral();
      await tester.runAsync(() async {
        for (final key in [
          'hint_grid_longpress',
          'hint_save_longpress',
          'hint_strip_swipe',
        ]) {
          await stores.prefs.write(key: key, value: '1');
        }
        await stores.prefs.write(
          key: 'editor_settings',
          value: '{"enableCompletion":false}',
        );
        await stores.prefs.write(
          key: 'assistant_settings',
          value: jsonEncode(
            const AssistantSettings(
              introVersion: kAssistantIntroVersion,
            ).toJson(),
          ),
        );
      });

      final container = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(true),
          assistantProvider.overrideWith(_ShowcaseAssistant.new),
          assistantEndpointProvider.overrideWithValue(
            const CustomEndpoint(
              id: 'studio-demo',
              name: '演示模型',
              format: AgentApiFormat.openai,
              baseUrl: 'http://127.0.0.1:1',
              apiKey: 'demo-key',
              model: 'studio-demo',
            ),
          ),
          assistantModelProvider.overrideWithValue(
            const AgentModelChoice(key: 'studio-demo', name: '演示模型'),
          ),
        ],
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
        stores.flushNow();
      });

      container
          .read(desktopLibraryProvider.notifier)
          .choose(null, automatic: false);

      container
          .read(generateProvider.notifier)
          .setPrompts(
            positive:
                '1girl, solo, silver hair, cyan eyes, nocturnal studio portrait, cinematic rim lighting, shallow depth of field, delicate shading, masterpiece',
            negative: 'lowres, bad anatomy, text, watermark, blurry',
          );

      final addedIds = <String>[];
      // Add 2 cycles ending with hero so it becomes the selected canvas artwork.
      final seedList = [...artworks, ...artworks];
      for (var i = 0; i < seedList.length; i++) {
        final art = seedList[i];
        final added = container
            .read(galleryProvider.notifier)
            .addResult(
              bytes: art.bytes,
              width: art.width,
              height: art.height,
              seed: 20261126 + i * 17,
              input: container.read(generateProvider),
            );
        addedIds.add(added.id);
      }
      if (addedIds.length >= 3) {
        container
            .read(galleryProvider.notifier)
            .setFavorite(addedIds.last, true);
        container
            .read(galleryProvider.notifier)
            .setFavorite(addedIds[addedIds.length - 3], true);
      }

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final captureKey = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(key: captureKey, child: const PlanaApp()),
        ),
      );
      await _settleFrame(tester);

      // 1. Studio Workspace - Light
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(mode: ThemeMode.light));
      await _capture(tester, captureKey, 'studio_workspace_light');

      // 2. Studio Workspace - Dark
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(mode: ThemeMode.dark));
      await _capture(tester, captureKey, 'studio_workspace_dark');

      // 3. Studio Workspace - Focus Canvas Mode (Dark)
      await tester.tap(
        find.byKey(const ValueKey('desktop-focus-canvas-toggle')),
      );
      await _capture(tester, captureKey, 'studio_workspace_focus_dark');

      // Restore panes before opening Gallery view.
      await tester.tap(
        find.byKey(const ValueKey('desktop-focus-canvas-toggle')),
      );
      await _settleFrame(tester);

      // 4. Studio Gallery Grid - Light
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(mode: ThemeMode.light));
      container
          .read(desktopGalleryLocationProvider.notifier)
          .open(null, overview: false);
      container.read(shellIndexProvider.notifier).select(kTabGallery);
      await _capture(tester, captureKey, 'studio_gallery_light');

      // 5. Studio Gallery Grid - Dark
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(mode: ThemeMode.dark));
      await _capture(tester, captureKey, 'studio_gallery_dark');

      await tester.pumpWidget(const SizedBox());
      container.dispose();
      disposed = true;
      await tester.pump(const Duration(seconds: 2));
      await _settleFrame(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
