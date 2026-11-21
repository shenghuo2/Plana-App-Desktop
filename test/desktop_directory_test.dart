import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/core/platform/desktop_directory.dart';

class _Explorer extends Fake implements Process {
  @override
  Future<int> get exitCode =>
      throw StateError('Must not wait for Explorer exit');
}

void main() {
  late Directory fixture;
  late DesktopDirectoryLauncher launcher;
  final calls =
      <({String executable, List<String> arguments, ProcessStartMode mode})>[];
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('plana_open_folder_');
    calls.clear();
    launcher = DesktopDirectoryLauncher(
      startProcess:
          (executable, arguments, {mode = ProcessStartMode.normal}) async {
            calls.add((
              executable: executable,
              arguments: arguments,
              mode: mode,
            ));
            return _Explorer();
          },
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'creates directory and hands a literal path to detached system Explorer',
    () async {
      final root = Directory(p.join(fixture.path, '作品 空格, & % #', 'output'));
      await launcher.open(root, isCurrent: () => true);
      expect(root.existsSync(), isTrue);
      expect(calls, hasLength(1));
      expect(
        calls.single.executable,
        p.join(Platform.environment['SystemRoot']!, 'explorer.exe'),
      );
      expect(calls.single.arguments, [root.path]);
      expect(calls.single.mode, ProcessStartMode.detached);
    },
    skip: !Platform.isWindows,
  );

  test(
    'file in output path fails without launching or altering the file',
    () async {
      final file = File(p.join(fixture.path, 'output'))
        ..writeAsStringSync('keep');
      for (final path in [file.path, p.join(file.path, 'child')]) {
        await expectLater(
          launcher.open(Directory(path), isCurrent: () => true),
          throwsA(isA<FileSystemException>()),
        );
      }
      expect(file.readAsStringSync(), 'keep');
      expect(calls, isEmpty);
    },
  );

  test(
    'expired preparation does not create a directory or open Explorer',
    () async {
      final root = Directory(p.join(fixture.path, 'output'));
      await launcher.open(root, isCurrent: () => false);
      expect(root.existsSync(), isFalse);
      expect(calls, isEmpty);
    },
  );

  test('Explorer start failure is propagated for a retry', () async {
    final failing = DesktopDirectoryLauncher(
      startProcess:
          (executable, arguments, {mode = ProcessStartMode.normal}) async {
            throw ProcessException(executable, arguments, 'denied');
          },
    );
    final root = Directory(p.join(fixture.path, 'output'));
    await expectLater(
      failing.open(root, isCurrent: () => true),
      throwsA(isA<ProcessException>()),
    );
    await launcher.open(root, isCurrent: () => true);
    expect(calls, hasLength(1));
  }, skip: !Platform.isWindows);
}
