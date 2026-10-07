import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_info.dart';
import '../../core/store/atomic_file.dart';
import 'macos_update_script.dart';
import 'update_service.dart';

class UpdateDownloadCancelled implements Exception {}

class DownloadedMacOSUpdate {
  const DownloadedMacOSUpdate({
    required this.file,
    required this.release,
    required this.asset,
    required this.sha256,
  });
  final File file;
  final GithubRelease release;
  final GithubAsset asset;
  final String sha256;
}

GithubAsset? macOSUpdateAsset(GithubRelease release, String architecture) {
  final candidates = release.assets
      .where(
        (a) =>
            a.name.toLowerCase().endsWith('.dmg') &&
            a.matchesArchitecture(architecture) &&
            a.url.isNotEmpty &&
            a.size > 0,
      )
      .toList();
  int rank(GithubAsset a) {
    final name = a.name.toLowerCase();
    if (name.contains(architecture) ||
        (architecture == 'x64' && name.contains('x86_64'))) {
      return 0;
    }
    return name.contains('universal') ? 1 : 2;
  }

  candidates.sort((a, b) => rank(a).compareTo(rank(b)));
  return candidates.firstOrNull;
}

/// 用户点击下载后校验 DMG;独立助手验证、暂存成功后才退出当前应用。
class MacOSUpdateService {
  MacOSUpdateService({
    Directory? directory,
    String? executablePath,
    http.Client Function()? clientFactory,
    Future<Process> Function(String, List<String>)? processStarter,
    Future<ProcessResult> Function(String, List<String>)? processRunner,
    void Function(int)? exitApp,
  }) : _directoryOverride = directory,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _clientFactory = clientFactory ?? http.Client.new,
       _processStarter =
           processStarter ?? ((cmd, args) => Process.start(cmd, args)),
       _processRunner =
           processRunner ?? ((cmd, args) => Process.run(cmd, args)),
       _exitApp = exitApp ?? exit;

  final Directory? _directoryOverride;
  final String _executablePath;
  final http.Client Function() _clientFactory;
  final Future<Process> Function(String, List<String>) _processStarter;
  final Future<ProcessResult> Function(String, List<String>) _processRunner;
  final void Function(int) _exitApp;
  http.Client? _client;
  bool _cancelled = false;

  Future<Directory> directory() async =>
      _directoryOverride ??
      Directory(
        p.join((await getApplicationSupportDirectory()).path, 'updates'),
      );

  static String? appBundle(String executable) {
    final marker = executable.indexOf('.app/Contents/MacOS/');
    if (marker < 0) return null;
    final path = executable.substring(0, marker + 4);
    if (path.startsWith('/Volumes/') || path.contains('/AppTranslocation/')) {
      return null;
    }
    return path;
  }

  void cancelDownload() {
    _cancelled = true;
    _client?.close();
  }

  Future<DownloadedMacOSUpdate> download(
    GithubRelease release, {
    required String architecture,
    required void Function(int received, int total) onProgress,
  }) async {
    final asset = macOSUpdateAsset(release, architecture);
    if (asset == null) throw const UpdateException('此版本没有适合当前 Mac 的 DMG');
    if (_client != null) throw const UpdateException('更新包正在下载');
    final client = _clientFactory();
    _client = client;
    _cancelled = false;
    File? partial;
    IOSink? sink;
    try {
      final root = await directory();
      await root.create(recursive: true);
      final safeVersion = release.tag.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final file = File(p.join(root.path, '$safeVersion-$architecture.dmg'));
      final part = partial = File('${file.path}.part');
      final expected = await _expectedSha(client, release, asset);
      if (await _valid(file, asset, expected)) {
        onProgress(asset.size, asset.size);
        return DownloadedMacOSUpdate(
          file: file,
          release: release,
          asset: asset,
          sha256: expected,
        );
      }
      final response = await client
          .send(http.Request('GET', _downloadUri(asset.url)))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw UpdateException('下载更新失败(HTTP ${response.statusCode})');
      }
      if (response.contentLength != null &&
          response.contentLength != asset.size) {
        throw const UpdateException('更新包大小与发布信息不符');
      }
      sink = part.openWrite();
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (_cancelled) throw UpdateDownloadCancelled();
        received += chunk.length;
        if (received > asset.size) throw const UpdateException('更新包大小与发布信息不符');
        sink.add(chunk);
        onProgress(received, asset.size);
      }
      await sink.close();
      sink = null;
      if (_cancelled) throw UpdateDownloadCancelled();
      if (!await _valid(part, asset, expected)) {
        throw const UpdateException('更新包不完整或校验失败,请重新下载');
      }
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
      return DownloadedMacOSUpdate(
        file: file,
        release: release,
        asset: asset,
        sha256: expected,
      );
    } catch (e) {
      if (_cancelled) throw UpdateDownloadCancelled();
      if (e is UpdateException) rethrow;
      throw const UpdateException('下载更新失败,请检查网络后重试');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } finally {
        client.close();
        _client = null;
      }
    }
  }

  Uri _downloadUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/$kGithubRepo/releases/download/')) {
      throw const UpdateException('更新包下载地址不属于本应用的发布仓库');
    }
    return uri;
  }

  Future<String> _expectedSha(
    http.Client client,
    GithubRelease release,
    GithubAsset asset,
  ) async {
    final digest = asset.digest;
    if (digest != null &&
        RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      return digest.substring(7).toLowerCase();
    }
    final checksum = release.assets
        .where((a) => a.name == '${asset.name}.sha256')
        .firstOrNull;
    if (checksum == null || checksum.size > 16384) {
      throw const UpdateException('发布版缺少更新包校验信息,请从发布页下载');
    }
    final response = await client
        .send(http.Request('GET', _downloadUri(checksum.url)))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw const UpdateException('无法读取更新包校验信息');
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 16384) throw const UpdateException('更新包校验信息格式异常');
    }
    for (final line in utf8.decode(bytes).split('\n')) {
      final match = RegExp(
        r'^([a-fA-F0-9]{64})\s+\*?(.+)$',
      ).firstMatch(line.trim());
      if (match != null && match.group(2) == asset.name) {
        return match.group(1)!.toLowerCase();
      }
    }
    throw const UpdateException('更新包校验信息格式异常');
  }

  Future<bool> _valid(File file, GithubAsset asset, String expected) async =>
      await file.exists() &&
      await file.length() == asset.size &&
      (await sha256.bind(file.openRead()).first).toString() == expected;

  Future<void> install(
    DownloadedMacOSUpdate update, {
    required String architecture,
    required Future<void> Function() beforeExit,
  }) async {
    if (!await _valid(update.file, update.asset, update.sha256)) {
      throw const UpdateException('更新包已损坏,请重新下载');
    }
    final bundle = appBundle(_executablePath);
    if (bundle == null || !await Directory(bundle).exists()) {
      throw const UpdateException('请将应用移到“应用程序”或其他可写目录后更新');
    }
    final writable = await _processRunner('/bin/test', [
      '-w',
      p.dirname(bundle),
    ]);
    if (writable.exitCode != 0) {
      throw const UpdateException('当前应用目录不可写,请移到用户的“应用程序”目录后更新');
    }
    final root = await directory();
    final work = Directory(p.join(root.path, 'install'));
    await work.create(recursive: true);
    final token =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final startup = p.join(work.path, '$token.started');
    final ready = File(p.join(work.path, 'ready'));
    if (await ready.exists()) await ready.delete();
    await writeStringAtomic(
      File(p.join(work.path, 'pending.json')),
      jsonEncode({
        'version': update.release.tag
            .replaceFirst(RegExp(r'^[vV]'), '')
            .split('+')
            .first,
        'startup': startup,
      }),
    );
    final script = File(p.join(work.path, 'install.sh'));
    await script.writeAsString(
      MacOSUpdateScript.build(
        appPid: pid,
        version: update.release.tag,
        architecture: architecture,
        dmgPath: update.file.path,
        targetApp: bundle,
        workDirectory: work.path,
        stagedApp: p.join(p.dirname(bundle), '.Plana-update-$token.app'),
        backupApp: p.join(p.dirname(bundle), '.Plana-backup-$token.app'),
        startupFile: startup,
      ),
      flush: true,
    );
    Process? helper;
    try {
      helper = await _processStarter('/bin/bash', [script.path]);
      unawaited(helper.stdout.drain<void>());
      unawaited(helper.stderr.drain<void>());
      int? helperExit;
      unawaited(
        helper.exitCode.then((code) {
          helperExit = code;
        }),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!await ready.exists()) {
        if (helperExit != null) {
          throw const UpdateException('更新程序未能验证应用,当前版本已保留');
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const UpdateException('准备更新超时,当前版本已保留');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await beforeExit();
      _exitApp(0);
    } catch (e) {
      helper?.kill();
      if (helper != null) await helper.exitCode;
      if (e is UpdateException) rethrow;
      throw const UpdateException('无法启动更新程序,当前版本已保留');
    }
  }

  /// AppShell 首帧出现后回执;帮助脚本确认新的 Flutter 应用确实启动了。
  Future<bool?> acknowledgeStartup() async {
    final root = await directory();
    final work = Directory(p.join(root.path, 'install'));
    final pending = File(p.join(work.path, 'pending.json'));
    if (await pending.exists()) {
      try {
        final json = jsonDecode(await pending.readAsString()) as Map;
        final startup = json['startup'] as String;
        if (json['version'] == kAppVersion && p.dirname(startup) == work.path) {
          await writeStringAtomic(File(startup), '$pid\n');
        }
      } catch (_) {}
    }
    final result = File(p.join(work.path, 'result.json'));
    if (!await result.exists()) return null;
    try {
      final json = jsonDecode(await result.readAsString()) as Map;
      return json['success'] == true;
    } finally {
      await result.delete();
    }
  }
}
