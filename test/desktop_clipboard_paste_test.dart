/// 「⌘/Ctrl+V 把剪贴板里的图贴进接收区」的行为。
///
/// 四条底线:
/// - **鼠标底下那块优先**,鼠标不在任何一块上时才看焦点 —— 点过输入框之后把
///   鼠标挪到某张卡上按 ⌘V,图要进那张卡(只看焦点时这一下哪儿都不去);
/// - 剪贴板里只有文本 / 没有接收区 / 那块不收或正忙 → **原样走系统那套文本
///   粘贴**,一下都不能吞;
/// - 光标底下那块明确不收时,不越过它去贴用户没在看着的下一层;
/// - 没开 acceptPaste 的区域既不接收,也不挡住后面那层。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/ui/image_drop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final png = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 20, height: 12)..clear(img.ColorRgb8(20, 90, 220)),
    ),
  );
  var clipboardResponse = <String, Object?>{};
  var clipboardText = '粘贴进来的文字';

  /// 哪一块收下了这一次粘贴。两块接收区的 onDrop 分开记,才验得出「归鼠标那块」。
  late List<String> received;

  setUp(() {
    received = [];
    clipboardResponse = {'image': png, 'format': 'png'};
    clipboardText = '粘贴进来的文字';
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, (call) async {
      if (call.method == 'read') return clipboardResponse;
      return true;
    });
    // Flutter 自带的文本剪贴板:回落那一条要真读到东西,才验得出「没被吞」。
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clipboardText};
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> paste(WidgetTester tester, {bool control = false}) async {
    final modifier = control
        ? LogicalKeyboardKey.controlLeft
        : LogicalKeyboardKey.metaLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(modifier);
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  /// 把鼠标挪到某个点(或挪出窗口,null)。
  Future<void> hover(WidgetTester tester, Offset? at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    if (at == null) {
      await mouse.addPointer(location: Offset.zero);
      await mouse.removePointer();
    } else {
      await mouse.addPointer(location: at);
      await mouse.moveTo(at);
    }
    await tester.pumpAndSettle();
    addTearDown(mouse.removePointer);
  }

  /// 上面是「另一张卡」(`sibling`),下面是主接收区(`region`),输入框在
  /// `region` 里面 —— 与助手对话框同形。焦点默认给输入框。
  Future<(TextEditingController, Rect, Rect)> mount(
    WidgetTester tester, {
    bool siblingEnabled = true,
    bool siblingAcceptsPaste = true,
    bool desktop = true,
  }) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopModeProvider.overrideWithValue(desktop)],
        child: MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: ImageDropRegion(
                    key: const ValueKey('sibling'),
                    label: '用作图生图底图',
                    acceptPaste: siblingAcceptsPaste,
                    enabled: siblingEnabled,
                    onDrop: (images, _) async => received.add('sibling'),
                    child: const ColoredBox(
                      color: Color(0xFFEEEEEE),
                      child: SizedBox.expand(),
                    ),
                  ),
                ),
                Expanded(
                  child: ImageDropRegion(
                    key: const ValueKey('region'),
                    label: '将图片添加到对话框',
                    acceptPaste: true,
                    onDrop: (images, _) async => received.add('region'),
                    child: Column(
                      children: [
                        TextField(
                          key: const ValueKey('field'),
                          controller: controller,
                        ),
                        const SizedBox(height: 240),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    return (
      controller,
      tester.getRect(find.byKey(const ValueKey('sibling'))),
      tester.getRect(find.byKey(const ValueKey('region'))),
    );
  }

  testWidgets('剪贴板里有图:⌘V 把图交给接收区,输入框不动', (tester) async {
    final (controller, _, _) = await mount(tester);
    await paste(tester);

    expect(received, ['region']);
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 上是 Ctrl+V', (tester) async {
    await mount(tester);
    await paste(tester, control: true);

    expect(received, ['region']);
  });

  testWidgets('剪贴板里同时有文本:图让位,文本照常粘进输入框', (tester) async {
    clipboardResponse = {
      'image': png,
      'format': 'png',
      'text': '一段复制来的文字',
    };
    final (controller, _, _) = await mount(tester);
    await paste(tester);

    expect(received, isEmpty);
    expect(controller.text, clipboardText);
  });

  testWidgets('剪贴板里没有图:文本粘贴原样可用', (tester) async {
    clipboardResponse = {'text': '只有文字'};
    final (controller, _, _) = await mount(tester);
    await paste(tester);

    expect(received, isEmpty);
    expect(controller.text, clipboardText);
  });

  testWidgets('光标底下那块正忙时不硬塞,这一下还给文本粘贴', (tester) async {
    final (controller, sibling, _) = await mount(tester, siblingEnabled: false);
    await hover(tester, sibling.center);
    await paste(tester);

    expect(received, isEmpty);
    expect(controller.text, clipboardText);
  });

  // 这一条走 Ctrl+V:它得落到**系统自己那套**绑定上(Linux / Windows 是 Ctrl+V,
  // macOS 上 Flutter 也把 Ctrl+V 映射成粘贴)。拿 ⌘V 在 Linux 上测,是测了个寂寞
  // —— 那边本来就没有这条绑定,粘不出东西不代表我们没拦。
  testWidgets('没开 acceptPaste 的区域既不接收,也不挡住它外面那层', (tester) async {
    final (controller, sibling, _) = await mount(
      tester,
      siblingAcceptsPaste: false,
    );
    // 光标停在不参与粘贴的那块上:对粘贴来说它等于不存在 —— 焦点还在输入框里,
    // 于是照样是该收的那块收(而不是被这块挡成什么都不发生)。
    await hover(tester, sibling.center);
    await paste(tester, control: true);

    expect(received, ['region']);
    expect(controller.text, isEmpty);
  });

  testWidgets('移动端不拦这道快捷键(那边没有键盘,也不该抢系统的粘贴)', (tester) async {
    final (controller, _, _) = await mount(tester, desktop: false);
    await paste(tester, control: true);

    expect(received, isEmpty);
    expect(controller.text, clipboardText);
  });

  testWidgets('应用级导入区(acceptInternal: false)照样收剪贴板来的图', (tester) async {
    // 「不收应用内拖拽」那道闸针对的是画布/历史里拖出来的图;剪贴板来的图没有
    // paths,不该被它一起挡掉 —— 挡掉了,外面这一圈兜底就形同虚设。
    //
    // 光标压在框里而不是靠焦点:这块区域里没有任何可聚焦的东西(真实的应用级
    // 导入区就是裹住整棵界面的,焦点落在里面的输入框上)。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopModeProvider.overrideWithValue(true)],
        child: MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: ImageDropRegion(
              label: '导入图片',
              acceptPaste: true,
              acceptInternal: false,
              onDrop: (images, payload) async {
                received.add('global:${payload.source}');
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await hover(tester, tester.getCenter(find.byType(SizedBox).last));

    await paste(tester);

    expect(received, ['global:clipboard']);
    expect(tester.takeException(), isNull);
  });

  group('鼠标优先、焦点兜底', () {
    testWidgets('鼠标停在另一块上时归鼠标那块(焦点还在下面的输入框里)', (tester) async {
      final (controller, sibling, _) = await mount(tester);
      await hover(tester, sibling.center);

      await paste(tester);

      expect(received, ['sibling']);
      expect(controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('鼠标没进过窗口:退回焦点所在的那块', (tester) async {
      final (controller, _, _) = await mount(tester);
      await hover(tester, null);

      await paste(tester);

      expect(received, ['region']);
      expect(controller.text, isEmpty);
    });

    testWidgets('鼠标停在接收区之间的缝上:退回焦点所在的那块', (tester) async {
      final (controller, sibling, region) = await mount(tester);
      // 两块之间的那一线不属于任何一块(Expanded 之间没有缝时用边线上一点)。
      final seam = Offset(
        sibling.center.dx,
        (sibling.bottom + region.top) / 2,
      );
      await hover(tester, seam);

      await paste(tester);

      expect(received, ['region']);
      expect(controller.text, isEmpty);
    });

    testWidgets('移动端上鼠标悬停也不生效', (tester) async {
      final (controller, sibling, _) = await mount(tester, desktop: false);
      await hover(tester, sibling.center);

      await paste(tester, control: true);

      // 桌面开关关着 → 整条粘贴分发不存在,只剩系统自己的文本粘贴。
      expect(received, isEmpty);
      expect(controller.text, clipboardText);
    });
  });

  group('被藏起来的页面不接手', () {
    testWidgets('保活的页面切走之后(IndexedStack),焦点留在上面也不贴进去', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final page = ValueNotifier(0);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [desktopModeProvider.overrideWithValue(true)],
          child: MaterialApp(
            builder: (_, child) => DesktopImageDropHost(child: child!),
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: page,
                builder: (_, index, _) => IndexedStack(
                  index: index,
                  children: [
                    ImageDropRegion(
                      key: const ValueKey('live'),
                      label: '将图片添加到对话框',
                      acceptPaste: true,
                      onDrop: (_, _) async => received.add('live'),
                      child: Column(
                        children: [
                          TextField(
                            key: const ValueKey('field'),
                            controller: controller,
                          ),
                          const SizedBox(height: 240),
                        ],
                      ),
                    ),
                    const ColoredBox(
                      key: ValueKey('other'),
                      color: Color(0xFF888888),
                      child: SizedBox.expand(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('field')));
      await tester.pumpAndSettle();

      // 切到另一页:接收区还在树里、也有尺寸(IndexedStack 保尺寸),但看不见了。
      page.value = 1;
      await tester.pumpAndSettle();
      await hover(tester, null);

      await paste(tester, control: true);

      expect(received, isEmpty);
      expect(controller.text, isEmpty);
    });

    testWidgets('标签栏上的粘贴由代理指回助手那块', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final dropKey = GlobalKey();
      late Rect headerRect;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [desktopModeProvider.overrideWithValue(true)],
          child: MaterialApp(
            builder: (_, child) => DesktopImageDropHost(child: child!),
            home: Scaffold(
              body: Column(
                children: [
                  // 「标签栏」:在助手页外面,靠 proxy 指回去。宽度要撑满 ——
                  // Column 里的 SizedBox 只给高度的话宽度是 0,打不着。
                  ImagePasteProxy(
                    target: dropKey,
                    child: const SizedBox(
                      key: ValueKey('tab-header'),
                      height: 46,
                      width: double.infinity,
                      child: ColoredBox(color: Color(0xFF334455)),
                    ),
                  ),
                  Expanded(
                    child: ImageDropRegion(
                      key: dropKey,
                      label: '将图片添加到对话框',
                      acceptPaste: true,
                      onDrop: (_, _) async => received.add('assistant'),
                      child: Column(
                        children: [
                          TextField(
                            key: const ValueKey('field'),
                            controller: controller,
                          ),
                          const SizedBox(height: 240),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      headerRect = tester.getRect(find.byKey(const ValueKey('tab-header')));
      await hover(tester, headerRect.center);

      await paste(tester);

      // 光标在标签栏上(助手页外面),这一下仍然归助手 —— 没有代理的话
      // 它哪儿都不去。
      expect(received, ['assistant']);
      expect(controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
