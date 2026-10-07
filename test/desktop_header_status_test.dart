import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/gen_queue.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/loop_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/shell/desktop_task_status.dart';
import 'package:plana_app/features/shell/desktop_version_button.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/features/update/desktop_update.dart';
import 'package:plana_app/features/update/macos_update_controller.dart';
import 'package:plana_app/features/update/macos_update_service.dart';
import 'package:plana_app/features/update/update_service.dart';
import 'package:plana_app/features/update/update_sheet.dart';

class _Generation extends GenerationNotifier {
  void setPool(GenPool pool) => state = pool;
}

class _Queue extends GenQueueNotifier {
  void setQueue(GenQueueState queue) => state = queue;
}

class _Loop extends LoopNotifier {
  void setLoop(LoopStatus loop) => state = loop;
}

class _Assistant extends AssistantNotifier {
  @override
  AssistantState build() => const AssistantState();

  void setAssistant(AssistantState assistant) => state = assistant;
}

class _MacUpdateService extends MacOSUpdateService {
  Completer<DownloadedMacOSUpdate>? _pending;
  Completer<DownloadedMacOSUpdate> get pending =>
      _pending ??= Completer<DownloadedMacOSUpdate>();
  bool started = false;
  int installs = 0;

  @override
  Future<DownloadedMacOSUpdate> download(
    GithubRelease release, {
    required String architecture,
    required void Function(int, int) onProgress,
  }) {
    started = true;
    onProgress(3, 6);
    return pending.future;
  }

  @override
  void cancelDownload() {
    if (started && !pending.isCompleted) {
      pending.completeError(UpdateDownloadCancelled());
    }
  }

  @override
  Future<void> install(
    DownloadedMacOSUpdate update, {
    required String architecture,
    required Future<void> Function() beforeExit,
  }) async {
    installs++;
    await beforeExit();
  }
}

GenJob _job(String id, GenJobStage stage) => GenJob(
  id: id,
  kind: GenJobKind.normal,
  stage: stage,
  width: 832,
  height: 1216,
  seq: int.parse(id),
  step: stage == GenJobStage.running ? 8 : 0,
  total: stage == GenJobStage.running ? 28 : 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProviderContainer c;
  late _MacUpdateService updater;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_header_status');
    updater = _MacUpdateService();
    c = ProviderContainer(
      overrides: [
        desktopModeProvider.overrideWithValue(true),
        prefsStoreProvider.overrideWithValue(PrefsStore.emptyForTest(root)),
        macOSUpdateServiceProvider.overrideWithValue(updater),
        generationProvider.overrideWith(_Generation.new),
        genQueueProvider.overrideWith(_Queue.new),
        loopStatusProvider.overrideWith(_Loop.new),
        assistantProvider.overrideWith(_Assistant.new),
        updateReleaseFetcherProvider.overrideWithValue(
          (
            current, {
            String repo = kGithubRepo,
            TargetPlatform? platform,
            String? architecture,
          }) async => const GithubRelease(
            tag: 'v1.1.2-desktop.1',
            name: '',
            notes: '新版说明',
            url:
                'https://github.com/$kGithubRepo/releases/tag/v1.1.2-desktop.1',
            prerelease: false,
            assets: [
              GithubAsset(
                name: 'Plana-macOS.dmg',
                url:
                    'https://github.com/$kGithubRepo/releases/download/v1.1.2-desktop.1/Plana-macOS.dmg',
                size: 6,
              ),
              GithubAsset(
                name: 'Plana-RemoteUpload-macOS.dmg',
                url:
                    'https://github.com/$kGithubRepo/releases/download/v1.1.2-desktop.1/Plana-RemoteUpload-macOS.dmg',
                size: 6,
              ),
              GithubAsset(name: 'Plana-Windows-x64.zip'),
            ],
          ),
        ),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {bool about = false}) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      Spacer(),
                      DesktopTaskStatusButton(),
                      DesktopVersionButton(),
                    ],
                  ),
                ),
                if (about) const UpdateRow(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder key(String name) => find.byKey(ValueKey(name));

  _Generation getGeneration() =>
      c.read(generationProvider.notifier) as _Generation;
  _Queue getQueue() => c.read(genQueueProvider.notifier) as _Queue;
  _Loop getLoop() => c.read(loopStatusProvider.notifier) as _Loop;
  _Assistant getAssistant() => c.read(assistantProvider.notifier) as _Assistant;

  testWidgets('看历史图时仍显示后台生成任务,查看进度不切页,完成后入口消失', (tester) async {
    c.read(shellIndexProvider.notifier).select(kTabProfile);
    await mount(tester);
    expect(find.text('v$kAppVersion'), findsOneWidget);
    expect(key('desktop-task-button'), findsNothing);
    getGeneration().setPool(GenPool(jobs: [_job('1', GenJobStage.running)]));
    await tester.pump();
    expect(key('desktop-task-button'), findsOneWidget);
    expect(c.read(generationProvider).selectedId, isNull);
    await tester.tap(key('desktop-task-button'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('任务状态'), findsOneWidget);
    expect(find.text('832 × 1216 · 8 / 28 步'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      closeTo(8 / 28, .001),
    );
    expect(c.read(shellIndexProvider), kTabProfile);

    getGeneration().setPool(const GenPool());
    await tester.pump();
    expect(key('desktop-task-button'), findsNothing);
    expect(find.text('当前没有任务'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 160));
    expect(key('desktop-popover'), findsNothing);
  });

  testWidgets('本地等待、服务端排队和未派发队列统计各一次', (tester) async {
    getGeneration().setPool(
      GenPool(
        jobs: [
          _job('1', GenJobStage.running),
          _job('2', GenJobStage.waiting),
          _job('3', GenJobStage.queued),
        ],
      ),
    );
    getQueue().setQueue(
      GenQueueState(
        items: [QueuedTask(id: 1, snapshot: GenerateState.initial())],
        active: true,
      ),
    );
    await mount(tester);
    expect(find.text('生成中 · 排队 3'), findsOneWidget);
    await tester.tap(key('desktop-task-button'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('图片生成 · 服务端排队'), findsOneWidget);
    expect(find.text('图片生成 · 等待生成'), findsOneWidget);
    expect(find.text('待生成队列 · 1 项'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('循环和队列接续间隙保留入口,暂停队列仍可查看,全部结束才隐藏', (tester) async {
    await mount(tester);
    getLoop().setLoop(const LoopStatus(active: true, total: 10, batch: 3));
    await tester.pump();
    expect(find.text('循环生成中'), findsOneWidget);
    await tester.tap(key('desktop-task-button'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('已完成 2 / 10 张'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 160));

    getLoop().setLoop(const LoopStatus());
    getQueue().setQueue(const GenQueueState(active: true));
    await tester.pump();
    expect(find.text('队列处理中'), findsOneWidget);
    getQueue().setQueue(
      GenQueueState(
        items: [QueuedTask(id: 1, snapshot: GenerateState.initial())],
      ),
    );
    await tester.pump();
    expect(find.text('待处理 1'), findsOneWidget);
    getQueue().setQueue(const GenQueueState());
    await tester.pump();
    expect(key('desktop-task-button'), findsNothing);
  });

  testWidgets('只有助手在处理时也显示入口,阶段实时更新,完成后隐藏', (tester) async {
    getAssistant().setAssistant(
      const AssistantState(running: true, stage: '正在思考'),
    );
    await mount(tester);
    expect(find.text('助手处理中'), findsOneWidget);
    await tester.tap(key('desktop-task-button'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('正在思考'), findsOneWidget);
    getAssistant().setAssistant(
      const AssistantState(running: true, stage: '正在整理提示词'),
    );
    await tester.pump();
    expect(find.text('正在整理提示词'), findsOneWidget);
    getAssistant().setAssistant(const AssistantState());
    await tester.pump();
    expect(key('desktop-task-button'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    '版本面板的检查结果点亮标记,可以查看桌面更新说明',
    (tester) async {
      await mount(tester);
      expect(key('desktop-update-marker'), findsNothing);
      await tester.tap(key('desktop-version-button'));
      await tester.pumpAndSettle();
      expect(find.text('版本 $kAppVersion · 构建 $kAppBuild'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(key('desktop-check-update'));
        await c.read(desktopUpdateProvider.notifier).check();
      });
      await tester.pumpAndSettle();
      expect(key('desktop-update-marker'), findsOneWidget);
      expect(find.text('查看更新'), findsOneWidget);
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('新版说明'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('关于页和顶栏共用更新结果', (tester) async {
    await mount(tester, about: true);
    await tester.runAsync(() async {
      await tester.tap(find.text('检查更新'));
      await c.read(desktopUpdateProvider.notifier).check();
    });
    await tester.pumpAndSettle();
    expect(key('desktop-update-marker'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Mac 下载进度进入任务面板,生成或待生成队列未结束时禁用安装',
    (tester) async {
      await tester.runAsync(() async {
        await c.read(desktopUpdateProvider.notifier).check();
      });
      await mount(tester);
      await tester.tap(key('desktop-version-button'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      await tester.tap(key('macos-download-update'));
      await tester.pump();
      expect(find.text('下载更新 · 50%'), findsOneWidget);
      await tester.tap(find.text('以后再说'));
      await tester.pumpAndSettle();
      expect(find.text('下载更新 50%'), findsOneWidget);
      await tester.tap(key('desktop-task-button'));
      await tester.pump(const Duration(milliseconds: 160));
      expect(find.text('下载中 · 50%'), findsOneWidget);
      final release = c.read(desktopUpdateProvider).release!;
      await tester.runAsync(() async {
        updater.pending.complete(
          DownloadedMacOSUpdate(
            file: File('${root.path}/update.dmg'),
            release: release,
            asset: release.assets.first,
            sha256: 'unused',
          ),
        );
        await updater.pending.future;
      });
      await tester.pumpAndSettle();
      expect(key('desktop-task-button'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 160));

      getGeneration().setPool(GenPool(jobs: [_job('1', GenJobStage.running)]));
      await tester.tap(key('desktop-version-button'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(key('macos-install-update')).onPressed,
        isNull,
      );
      await c.read(macOSUpdateProvider.notifier).install();
      expect(updater.installs, 0);
      getGeneration().setPool(const GenPool());
      getQueue().setQueue(
        GenQueueState(
          items: [QueuedTask(id: 1, snapshot: GenerateState.initial())],
        ),
      );
      await tester.pump();
      expect(
        tester.widget<FilledButton>(key('macos-install-update')).onPressed,
        isNull,
      );
      getQueue().clear();
      await tester.pump();
      expect(
        tester.widget<FilledButton>(key('macos-install-update')).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
