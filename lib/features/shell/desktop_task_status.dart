import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/desktop_popover.dart';
import '../assistant/assistant_state.dart';
import '../generate/gen_jobs.dart';
import '../generate/gen_queue.dart';
import '../generate/generation_controller.dart';
import '../generate/loop_controller.dart';
import '../update/macos_update_controller.dart';

bool _waiting(GenJob job) =>
    job.stage == GenJobStage.waiting || job.stage == GenJobStage.queued;

String _stageLabel(GenJobStage stage) => switch (stage) {
  GenJobStage.waiting => '等待生成',
  GenJobStage.preparing => '准备中',
  GenJobStage.queued => '服务端排队',
  GenJobStage.starting => '启动中',
  GenJobStage.running => '生成中',
  GenJobStage.saving => '保存中',
};

/// 顶栏只订阅状态与数量,逐帧预览不触发它重建。
final desktopTaskStatusProvider = Provider((ref) {
  final jobs = ref.watch(
    generationProvider.select(
      (pool) => (
        active: pool.jobs.where((job) => !_waiting(job)).length,
        waiting: pool.jobs.where(_waiting).length,
        stage: pool.jobs.where((job) => !_waiting(job)).length == 1
            ? pool.jobs.firstWhere((job) => !_waiting(job)).stage
            : null,
      ),
    ),
  );
  final queue = ref.watch(
    genQueueProvider.select((q) => (count: q.items.length, active: q.active)),
  );
  final loop = ref.watch(loopStatusProvider.select((loop) => loop.active));
  final assistant = ref.watch(assistantProvider.select((s) => s.running));
  final activeCount = jobs.active + (assistant ? 1 : 0);
  // items 不含已派发到任务池的工作,两边相加不会重复计数。
  final waitingCount = jobs.waiting + queue.count;
  final labels = <String>[
    if (activeCount > 0)
      activeCount > 1
          ? '进行中 $activeCount'
          : assistant
          ? '助手处理中'
          : _stageLabel(jobs.stage ?? GenJobStage.running),
    if (waitingCount > 0)
      jobs.waiting == 0 && !queue.active && !loop && activeCount == 0
          ? '待处理 $waitingCount'
          : '排队 $waitingCount',
  ];
  // 循环/队列的启动、接续及收尾间隙可能还没有任务,仍应显示入口。
  if (labels.isEmpty) {
    if (loop) {
      labels.add('循环生成中');
    } else if (queue.active) {
      labels.add('队列处理中');
    }
  }
  final update = ref.watch(
    macOSUpdateProvider.select((s) => (stage: s.stage, percent: s.percent)),
  );
  final updating =
      update.stage == MacOSUpdateStage.downloading ||
      update.stage == MacOSUpdateStage.installing;
  if (labels.isEmpty && updating) {
    labels.add(
      update.stage == MacOSUpdateStage.downloading
          ? '下载更新 ${update.percent}%'
          : '准备更新',
    );
  }
  return (
    label: labels.join(' · '),
    active:
        jobs.active + jobs.waiting > 0 ||
        queue.active ||
        loop ||
        assistant ||
        updating,
  );
});

class DesktopTaskStatusButton extends ConsumerWidget {
  const DesktopTaskStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(desktopTaskStatusProvider);
    if (status.label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: '${status.label} · 查看任务状态',
        child: TextButton.icon(
          key: const ValueKey('desktop-task-button'),
          onPressed: () => showDesktopPopover(
            context,
            width: 360,
            builder: (_) => const _TaskPanel(),
          ),
          style: TextButton.styleFrom(
            foregroundColor: context.scheme.primary,
            backgroundColor: context.scheme.primaryContainer.withValues(
              alpha: .5,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 12),
          ),
          icon: Icon(
            status.active ? Icons.timelapse : Icons.pause_circle_outline,
            size: 16,
          ),
          label: Text(
            status.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _TaskPanel extends ConsumerWidget {
  const _TaskPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(generationProvider).newestFirst;
    final queue = ref.watch(genQueueProvider);
    final loop = ref.watch(loopStatusProvider);
    final update = ref.watch(macOSUpdateProvider);
    final assistant = ref.watch(
      assistantProvider.select((s) => (running: s.running, stage: s.stage)),
    );
    final idle =
        jobs.isEmpty &&
        queue.items.isEmpty &&
        !queue.active &&
        !loop.active &&
        !assistant.running &&
        !update.busy;
    final completed = loop.batch > 0 ? loop.batch - 1 : 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
          child: Row(
            children: [
              Expanded(child: Text('任务状态', style: context.texts.titleMedium)),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (idle)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('当前没有任务', textAlign: TextAlign.center),
                  ),
                if (loop.active)
                  _TaskRow(
                    icon: Icons.repeat,
                    title: loop.stopping ? '循环生成 · 正在停止' : '循环生成',
                    detail: loop.stopping
                        ? '完成当前任务后停止'
                        : loop.total > 0
                        ? '已完成 $completed / ${loop.total} 张'
                        : '已完成 $completed 张 · 不限数量',
                  ),
                if (assistant.running)
                  _TaskRow(
                    icon: Icons.auto_awesome_outlined,
                    title: 'AI 助手',
                    detail: assistant.stage.isEmpty ? '正在处理' : assistant.stage,
                  ),
                if (update.busy)
                  _TaskRow(
                    icon: Icons.system_update_alt,
                    title: '应用更新',
                    detail: update.stage == MacOSUpdateStage.downloading
                        ? '下载中 · ${update.percent}%'
                        : '正在验证并准备重新启动',
                    showProgress: true,
                    progress:
                        update.stage == MacOSUpdateStage.downloading &&
                            update.total > 0
                        ? update.received / update.total
                        : null,
                  ),
                for (final job in jobs)
                  _TaskRow(
                    icon: job.kind == GenJobKind.inpaint
                        ? Icons.brush_outlined
                        : Icons.image_outlined,
                    title:
                        '${job.kind == GenJobKind.inpaint ? '局部重绘' : '图片生成'} · ${_stageLabel(job.stage)}',
                    detail: [
                      '${job.width} × ${job.height}',
                      if (job.note?.isNotEmpty == true) job.note!,
                      if (job.stage == GenJobStage.running && job.sampling)
                        '${job.step} / ${job.total} 步',
                    ].join(' · '),
                    showProgress: !_waiting(job),
                    progress: job.stage == GenJobStage.saving
                        ? null
                        : job.progress,
                  ),
                if (queue.active || queue.items.isNotEmpty) ...[
                  _TaskRow(
                    icon: Icons.playlist_play,
                    title: '待生成队列 · ${queue.items.length} 项',
                    detail: queue.stopping
                        ? '完成当前任务后暂停'
                        : queue.active
                        ? '已完成 ${queue.done} 张'
                        : loop.active
                        ? '等待当前循环结束'
                        : '等待处理',
                  ),
                  for (var i = 0; i < queue.items.length; i++)
                    _TaskRow(
                      icon: Icons.schedule,
                      title: '待生成 ${i + 1}',
                      detail:
                          '${queue.items[i].snapshot.params.model} · '
                          '${queue.items[i].snapshot.params.width} × '
                          '${queue.items[i].snapshot.params.height}',
                    ),
                  if (queue.items.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () =>
                            ref.read(genQueueProvider.notifier).clear(),
                        child: const Text('清空待生成队列'),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.showProgress = false,
    this.progress,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool showProgress;
  final double? progress;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: context.scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: context.texts.bodyMedium),
              const SizedBox(height: 3),
              Text(
                detail,
                style: context.texts.bodySmall!.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
              if (showProgress) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress, minHeight: 3),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
