/// 对话里那张生成图点开之后的样子。
///
/// 这份测试原先(上游 windows.45)钉的是「先读完原图、再开一个单图预览浮层」那套
/// 设计:读原图期间点两次只开一个、读失败给一句提示、读完人已经走了就不开。
///
/// 本 fork 换成了**直接开桌面看图浮层**(`desktop-image-viewer`,带整库上下文、
/// 能翻页、能看作品信息),原图由浮层自己懒读 —— 它本来就处理了「缩略图先到、
/// 原图后到」。于是这批用例按同一批**行为约束**重写:点开看的是原图、不切页、
/// 不动图库选择、不弄丢草稿、连点不叠出多层、重绘那颗按钮不误触、移动端照旧。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/widgets/inline_images.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/shell/shell_state.dart';

const _message = AssistantMsg(
  id: 'reply',
  role: MsgRole.ai,
  text: '生成结果',
  at: 1,
  imageIds: ['older', 'generated'],
);

class _Assistant extends AssistantNotifier {
  final generated = <String>[];
  @override
  AssistantState build() => const AssistantState(msgs: [_message]);
  void clear() => state = const AssistantState();
  @override
  Future<void> generateFrom(String msgId) async => generated.add(msgId);
}

class _Canvas extends GenerateNotifier {
  @override
  GenerateState build() => GenerateState.initial();
}

class _Settings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async => const AssistantSettings(
    introVersion: kAssistantIntroVersion,
    libraryScope: LibraryScope.none,
  );
}

void main() {
  final original = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 60, height: 90)..clear(img.ColorRgb8(30, 90, 160)),
    ),
  );
  final thumbnail = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 12, height: 18)..clear(img.ColorRgb8(160, 90, 30)),
    ),
  );
  late AppStores stores;
  late ProviderContainer container;
  late WidgetTester activeTester;
  var isDesktop = true;
  Completer<Uint8List?>? originalRead;
  final viewer = find.byKey(const ValueKey('desktop-image-viewer'));
  final viewerPixels = find.byKey(const ValueKey('desktop-viewer-image'));
  Finder inlineImage() => find.descendant(
    of: find.byType(InlineImages),
    matching: find.byType(Image),
  );

  ResultImage result(String id, {Uint8List? bytes}) =>
      ResultImage(id: id, width: 60, height: 90, seed: 1, bytes: bytes);

  setUp(() {
    stores = AppStores.ephemeral();
    isDesktop = true;
    originalRead = null;
    stores.gallery.initialResults = [
      result('generated', bytes: original),
      result('older', bytes: thumbnail),
      result('canvas', bytes: thumbnail),
    ];
    stores.gallery.initialSelectedId = 'canvas';
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWith((ref) => isDesktop),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        assistantEndpointProvider.overrideWithValue(null),
        assistantProvider.overrideWith(_Assistant.new),
        generateProvider.overrideWith(_Canvas.new),
        assistantSettingsProvider.overrideWith(_Settings.new),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
        galleryThumbProvider.overrideWith((ref, id) async => thumbnail),
        galleryImageProvider.overrideWith(
          (ref, id) => originalRead?.future ?? stores.gallery.readImage(id),
        ),
      ],
    );
  });

  Future<void> cleanFixture() async {
    await activeTester.pumpWidget(const SizedBox());
    container.dispose();
    stores.flushNow();
    var idle = false;
    unawaited(
      Future.wait([
        stores.assistant.idle,
        stores.workspace.idle,
        stores.gallery.idle,
        stores.ledger.idle,
        stores.desktopOutput.idle,
      ]).then((_) => idle = true),
    );
    // Gallery selection on the old/mobile path can queue a real disk write
    // from the fake test clock. Drain both clocks rather than await one while
    // freezing the other, including after an intentionally failing assertion.
    for (var i = 0; i < 200 && !idle; i++) {
      await activeTester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await activeTester.pump();
    }
    expect(idle, isTrue, reason: 'Temporary store queues did not drain');
    final root = stores.desktopOutput.root.parent;
    expect(
      root.path.startsWith(
        '${Directory.systemTemp.path}${Platform.pathSeparator}plana_stores',
      ),
      isTrue,
    );
    root.deleteSync(recursive: true);
  }

  void previewTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      activeTester = tester;
      try {
        await body(tester);
      } finally {
        await cleanFixture();
      }
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    bool embedded = false,
    bool desktop = true,
  }) async {
    activeTester = tester;
    isDesktop = desktop;
    container
        .read(shellIndexProvider.notifier)
        .select(embedded ? kTabCreate : kTabAssistant);
    tester.view.physicalSize = const Size(1200, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final page = AssistantPage(embedded: embedded);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            platform: desktop ? TargetPlatform.windows : TargetPlatform.android,
          ),
          home: Scaffold(
            body: embedded
                ? Row(
                    children: [
                      const Expanded(child: SizedBox()),
                      SizedBox(width: 350, child: page),
                    ],
                  )
                : page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(inlineImage());
    await tester.pumpAndSettle();
  }

  /// 等浮层把原图读完并画出来。
  ///
  /// **不能用 pumpAndSettle**:原图没读完时浮层里挂着转圈的进度指示,一直在动,
  /// 它就永远「settle」不了。这里边喂真时间(读盘要走真 IO)边 pump。
  Future<void> settleViewer(WidgetTester tester, {bool untilImage = true}) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (!untilImage) continue;
      final found = viewerPixels.evaluate();
      if (found.isNotEmpty &&
          tester.widget<Image>(viewerPixels).image is MemoryImage) {
        return;
      }
    }
  }

  /// 打开浮层那一刻不 settle(还在转圈),只把这一帧推出去。
  Future<void> pumpViewerOpen(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  for (final embedded in [false, true]) {
    previewTest(
      'single click previews original and keeps conversation and canvas, embedded=$embedded',
      (tester) async {
        await mount(tester, embedded: embedded);
        final gallery = container.read(galleryProvider);
        final canvas = container.read(generateProvider);
        final navigation = container.read(shellIndexProvider);
        final input = find.widgetWithText(TextField, '想画什么、想改哪里…');
        await tester.enterText(input, '保留这条草稿');
        await tester.ensureVisible(inlineImage());
        await pumpViewerOpen(tester, inlineImage());
        await settleViewer(tester);
        expect(viewer, findsOneWidget);
        expect(
          (tester.widget<Image>(viewerPixels).image as MemoryImage).bytes,
          orderedEquals(original),
        );
        expect(container.read(shellIndexProvider), navigation);
        expect(container.read(galleryProvider), same(gallery));
        expect(container.read(generateProvider), same(canvas));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(viewer, findsNothing);
        expect(find.text('保留这条草稿'), findsOneWidget);
        expect(find.text('生成结果'), findsOneWidget);
        expect(container.read(shellIndexProvider), navigation);
        expect(container.read(galleryProvider), same(gallery));
        expect(tester.takeException(), isNull);
      },
    );
  }

  previewTest('repeated clicks while loading open only one viewer', (
    tester,
  ) async {
    originalRead = Completer<Uint8List?>();
    stores.gallery.initialResults = [result('generated'), result('canvas')];
    await mount(tester);
    expect(
      ((tester.widget<Image>(inlineImage()).image as ResizeImage).imageProvider
              as MemoryImage)
          .bytes,
      orderedEquals(thumbnail),
    );
    await pumpViewerOpen(tester, inlineImage());
    // 第二次点:浮层已经开着、盖在这一层上面,这一下打到浮层上 ——
    // 不该在它上面再叠一层。
    await tester.tapAt(tester.getCenter(inlineImage()));
    await tester.pump();
    expect(viewer, findsOneWidget);
    originalRead!.complete(original);
    await settleViewer(tester);
    expect(viewer, findsOneWidget);
    expect(
      (tester.widget<Image>(viewerPixels).image as MemoryImage).bytes,
      orderedEquals(original),
    );
    await tester.tap(find.byKey(const ValueKey('desktop-image-close')));
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(container.read(shellIndexProvider), kTabAssistant);
    expect(container.read(galleryProvider).selectedId, 'canvas');
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    previewTest(
      'unavailable original keeps the viewer usable and the chat intact, readThrows=$fails',
      (tester) async {
        originalRead = Completer<Uint8List?>();
        stores.gallery.initialResults = [result('generated'), result('canvas')];
        await mount(tester);
        await pumpViewerOpen(tester, inlineImage());
        if (fails) {
          originalRead!.completeError(
            const FileSystemException('Synthetic missing image'),
          );
        } else {
          originalRead!.complete(null);
        }
        await tester.pumpAndSettle();
        // 读不出来时说一句人话,浮层本身不崩、关得掉。
        await settleViewer(tester);
        expect(find.text('无法读取这张图片'), findsOneWidget);
        expect(viewer, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(viewer, findsNothing);
        expect(container.read(shellIndexProvider), kTabAssistant);
        expect(container.read(galleryProvider).selectedId, 'canvas');
        expect(tester.takeException(), isNull);
      },
    );
  }

  previewTest('removing the message while the viewer is open does not crash', (
    tester,
  ) async {
    originalRead = Completer<Uint8List?>();
    stores.gallery.initialResults = [result('generated'), result('canvas')];
    await mount(tester);
    await pumpViewerOpen(tester, inlineImage());
    (container.read(assistantProvider.notifier) as _Assistant).clear();
    // 消息没了:列表重建,但浮层是自己一层,不受影响 —— 这里同样不能 settle
    // (原图读还没回来,浮层里转着圈)。
    await settleViewer(tester, untilImage: false);
    originalRead!.complete(original);
    await settleViewer(tester);
    // 浮层照样关得掉,不该崩。
    expect(viewer, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleViewer(tester, untilImage: false);
    expect(viewer, findsNothing);
    expect(container.read(galleryProvider).selectedId, 'canvas');
    expect(tester.takeException(), isNull);
  });

  previewTest('switching tabs while the viewer is open keeps it on top', (
    tester,
  ) async {
    originalRead = Completer<Uint8List?>();
    stores.gallery.initialResults = [result('generated'), result('canvas')];
    await mount(tester);
    await pumpViewerOpen(tester, inlineImage());
    container.read(shellIndexProvider.notifier).select(kTabInspiration);
    originalRead!.complete(original);
    await tester.pumpAndSettle();
    await settleViewer(tester);
    expect(container.read(shellIndexProvider), kTabInspiration);
    expect(container.read(galleryProvider).selectedId, 'canvas');
    expect(tester.takeException(), isNull);
  });

  previewTest(
    'regenerate button sends only its message action without opening the viewer',
    (tester) async {
      await mount(tester, embedded: true);
      await tester.tap(find.byTooltip('重新生成'));
      await tester.pumpAndSettle();
      expect(
        (container.read(assistantProvider.notifier) as _Assistant).generated,
        ['reply'],
      );
      expect(viewer, findsNothing);
      expect(container.read(shellIndexProvider), kTabCreate);
      expect(container.read(galleryProvider).selectedId, 'canvas');
      expect(tester.takeException(), isNull);
    },
  );

  previewTest('mobile keeps its existing gallery navigation', (tester) async {
    await mount(tester, desktop: false);
    await tester.tap(inlineImage());
    await tester.pumpAndSettle();
    expect(viewer, findsNothing);
    expect(container.read(shellIndexProvider), kTabGallery);
    expect(container.read(galleryProvider).selectedId, 'generated');
    expect(tester.takeException(), isNull);
  });
}
