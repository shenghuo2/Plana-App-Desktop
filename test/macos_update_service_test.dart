import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/update/macos_update_service.dart';
import 'package:plana_app/features/update/update_service.dart';

GithubRelease _release(
  List<int> bytes, {
  String? digest,
  bool checksum = false,
}) {
  const name = 'Plana-macOS-x64.dmg';
  const url =
      'https://github.com/$kGithubRepo/releases/download/v1.1.1-desktop.46/$name';
  return GithubRelease(
    tag: 'v1.1.1-desktop.46',
    name: '',
    notes: '',
    url: url,
    prerelease: false,
    assets: [
      GithubAsset(
        name: name,
        url: url,
        size: bytes.length,
        digest: checksum ? null : digest ?? 'sha256:${sha256.convert(bytes)}',
      ),
      if (checksum)
        const GithubAsset(name: '$name.sha256', url: '$url.sha256', size: 90),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_update_service');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  const bytes = [1, 2, 3, 4, 5, 6];

  test('优先选同架构 DMG,不选另一架构或 PKG', () {
    const release = GithubRelease(
      tag: '',
      name: '',
      notes: '',
      url: '',
      prerelease: false,
      assets: [
        GithubAsset(name: 'Plana-macOS-arm64.dmg', url: 'a', size: 1),
        GithubAsset(name: 'Plana-macOS-universal.dmg', url: 'u', size: 1),
        GithubAsset(name: 'Plana-macOS-x64.dmg', url: 'x', size: 1),
        GithubAsset(name: 'Plana-macOS.pkg', url: 'p', size: 1),
      ],
    );
    expect(macOSUpdateAsset(release, 'arm64')?.url, 'a');
    expect(macOSUpdateAsset(release, 'x64')?.url, 'x');
    expect(macOSUpdateAsset(_release(bytes), 'arm64'), isNull);
  });

  test('流式下载核对大小和 SHA,已校验的缓存可复用且不再请求网络', () async {
    var calls = 0;
    final progress = <int>[];
    final service = MacOSUpdateService(
      directory: root,
      clientFactory: () => MockClient((request) async {
        calls++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    final result = await service.download(
      _release(bytes),
      architecture: 'x64',
      onProgress: (received, total) {
        expect(total, bytes.length);
        progress.add(received);
      },
    );
    expect(await result.file.readAsBytes(), bytes);
    expect(result.sha256, sha256.convert(bytes).toString());
    expect(progress.last, bytes.length);
    final reused = await service.download(
      _release(bytes),
      architecture: 'x64',
      onProgress: (_, _) {},
    );
    expect(reused.file.path, result.file.path);
    expect(calls, 1);
  });

  for (final wrong in [
    [1, 2],
    [6, 5, 4, 3, 2, 1],
  ]) {
    test('长度或摘要不符时不产生可安装文件 (${wrong.length} 字节)', () async {
      final service = MacOSUpdateService(
        directory: root,
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes(wrong, 200)),
      );
      await expectLater(
        service.download(
          _release(bytes),
          architecture: 'x64',
          onProgress: (_, _) {},
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(
        root.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.dmg') || f.path.endsWith('.part'),
        ),
        isEmpty,
      );
    });
  }

  test('GitHub 未提供 digest 时读同名校验文件', () async {
    final requests = <Uri>[];
    final service = MacOSUpdateService(
      directory: root,
      clientFactory: () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('.sha256')) {
          return http.Response(
            '${sha256.convert(bytes)}  Plana-macOS-x64.dmg\n',
            200,
          );
        }
        return http.Response.bytes(bytes, 200);
      }),
    );
    await service.download(
      _release(bytes, checksum: true),
      architecture: 'x64',
      onProgress: (_, _) {},
    );
    expect(requests.length, 2);
    expect(requests.first.path.endsWith('.sha256'), isTrue);
  });

  test('取消后清理未完成文件,可以重试', () async {
    final service = MacOSUpdateService(
      directory: root,
      clientFactory: () =>
          MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    await expectLater(
      service.download(
        _release(bytes),
        architecture: 'x64',
        onProgress: (_, _) => service.cancelDownload(),
      ),
      throwsA(isA<UpdateDownloadCancelled>()),
    );
    expect(
      root.listSync().whereType<File>().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
    final retried = await service.download(
      _release(bytes),
      architecture: 'x64',
      onProgress: (_, _) {},
    );
    expect(await retried.file.exists(), isTrue);
  });

  test('拒绝非本 fork 的下载地址', () async {
    const release = GithubRelease(
      tag: 'v2.0.0',
      name: '',
      notes: '',
      url: '',
      prerelease: false,
      assets: [
        GithubAsset(
          name: 'Plana-macOS-x64.dmg',
          url: 'https://example.com/package.dmg',
          size: 1,
          digest:
              'sha256:0000000000000000000000000000000000000000000000000000000000000000',
        ),
      ],
    );
    final service = MacOSUpdateService(
      directory: root,
      clientFactory: () => MockClient((_) async => throw StateError('不该请求')),
    );
    await expectLater(
      service.download(release, architecture: 'x64', onProgress: (_, _) {}),
      throwsA(isA<UpdateException>()),
    );
  });

  test('拒绝从 DMG 或 App Translocation 更新,允许用户重命名应用', () {
    expect(
      MacOSUpdateService.appBundle(
        '/Volumes/Plana/Plana App.app/Contents/MacOS/Plana App',
      ),
      isNull,
    );
    expect(
      MacOSUpdateService.appBundle(
        '/private/AppTranslocation/a/Plana App.app/Contents/MacOS/Plana App',
      ),
      isNull,
    );
    expect(
      MacOSUpdateService.appBundle(
        '/Applications/我的 Plana.app/Contents/MacOS/Plana App',
      ),
      '/Applications/我的 Plana.app',
    );
  });

  Future<DownloadedMacOSUpdate> downloaded() async {
    final file = File(p.join(root.path, 'update.dmg'));
    await file.writeAsBytes(bytes);
    final release = _release(bytes);
    return DownloadedMacOSUpdate(
      file: file,
      release: release,
      asset: release.assets.first,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  test('助手验证失败时不退出应用', () async {
    final bundle = Directory(p.join(root.path, 'Plana App.app'));
    await bundle.create();
    var exited = false;
    var flushed = false;
    final service = MacOSUpdateService(
      directory: root,
      executablePath: '${bundle.path}/Contents/MacOS/Plana App',
      processRunner: (_, _) async => ProcessResult(0, 0, '', ''),
      processStarter: (_, _) => Process.start('/bin/false', []),
      exitApp: (_) {
        exited = true;
      },
    );
    await expectLater(
      service.install(
        await downloaded(),
        architecture: 'x64',
        beforeExit: () async {
          flushed = true;
        },
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(exited, isFalse);
    expect(flushed, isFalse);
    expect(await bundle.exists(), isTrue);
  }, skip: Platform.isWindows);

  test('准备成功后落盘失败则终止助手并保留应用', () async {
    final bundle = Directory(p.join(root.path, 'Plana App.app'));
    await bundle.create();
    var exited = false;
    Process? helper;
    final service = MacOSUpdateService(
      directory: root,
      executablePath: '${bundle.path}/Contents/MacOS/Plana App',
      processRunner: (_, _) async => ProcessResult(0, 0, '', ''),
      processStarter: (_, args) async {
        await File(
          p.join(File(args.single).parent.path, 'ready'),
        ).writeAsString('ready');
        return helper = await Process.start('/bin/sleep', ['20']);
      },
      exitApp: (_) {
        exited = true;
      },
    );
    await expectLater(
      service.install(
        await downloaded(),
        architecture: 'x64',
        beforeExit: () async {
          throw const UpdateException('任务尚未结束');
        },
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(await helper!.exitCode, isNot(0));
    expect(exited, isFalse);
    expect(await bundle.exists(), isTrue);
  }, skip: Platform.isWindows);

  test('首帧回执只确认预期版本,更新结果只消费一次', () async {
    final work = Directory(p.join(root.path, 'install'));
    await work.create();
    final startup = File(p.join(work.path, 'attempt.started'));
    final pending = File(p.join(work.path, 'pending.json'));
    final service = MacOSUpdateService(directory: root);
    await pending.writeAsString(
      jsonEncode({'version': '9.9.9', 'startup': startup.path}),
    );
    expect(await service.acknowledgeStartup(), isNull);
    expect(await startup.exists(), isFalse);
    await pending.writeAsString(
      jsonEncode({'version': kAppVersion, 'startup': startup.path}),
    );
    await service.acknowledgeStartup();
    expect((await startup.readAsString()).trim(), '$pid');
    await File(
      p.join(work.path, 'result.json'),
    ).writeAsString('{"success":false}');
    expect(await service.acknowledgeStartup(), isFalse);
    expect(await service.acknowledgeStartup(), isNull);
  });

  test('退出前等待工作台和设置真正落盘', () async {
    final stores = await AppStores.open(rootOverride: root);
    stores.workspace.schedule(
      GenerateState.initial().copyWith(prompt: '更新前草稿'),
      idSeq: 101,
    );
    unawaited(stores.prefs.write(key: 'pending_setting', value: 'saved'));
    await stores.flushForExit();
    await stores.workspace.load();
    expect(stores.workspace.initial?.prompt, '更新前草稿');
    final settings =
        jsonDecode(
              await File(p.join(root.path, 'settings.json')).readAsString(),
            )
            as Map;
    expect(settings['pending_setting'], 'saved');
  });
}
