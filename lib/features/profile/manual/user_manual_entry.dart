import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/app_info.dart';
import '../../../core/platform/desktop_directory.dart';
import '../../../l10n/l10n.dart';
import '../widgets/settings_ui.dart';
import 'manual_library.dart';

class UserManualEntry extends StatefulWidget {
  const UserManualEntry({super.key});

  @override
  State<UserManualEntry> createState() => _UserManualEntryState();
}

class _UserManualEntryState extends State<UserManualEntry> {
  static const _host = MethodChannel('plana/user_manual');
  ManualLibrary? _library;
  bool _active = false;
  bool _saving = false;

  Future<void> _open() async {
    if (_active || !mounted) return;
    _active = true;
    _host.setMethodCallHandler(_handle);
    final dark = Theme.of(context).brightness == Brightness.dark;
    try {
      final support = await getApplicationSupportDirectory();
      final cache = await getApplicationCacheDirectory();
      final library = ManualLibrary(
        Directory(p.join(support.path, 'user-manual')),
      );
      await library.prepare();
      if (!mounted) return;
      _library = library;
      await _host.invokeMethod<void>('open', [
        p.join(cache.path, 'manual-webview'),
        library.media.path,
        dark,
      ]);
    } catch (e) {
      if (mounted && _active) await _failed(e.toString());
    }
  }

  Future<void> _close() async {
    if (!_active) return;
    _active = false;
    _host.setMethodCallHandler(null);
    final library = _library;
    _library = null;
    try {
      await _host.invokeMethod<void>('close');
    } on PlatformException {
      // Ignore host channel teardown failures when the window/plugin is already gone.
    } on MissingPluginException {
      // Non-Windows tests or headless environments may not register this channel.
    } finally {
      try {
        await library?.close();
      } on Exception {
        // Ignore cleanup failures during widget disposal.
      }
    }
  }

  Future<void> _failed(String detail) async {
    await _close();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.userManual),
        content: SelectableText(
          '无法打开使用手册。请检查 Microsoft Edge WebView2 运行时及手册文件。\n\n$detail',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'failed') {
      if (mounted && _active) unawaited(_failed(call.arguments.toString()));
      return null;
    }
    if (call.method != 'request') throw MissingPluginException();
    Object? id;
    Object? value;
    try {
      final raw = call.arguments;
      if (raw is! String) throw const FormatException('无法识别手册请求。');
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('无法识别手册请求。');
      }
      id = decoded['id'];
      final library = _library;
      if (library == null) throw const FormatException('手册已关闭。');
      switch (decoded['method']) {
        case 'load':
          value = {...await library.load(), 'version': kAppVersion};
        case 'save':
          if (_saving) throw const FormatException('正在保存上一份修改。');
          _saving = true;
          try {
            value = await library.save(decoded['page'] as Map<String, dynamic>);
          } finally {
            _saving = false;
          }
        case 'media':
          final result = await FilePicker.platform.pickFiles(
            dialogTitle: '插入手册素材',
            type: FileType.custom,
            allowedExtensions: [...manualImageTypes, ...manualVideoTypes],
          );
          final path = result?.files.firstOrNull?.path;
          if (mounted && path != null) value = await library.stage(File(path));
        case 'discard':
          await library.discardStaged();
        case 'folder':
          await DesktopDirectoryLauncher().open(
            library.root,
            isCurrent: () => mounted,
          );
        case 'back':
          await _close();
        default:
          throw const FormatException('无法识别手册操作。');
      }
      return jsonEncode({'id': id, 'value': value});
    } catch (e) {
      return jsonEncode({
        'id': id,
        'error': e is FormatException ? e.message : e.toString(),
      });
    }
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsRow(
    icon: Icons.auto_stories_outlined,
    title: context.l10n.userManual,
    onTap: _open,
  );
}
