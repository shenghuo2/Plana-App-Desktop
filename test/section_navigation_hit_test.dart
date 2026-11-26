import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/section_navigation.dart';

void main() {
  testWidgets('法典的悬浮标签透传点击和滚轮，拖出刻度立即停止跳转', (tester) async {
    var taps = 0, scrolls = 0;
    final jumps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) scrolls++;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: SectionNavigation<int>(
                  entries: List.generate(80, (i) => i),
                  activeIndex: 3,
                  idOf: (i) => '$i',
                  labelOf: (i) => '分类 $i',
                  onSelect: jumps.add,
                  maxHeight: 180,
                  maxWidth: 300,
                  keyPrefix: 'index',
                  semanticLabel: '导航',
                  describePosition: (i) => '$i',
                  hint: '',
                  ticksOnly: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    Finder key(String value) => find.byKey(ValueKey(value));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final tick = tester.getCenter(key('index-tick-3'));
    await mouse.moveTo(tick);
    await tester.pumpAndSettle();
    final rail = tester.getRect(key('index-tick-navigation'));
    final label = tester.getCenter(key('index-tick-label-3'));
    expect(label.dx, lessThan(rail.left));
    expect(rail.left, closeTo(tester.getRect(key('index-tick-3')).left, .01));

    await tester.sendEventToBinding(
      PointerScrollEvent(position: label, scrollDelta: const Offset(0, 30)),
    );
    await tester.tapAt(label);
    expect(scrolls, 1);
    expect(taps, 1);
    expect(jumps, isEmpty);
    await mouse.down(tick);
    await tester.pump();
    expect(jumps, [3]);
    await mouse.moveTo(Offset(rail.left - 1, rail.bottom - 1));
    await tester.pump(const Duration(milliseconds: 450));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(jumps, [3]);
    expect(key('index-tick-label-3'), findsNothing);
    await mouse.moveTo(tick);
    await tester.pumpAndSettle();
    expect(key('index-tick-label-3'), findsOneWidget);
    await mouse.removePointer();
  });
}
