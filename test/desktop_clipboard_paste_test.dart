/// 「⌘/Ctrl+V 把剪贴板里的图贴进这块区域」的行为。
///
/// 三条底线:
/// - 剪贴板里有图(且没有能用的文本)→ 图归这块区域;
/// - 剪贴板里只有文本 / 这块区域不收 / 这块区域正忙 → **原样走系统那套文本粘贴**,
///   一下都不能吞;
/// - 没开 acceptPaste 的区域,不该拦这道快捷键。
library;


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';

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
  late List<List<PickedImage>> dropped;

  setUp(() {
    dropped = [];
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

  Future<void> paste(
    WidgetTester tester, {
    bool control = false,
  }) async {
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

  Future<TextEditingController> mount(
    WidgetTester tester, {
    bool acceptPaste = true,
    bool enabled = true,
    bool desktop = true,
  }) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopModeProvider.overrideWithValue(desktop)],
        child: MaterialApp(
          home: Scaffold(
            body: ImageDropRegion(
              label: '将图片添加到对话框',
              acceptPaste: acceptPaste,
              enabled: enabled,
              onDrop: (images, _) async => dropped.add(images),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('field'),
                    controller: controller,
                  ),
                  const SizedBox(height: 200),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('剪贴板里有图:⌘V 把图交给焦点所在的区域,输入框不动', (tester) async {
    final controller = await mount(tester);
    await paste(tester);

    expect(dropped, hasLength(1));
    expect(dropped.single.single.bytes, png);
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 上是 Ctrl+V', (tester) async {
    await mount(tester);
    await paste(tester, control: true);

    expect(dropped, hasLength(1));
    expect(dropped.single.single.bytes, png);
  });

  testWidgets('剪贴板里同时有文本:图让位,文本照常粘进输入框', (tester) async {
    clipboardResponse = {
      'image': png,
      'format': 'png',
      'text': '一段复制来的文字',
    };
    final controller = await mount(tester);
    await paste(tester);

    expect(dropped, isEmpty);
    expect(controller.text, clipboardText);
  });

  testWidgets('剪贴板里没有图:文本粘贴原样可用', (tester) async {
    clipboardResponse = {'text': '只有文字'};
    final controller = await mount(tester);
    await paste(tester);

    expect(dropped, isEmpty);
    expect(controller.text, clipboardText);
  });

  testWidgets('区域正忙(不收)时也让给文本粘贴', (tester) async {
    final controller = await mount(tester, enabled: false);
    await paste(tester);

    expect(dropped, isEmpty);
    expect(controller.text, clipboardText);
  });

  // 这一条走 Ctrl+V:它得落到**系统自己那套**绑定上(Linux / Windows 是 Ctrl+V,
  // macOS 上 Flutter 也把 Ctrl+V 映射成粘贴)。拿 ⌘V 在 Linux 上测,是测了个寂寞
  // —— 那边本来就没有这条绑定,粘不出东西不代表我们没拦。
  testWidgets('没开 acceptPaste 的区域不拦这道快捷键', (tester) async {
    final controller = await mount(tester, acceptPaste: false);
    await paste(tester, control: true);

    expect(dropped, isEmpty);
    expect(controller.text, clipboardText);
  });

  testWidgets('移动端不拦这道快捷键(那边没有键盘,也不该抢系统的粘贴)', (tester) async {
    final controller = await mount(tester, desktop: false);
    await paste(tester, control: true);

    expect(dropped, isEmpty);
    expect(controller.text, clipboardText);
  });
}
