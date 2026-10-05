/// Windows 那条 `paste` 事件(原生拦下 Ctrl+V 后送上来的图)的落点裁决。
///
/// 上游 windows.45 自带一份同名测试,走的是它那套 `pasteDefault` / `pasteFallback`
/// 标记。本 fork 的落点裁决换成了**光标优先、焦点兜底**(见 DesktopImageDropHost),
/// 这份测试按同一批行为改写成对新 API 的断言 —— 覆盖点一个没少:
/// 光标所在的那块优先、藏起来的页面收不到、弹层挡住时谁都不收、
/// 代理能替自己盖不到的那一行接手、原生报错给人话、纯文本粘贴不受影响。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 12, height: 18, numChannels: 4)
        ..clear(img.ColorRgba8(230, 90, 120, 120)),
    ),
  );
  Finder key(String value) => find.byKey(ValueKey(value));

  /// 原生侧拦下 Ctrl+V 之后推上来的那条事件:图已经在原生读好了,连位置一起给。
  Future<void> paste(
    WidgetTester tester,
    Offset point, {
    Uint8List? bytes,
    bool bitmap = false,
    List<String> paths = const [],
    String error = '',
  }) async {
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        DesktopImageDropHost.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('paste', {
            'x': point.dx * tester.view.devicePixelRatio,
            'y': point.dy * tester.view.devicePixelRatio,
            'bytes': bytes ?? png,
            'bitmap': bitmap,
            'paths': paths,
            'error': error,
          }),
        ),
        (_) {},
      );
    });
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  Future<void> mount(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopModeProvider.overrideWithValue(true)],
        child: MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('光标所在的那块胜出;连贴两次各自收下原图', (tester) async {
    final reference = <PickedImage>[], assistant = <PickedImage>[];
    var generic = 0;
    final text = TextEditingController();
    addTearDown(text.dispose);
    await mount(
      tester,
      ImageDropRegion(
        label: '普通导入',
        acceptInternal: false,
        onDrop: (_, _) async => generic++,
        child: Row(
          children: [
            Expanded(
              child: ImageDropRegion(
                label: '参考',
                acceptPaste: true,
                multiple: true,
                onDrop: (images, _) async => reference.addAll(images),
                child: Center(
                  child: TextField(
                    key: const ValueKey('reference'),
                    controller: text,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ImageDropRegion(
                label: '助手',
                acceptPaste: true,
                multiple: true,
                onDrop: (images, payload) async {
                  expect(payload.source, kClipboardSource);
                  assistant.addAll(images);
                },
                child: const SizedBox.expand(key: ValueKey('assistant')),
              ),
            ),
          ],
        ),
      ),
    );
    // 焦点在左边那个输入框里,光标压右边那块 —— 归光标那块。
    await tester.tap(key('reference'));
    await tester.pumpAndSettle();
    await paste(tester, tester.getCenter(key('assistant')));
    await paste(tester, tester.getCenter(key('assistant')));
    expect(assistant.map((image) => image.bytes), [png, png]);
    expect(reference, isEmpty);
    expect(generic, 0);
    expect(text.text, isEmpty);

    // 光标挪到左边那块 → 这次归左边。
    await paste(tester, tester.getCenter(key('reference')));
    expect(reference.single.bytes, png);
  });

  testWidgets('藏着的那一页(IndexedStack 后台页)收不到', (tester) async {
    var shown = 0, hidden = 0;
    final page = ValueNotifier(0);
    addTearDown(page.dispose);
    await mount(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: page,
        builder: (_, index, _) => IndexedStack(
          index: index,
          children: [
            ImageDropRegion(
              label: '前台',
              acceptPaste: true,
              onDrop: (_, _) async => shown++,
              child: const SizedBox.expand(key: ValueKey('front')),
            ),
            ImageDropRegion(
              label: '后台',
              acceptPaste: true,
              onDrop: (_, _) async => hidden++,
              child: const SizedBox.expand(key: ValueKey('back')),
            ),
          ],
        ),
      ),
    );
    // 前台那一页收下;报的是后台那一页中心的坐标(两页同尺寸,坐标一样)——
    // 但命中测试只认当前那一页。
    await paste(tester, tester.getCenter(key('front')));
    expect(shown, 1);
    expect(hidden, 0);

    page.value = 1;
    await tester.pumpAndSettle();
    await paste(tester, tester.getCenter(key('back')));
    expect(shown, 1);
    expect(hidden, 1);
  });

  testWidgets('弹层挡住时不往底下塞', (tester) async {
    var imports = 0;
    late BuildContext ctx;
    await mount(
      tester,
      ImageDropRegion(
        label: '导入',
        acceptPaste: true,
        onDrop: (_, _) async => imports++,
        child: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await paste(tester, const Offset(450, 350));
    expect(imports, 1);

    // 弹层盖住整页:光标底下那块接收区命中不到了,这一下谁都不接手 ——
    // 这正是「挡住时不往底下塞」。
    unawaited(
      showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(title: Text('dialog')),
      ),
    );
    await tester.pumpAndSettle();
    await paste(tester, const Offset(450, 350));
    expect(imports, 1);
  });

  testWidgets('代理把它盖不到的那一行指回目标接收区', (tester) async {
    var assistant = 0;
    final dropKey = GlobalKey();
    await mount(
      tester,
      Column(
        children: [
          ImagePasteProxy(
            target: dropKey,
            child: const SizedBox(
              key: ValueKey('header'),
              height: 60,
              width: double.infinity,
            ),
          ),
          Expanded(
            child: ImageDropRegion(
              key: dropKey,
              label: '助手',
              acceptPaste: true,
              onDrop: (_, _) async => assistant++,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
    await paste(tester, tester.getCenter(key('header')));
    expect(assistant, 1);
  });

  testWidgets('原生报错时给一句人话,不静默', (tester) async {
    await mount(
      tester,
      ImageDropRegion(
        label: '助手',
        acceptPaste: true,
        onDrop: (_, _) async {},
        child: const SizedBox.expand(),
      ),
    );
    await paste(tester, const Offset(450, 350), error: 'clipboard_busy');
    expect(find.text('剪贴板暂时被占用，请重试粘贴'), findsOneWidget);
  });

  testWidgets('图片路径形式的粘贴(资源管理器复制的文件)也认', (tester) async {
    final dir = Directory.systemTemp.createTempSync('plana_paste_paths_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/照片.png')..writeAsBytesSync(png);
    final got = <PickedImage>[];
    await mount(
      tester,
      ImageDropRegion(
        label: '助手',
        acceptPaste: true,
        multiple: true,
        onDrop: (images, payload) async {
          expect(payload.source, kClipboardSource);
          got.addAll(images);
        },
        child: const SizedBox.expand(),
      ),
    );
    await paste(tester, const Offset(450, 350), bytes: null, paths: [file.path]);
    expect(got.single.name, '照片.png');
    expect(got.single.bytes, png);
  });
}
