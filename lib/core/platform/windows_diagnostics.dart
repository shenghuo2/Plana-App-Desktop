import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/runtime_diagnostics.dart';

final windowsDiagnostics = WindowsDiagnostics();
final windowsDiagnosticsProvider = Provider((ref) => windowsDiagnostics);

/// The runner owns the preference so it can record a startup failure before
/// Dart starts. Both writers use the directory returned by that same runner.
class WindowsDiagnostics extends ChangeNotifier {
  static const _channel = MethodChannel('plana/diagnostics');
  Directory? _directory;
  bool _enabled = false;
  bool _busy = false;
  bool get enabled => _enabled;
  bool get busy => _busy;

  Future<void> _readStatus() async {
    final status = await _channel.invokeMapMethod<String, Object?>('status');
    final path = status?['directory'];
    if (path is! String || path.isEmpty) {
      throw const FileSystemException('Diagnostic directory unavailable');
    }
    _directory = Directory(path);
    _enabled = status?['enabled'] == true;
  }

  Future<void> initialize() async {
    try {
      await _readStatus();
      if (_enabled) {
        RuntimeDiagnostics.initialize(directory: _directory, shareable: true);
      }
    } on Exception {
      // Even a missing channel or inaccessible profile must allow startup.
    }
  }

  Future<Directory> logDirectory() async {
    if (_directory == null) await _readStatus();
    return _directory!;
  }

  Future<void> setEnabled(bool value) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      final directory = await logDirectory();
      if (value == _enabled) return;
      if (value) {
        await _channel.invokeMethod<void>('setEnabled', true);
        _enabled = true;
        final log = RuntimeDiagnostics.initialize(
          directory: directory,
          shareable: true,
        );
        if (log == null) {
          // Keep the switch aligned with the runner even if rolling back also
          // fails. The user can still turn off the native writer in that case.
          await _channel.invokeMethod<void>('setEnabled', false);
          _enabled = false;
          throw const FileSystemException('Cannot write diagnostic log');
        }
      } else {
        await _channel.invokeMethod<void>('setEnabled', false);
        _enabled = false;
        RuntimeDiagnostics.current?.event('recording-stopped');
        RuntimeDiagnostics.current?.dispose();
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<String>> displayAdapters() async {
    try {
      return await _channel.invokeListMethod<String>('displayAdapters') ?? [];
    } on Exception {
      return [];
    }
  }
}
