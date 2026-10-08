import 'package:flutter_test/flutter_test.dart';

/// Wait for actual disk/engine completion while advancing widget timers.
/// A fixed number of frames cannot guarantee that real IO has finished.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final elapsed = Stopwatch()..start();
  await tester.pump();
  while (!done() && elapsed.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason ?? 'Async work must finish');
}
