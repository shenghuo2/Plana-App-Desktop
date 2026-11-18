import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'codex_card.dart';
import 'codex_favorites.dart';
import 'codex_history.dart';
import 'codex_image_loading.dart';
import 'codex_models.dart';
import 'codex_block.dart';
import 'codex_providers.dart';
import 'codex_sheets.dart';

/// Draw from the visible candidate pool and browse previously drawn entries.
class CodexRandomWorkspace extends ConsumerStatefulWidget {
  const CodexRandomWorkspace({
    super.key,
    required this.scope,
    required this.codex,
    required this.candidateCount,
    required this.candidatesForDraw,
    required this.candidates,
    required this.media,
    required this.embedded,
    required this.onClose,
  });
  final String scope;
  final CodexMeta codex;
  final int candidateCount;
  final List<CodexEntry> Function() candidatesForDraw;
  final Widget candidates;
  final CodexMedia media;
  final bool embedded;
  final VoidCallback onClose;

  @override
  ConsumerState<CodexRandomWorkspace> createState() =>
      _CodexRandomWorkspaceState();
}

class _CodexRandomWorkspaceState extends ConsumerState<CodexRandomWorkspace> {
  bool _history = false;
  final _random = Random();
  final _images = CodexImageLoadController();
  late final _scroll = ScrollController(
    keepScrollOffset: false,
    onAttach: _images.attach,
    onDetach: _images.detach,
  );
  @override
  void dispose() {
    _scroll.dispose();
    _images.dispose();
    super.dispose();
  }

  Future<void> _draw() async {
    final pool = widget.candidatesForDraw();
    if (pool.isEmpty) return;
    final result = pool[_random.nextInt(pool.length)];
    if (!_history) setState(() => _history = true);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final saved = await ref
        .read(codexHistoryProvider.notifier)
        .record(widget.codex, result);
    if (!saved && mounted) hintSnack(context, '抽取结果保存失败，请重试');
  }

  Future<void> _clearHistory(int count) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除抽取历史？',
      message: '将清空所有法典的 $count 条抽取记录。',
      confirmLabel: '删除历史',
    );
    if (!confirmed || !mounted) return;
    final cleared = await ref.read(codexHistoryProvider.notifier).clearAll();
    if (!cleared && mounted) hintSnack(context, '历史删除失败，请重试');
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(codexHistoryProvider);
    final total = history.value?.length ?? 0;
    // Keep historical entries within available books and unblocked categories.
    final books = ref.watch(codexIndexProvider).value ?? const <CodexMeta>[];
    final allowed = {for (final book in books) book.id};
    final records = [
      for (final item in history.value ?? const <CodexDrawRecord>[])
        if (allowed.contains(item.codex.id) &&
            !ref
                .watch(codexBlockProvider(item.codex.id))
                .hides(item.entry.path))
          item,
    ];
    return Column(
      key: const ValueKey('desktop-codex-random-workspace'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: EdgeInsets.fromLTRB(
            widget.embedded ? 12 : 24,
            0,
            widget.embedded ? 12 : 24,
            12,
          ),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ChoiceChip(
                        key: const ValueKey('codex-random-candidates'),
                        label: Text('候选内容 ${widget.candidateCount}'),
                        selected: !_history,
                        onSelected: (_) => setState(() => _history = false),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '返回法典浏览',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              Text(
                '抽取范围：${widget.scope}',
                key: const ValueKey('codex-random-scope'),
                style: context.texts.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('codex-random-draw'),
                    icon: const Icon(Icons.casino_outlined, size: 18),
                    label: const Text('随机抽取'),
                    onPressed: widget.candidateCount == 0 ? null : _draw,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: ChoiceChip(
                          key: const ValueKey('codex-random-history'),
                          label: Text('抽取历史 ${records.length}'),
                          selected: _history,
                          onSelected: (_) => setState(() => _history = true),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        key: const ValueKey('codex-random-clear'),
                        tooltip: '删除历史',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: total == 0
                            ? null
                            : () => _clearHistory(total),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: !_history
              ? widget.candidates
              : history.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => Center(
                    child: TextButton.icon(
                      onPressed: () => ref.invalidate(codexHistoryProvider),
                      icon: const Icon(Icons.refresh),
                      label: const Text('抽取历史加载失败，点击重试'),
                    ),
                  ),
                  data: (_) => records.isEmpty
                      ? const Center(
                          child: Text(
                            '还没有抽取记录\n抽取结果会按时间保存在这里',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : _historyGrid(records),
                ),
        ),
      ],
    );
  }

  Widget _historyGrid(List<CodexDrawRecord> records) {
    final favorites = ref.watch(codexFavKeysProvider);
    final edge = widget.embedded ? 12.0 : 24.0;
    return LayoutBuilder(
      builder: (context, box) {
        final columns = widget.embedded
            ? 1
            : ((box.maxWidth - edge * 2 + 16) / 230).floor().clamp(1, 10);
        final width = (box.maxWidth - edge * 2 - (columns - 1) * 16) / columns;
        return Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: GridView.builder(
            key: const ValueKey('codex-random-history-grid'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(edge, 0, edge, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: 330,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
            ),
            itemCount: records.length,
            itemBuilder: (context, index) {
              final item = records[index];
              return CodexCard(
                key: ValueKey('codex-history-$index'),
                codex: item.codex,
                entry: item.entry,
                media: widget.media,
                desktop: true,
                imageLoading: _images,
                decodeWidth: width,
                favorite: favorites.contains(
                  codexFavKey(item.codex.id, item.entry.id),
                ),
                onFavorite: () async {
                  final notifier = ref.read(codexFavoritesProvider.notifier);
                  final selected = await notifier.toggle(
                    item.codex.id,
                    item.entry,
                    now: DateTime.now().millisecondsSinceEpoch,
                  );
                  if (context.mounted && !selected && notifier.isFull) {
                    hintSnack(context, '收藏夹已满');
                  }
                },
                onTap: () => showCodexDetailSheet(
                  context,
                  item.codex,
                  widget.media,
                  entries: [item.entry],
                  index: 0,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
