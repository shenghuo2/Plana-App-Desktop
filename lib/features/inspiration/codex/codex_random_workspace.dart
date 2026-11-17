import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import 'codex_card.dart';
import 'codex_favorites.dart';
import 'codex_history.dart';
import 'codex_image_loading.dart';
import 'codex_models.dart';
import 'codex_block.dart';
import 'codex_providers.dart';
import 'codex_sheets.dart';

/// The range/candidate/history workspace. Drawing controls will be decided
/// separately after the user reviews this view.
class CodexRandomWorkspace extends ConsumerStatefulWidget {
  const CodexRandomWorkspace({
    super.key,
    required this.scope,
    required this.count,
    required this.candidates,
    required this.media,
    required this.embedded,
    required this.onClose,
  });
  final String scope;
  final int count;
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
  final _images = CodexImageLoadController();
  late final _scroll = ScrollController(
    onAttach: _images.attach,
    onDetach: _images.detach,
  );
  @override
  void dispose() {
    _scroll.dispose();
    _images.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(codexHistoryProvider);
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
                  const Icon(Icons.casino_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('随机灵感', style: context.texts.titleSmall),
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
                children: [
                  ChoiceChip(
                    key: const ValueKey('codex-random-candidates'),
                    label: Text('候选内容 ${widget.count}'),
                    selected: !_history,
                    onSelected: (_) => setState(() => _history = false),
                  ),
                  ChoiceChip(
                    key: const ValueKey('codex-random-history'),
                    label: Text('抽取历史 ${records.length}'),
                    selected: _history,
                    onSelected: (_) => setState(() => _history = true),
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
