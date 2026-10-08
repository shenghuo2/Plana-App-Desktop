import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plana_app/features/update/macos_update_script.dart';

void main() {
  group('macOS 更新助手 (macOS 工具由测试替身替代)', () {
    late Directory root;
    late Directory bundle;
    late Directory candidate;
    late Directory work;
    late File startup;
    late File script;
    late int oldPid;
    final commands = <String, String>{};

    Future<File> executable(String name, String text) async {
      final file = File(p.join(root.path, name));
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
      await Process.run('/bin/chmod', ['+x', file.path]);
      return file;
    }

    Future<void> app(
      Directory directory, {
      required bool updated,
      bool starts = true,
      String bundleId = 'com.sora214.plana.app',
    }) async {
      final info = File(p.join(directory.path, 'Contents', 'Info.plist'));
      await info.parent.create(recursive: true);
      await info.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundleId</string>
<key>CFBundleExecutable</key><string>Plana App</string>
<key>CFBundleShortVersionString</key><string>1.1.1.${updated ? 46 : 45}</string>
<key>CFBundleVersion</key><string>${updated ? 65 : 64}</string>
</dict></plist>''');
      final binary = File(
        p.join(directory.path, 'Contents', 'MacOS', 'Plana App'),
      );
      await binary.parent.create();
      await binary.writeAsString(
        starts
            ? r'''#!/bin/bash
printf '%s\n' "$$" > "$PLANA_TEST_STARTUP"
exec /bin/sleep 30
'''
            : '#!/bin/bash\nexit 1\n',
      );
      await Process.run('/bin/chmod', ['+x', binary.path]);
      await File(
        p.join(directory.path, 'version.txt'),
      ).writeAsString(updated ? 'new' : 'old');
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp("plana update's ");
      bundle = Directory(p.join(root.path, '我的 Plana.app'));
      candidate = Directory(
        p.join(root.path, 'fixture', 'Plana App Desktop.app'),
      );
      work = Directory(p.join(root.path, 'work'));
      startup = File(p.join(work.path, 'startup'));
      await app(bundle, updated: false);
      await app(candidate, updated: true);
      final old = await Process.start('/bin/true', []);
      oldPid = old.pid;
      await old.exitCode;
      commands.clear();
      commands['/usr/bin/hdiutil'] = (await executable(
        'bin/hdiutil',
        r'''#!/bin/bash
if [[ "$1" == attach ]]; then
  mount="${@: -1}"
  /bin/cp -R "$PLANA_TEST_CANDIDATE" "$mount/"
fi
''',
      )).path;
      commands['/usr/libexec/PlistBuddy'] = (await executable(
        'bin/plist',
        r'''#!/usr/bin/env python3
import plistlib,sys
with open(sys.argv[3], 'rb') as f:
    print(plistlib.load(f)[sys.argv[2].split(':')[-1]])
''',
      )).path;
      commands['/usr/bin/lipo'] = (await executable('bin/lipo', r'''#!/bin/bash
set -euo pipefail
if [[ "$#" -ne 3 || "$2" != -verify_arch ]]; then
  printf 'Expected lipo <input_file> -verify_arch <architecture>\n' >&2
  exit 2
fi
[[ -f "$1" ]]
[[ "$3" == "$PLANA_TEST_AVAILABLE_ARCH" ]]
''')).path;
      commands['/usr/bin/codesign'] = (await executable(
        'bin/codesign',
        r'''#!/bin/bash
[[ "${PLANA_TEST_BAD_SIGN:-0}" != 1 ]]
''',
      )).path;
      commands['/usr/bin/ditto'] = (await executable(
        'bin/ditto',
        r'''#!/bin/bash
/bin/cp -R "$1" "$2"
''',
      )).path;
      commands['/usr/bin/open'] = (await executable('bin/open', r'''#!/bin/bash
printf '%s\n' "$1" > "$PLANA_TEST_OPENED"
''')).path;
      script = File(p.join(root.path, 'update.sh'));
    });
    tearDown(() async {
      if (await startup.exists()) {
        final newPid = int.tryParse((await startup.readAsString()).trim());
        if (newPid != null) Process.killPid(newPid);
      }
      // cleanup removes the startup marker, so the success fixture records its PID separately.
      final pidFile = File(p.join(root.path, 'child.pid'));
      if (await pidFile.exists()) {
        Process.killPid(int.parse((await pidFile.readAsString()).trim()));
      }
      await root.delete(recursive: true);
    });

    Future<ProcessResult> run({
      bool badSignature = false,
      String architecture = 'x64',
      String availableArchitecture = 'x86_64',
    }) async {
      var text = MacOSUpdateScript.build(
        appPid: oldPid,
        version: 'v1.1.1-desktop.46+65',
        architecture: architecture,
        dmgPath: p.join(root.path, 'update.dmg'),
        targetApp: bundle.path,
        workDirectory: work.path,
        stagedApp: p.join(root.path, '.staged.app'),
        backupApp: p.join(root.path, '.backup.app'),
        startupFile: startup.path,
        startupTimeout: 3,
      );
      for (final command in commands.entries) {
        text = text.replaceAll(
          command.key,
          MacOSUpdateScript.quote(command.value),
        );
      }
      await script.writeAsString(text);
      final syntax = await Process.run('/bin/bash', ['-n', script.path]);
      expect(syntax.exitCode, 0, reason: '${syntax.stderr}');
      return Process.run(
        '/bin/bash',
        [script.path],
        environment: {
          'PLANA_TEST_CANDIDATE': candidate.path,
          'PLANA_TEST_STARTUP': startup.path,
          'PLANA_TEST_OPENED': p.join(root.path, 'opened'),
          'PLANA_TEST_BAD_SIGN': badSignature ? '1' : '0',
          'PLANA_TEST_AVAILABLE_ARCH': availableArchitecture,
        },
      );
    }

    Future<Map> result() async =>
        jsonDecode(await File(p.join(work.path, 'result.json')).readAsString())
            as Map;

    Future<void> expectSuccessfulUpdate({
      String architecture = 'x64',
      String availableArchitecture = 'x86_64',
    }) async {
      // Keep a second PID file so the fixture can be cleaned after helper cleanup.
      final binary = File(
        p.join(candidate.path, 'Contents', 'MacOS', 'Plana App'),
      );
      final source = await binary.readAsString();
      await binary.writeAsString(
        source.replaceFirst(
          'exec /bin/sleep 30',
          "printf '%s\\n' \"\$\$\" > ${MacOSUpdateScript.quote(p.join(root.path, 'child.pid'))}\nexec /bin/sleep 30",
        ),
      );
      final updated = await run(
        architecture: architecture,
        availableArchitecture: availableArchitecture,
      );
      expect(
        updated.exitCode,
        0,
        reason: await File(p.join(work.path, 'update.log')).readAsString(),
      );
      expect(
        await File(p.join(bundle.path, 'version.txt')).readAsString(),
        'new',
      );
      expect((await result())['success'], isTrue);
      expect(
        await Directory(p.join(root.path, '.backup.app')).exists(),
        isFalse,
      );
    }

    test('改名后的安装包沿用原安装路径和 Bundle ID', () async {
      await expectSuccessfulUpdate();
    });

    test('仍可安装使用旧名称的安装包', () async {
      candidate = await candidate.rename(
        p.join(root.path, 'fixture', 'Plana App.app'),
      );
      await expectSuccessfulUpdate();
    });

    test('arm64 架构验证通过后完成更新', () async {
      await expectSuccessfulUpdate(
        architecture: 'arm64',
        availableArchitecture: 'arm64',
      );
    });

    test('架构不匹配在退出和替换前被拒绝', () async {
      final failed = await run(architecture: 'arm64');
      expect(failed.exitCode, isNot(0));
      expect(
        await File(p.join(bundle.path, 'version.txt')).readAsString(),
        'old',
      );
      expect(await File(p.join(work.path, 'ready')).exists(), isFalse);
      expect(
        await Directory(p.join(root.path, '.backup.app')).exists(),
        isFalse,
      );
    });

    test('启动失败时恢复旧 .app 并重新打开', () async {
      await app(candidate, updated: true, starts: false);
      final failed = await run();
      expect(failed.exitCode, isNot(0));
      expect(
        await File(p.join(bundle.path, 'version.txt')).readAsString(),
        'old',
      );
      expect((await result())['success'], isFalse);
      expect(
        (await File(p.join(root.path, 'opened')).readAsString()).trim(),
        bundle.path,
      );
    });

    test('不同 Bundle ID 在替换之前被拒绝', () async {
      await app(candidate, updated: true, bundleId: 'another.app');
      final failed = await run();
      expect(failed.exitCode, isNot(0));
      expect(
        await File(p.join(bundle.path, 'version.txt')).readAsString(),
        'old',
      );
      expect(
        await Directory(p.join(root.path, '.backup.app')).exists(),
        isFalse,
      );
    });

    test('签名验证失败在退出和替换前被拒绝', () async {
      final failed = await run(badSignature: true);
      expect(failed.exitCode, isNot(0));
      expect(
        await File(p.join(bundle.path, 'version.txt')).readAsString(),
        'old',
      );
      expect(await File(p.join(work.path, 'ready')).exists(), isFalse);
    });
  }, skip: Platform.isWindows);

  test('macOS 上用真实 lipo 验证更新脚本的架构检查命令', () async {
    final root = await Directory.systemTemp.createTemp("plana lipo's ");
    try {
      final candidate = Directory(p.join(root.path, 'Plana App Desktop.app'));
      final executable = File(
        p.join(candidate.path, 'Contents', 'MacOS', 'Plana App'),
      );
      await executable.parent.create(recursive: true);
      await Link(executable.path).create(Platform.resolvedExecutable);
      final architectures = await Process.run('/usr/bin/lipo', [
        '-archs',
        executable.path,
      ]);
      expect(architectures.exitCode, 0, reason: '${architectures.stderr}');
      final available = '${architectures.stdout}'.trim().split(RegExp(r'\s+'));
      expect(available.any({'arm64', 'x86_64'}.contains), isTrue);

      for (final architecture in {'arm64': 'arm64', 'x64': 'x86_64'}.entries) {
        final helper = MacOSUpdateScript.build(
          appPid: pid,
          version: 'v1.1.3-desktop',
          architecture: architecture.key,
          dmgPath: p.join(root.path, 'update.dmg'),
          targetApp: candidate.path,
          workDirectory: p.join(root.path, 'work'),
          stagedApp: p.join(root.path, '.staged.app'),
          backupApp: p.join(root.path, '.backup.app'),
          startupFile: p.join(root.path, 'startup'),
        );
        final invocation = helper
            .split('\n')
            .singleWhere((line) => line.startsWith('/usr/bin/lipo '));
        final probe = File(p.join(root.path, 'check.sh'));
        await probe.writeAsString('''set -euo pipefail
Architecture=${MacOSUpdateScript.quote(architecture.value)}
CandidateApp=${MacOSUpdateScript.quote(candidate.path)}
Executable=${MacOSUpdateScript.quote(p.basename(executable.path))}
$invocation
''');
        final verified = await Process.run('/bin/bash', [probe.path]);
        expect(
          verified.exitCode,
          available.contains(architecture.value) ? 0 : isNot(0),
          reason: '${verified.stderr}',
        );
      }
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
