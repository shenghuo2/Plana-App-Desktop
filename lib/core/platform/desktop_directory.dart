import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

typedef DirectoryProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      ProcessStartMode mode,
    });

final desktopDirectoryLauncherProvider = Provider<DesktopDirectoryLauncher>(
  (ref) => DesktopDirectoryLauncher(),
);

class DesktopDirectoryLauncher {
  DesktopDirectoryLauncher({DirectoryProcessStarter? startProcess})
    : _startProcess = startProcess ?? Process.start;

  final DirectoryProcessStarter _startProcess;

  Future<void> open(
    Directory directory, {
    required bool Function() isCurrent,
  }) async {
    final root = Directory(p.normalize(p.absolute(directory.path)));
    // Use async filesystem calls: an unavailable drive must not block the UI.
    await _checkDirectory(root);
    if (!isCurrent()) return;
    await root.create(recursive: true);
    await _checkDirectory(root);
    if (!isCurrent()) return;
    if (Platform.isWindows) {
      final windows =
          Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
      if (windows == null || !p.isAbsolute(windows)) {
        throw const FileSystemException('无法定位 Windows 资源管理器');
      }
      // url_launcher calls ShellExecuteW on the platform thread. Explorer can
      // stall that call (e.g. while negotiating with an existing shell window).
      // Launch the system executable directly, without a shell command or an
      // exitCode wait; an Explorer window may stay open indefinitely.
      await _startProcess(p.join(windows, 'explorer.exe'), [
        root.path,
      ], mode: ProcessStartMode.detached);
    } else {
      final opened = await launchUrl(
        Uri.directory(root.path),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw FileSystemException('无法打开作品文件夹', root.path);
    }
  }

  Future<void> _checkDirectory(Directory directory) async {
    var path = directory.path;
    while (true) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw FileSystemException('作品路径不能是链接或文件', path);
      }
      final parent = p.dirname(path);
      if (parent == path) return;
      path = parent;
    }
  }
}
