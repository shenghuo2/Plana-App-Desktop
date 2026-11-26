import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';
import '../../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'codex_block.dart';
import 'codex_card_interactions.dart' show importCodexPrompt;
import 'codex_draw_card.dart';
import 'codex_draw_history_list.dart';
import 'codex_draw_pool.dart';
import 'codex_history.dart';
import 'codex_models.dart';
import 'codex_providers.dart';
import 'codex_sheets.dart';
import 'codex_wide_draw.dart';

class CodexRandomWorkspace extends ConsumerStatefulWidget {
  const CodexRandomWorkspace({
    super.key,
    required this.scope,
    required this.scopeKey,
    required this.codex,
    required this.entries,
    required this.candidatesForDraw,
    required this.bookPicker,
    required this.categoryPicker,
    required this.favoritesOnly,
    required this.onFavorites,
    required this.media,
    required this.onClose,
    this.wide = false,
    this.onBrowseCategory,
    this.query = '',
    this.onClearQuery,
    this.newOnly = false,
    this.onToggleNew,
  });
  final bool wide;
  final ValueChanged<List<String>>? onBrowseCategory;
  final String query;
  final String Function([List<String>? category]) scope;
  final String Function([List<String>? category]) scopeKey;
  final CodexMeta codex;
  final List<CodexEntry> entries;
  final List<CodexEntry> Function([List<String>? category]) candidatesForDraw;
  final Widget bookPicker, categoryPicker;
  final bool favoritesOnly, newOnly;
  final VoidCallback onFavorites, onClose;
  final VoidCallback? onClearQuery, onToggleNew;
  final CodexMedia media;

  @override
  ConsumerState<CodexRandomWorkspace> createState() =>
      _CodexRandomWorkspaceState();
}

class _CodexRandomWorkspaceState extends ConsumerState<CodexRandomWorkspace> {
  final _stageScroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'Codex draw desk');
  bool _history = false;
  bool _trio = false;
  String? _handScope;
  List<CodexDrawRecord> _hand = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _stageScroll.dispose();
    super.dispose();
  }

  Future<void> _draw(
    CodexDrawRecord? previous, {
    bool batch = false,
    List<String>? category,
  }) async {
    final scope = widget.scopeKey(category);
    final pool = widget.candidatesForDraw(category);
    final rounds = ref.read(codexDrawRoundsProvider.notifier);
    if (rounds.saving || pool.isEmpty) return;
    final draws = await rounds.deal(
      book: widget.codex,
      scopeKey: scope,
      scopeLabel: widget.scope(category),
      pool: pool,
      count: batch ? 3 : 1,
      previousId: previous?.codex.id == widget.codex.id
          ? previous?.entry.id
          : null,
    );
    if (!mounted) return;
    if (draws.isEmpty) {
      hintSnack(context, context.l10n.desktopCouldNotSaveTheRandomDrawTryAgain);
    } else if (batch && scope == widget.scopeKey()) {
      setState(() {
        _handScope = scope;
        _hand = draws;
      });
    }
  }

  Future<void> _clearHistory(int count) async {
    final t = context.l10n;
    final ok = await confirmDialog(
      context,
      title: t.desktopDeleteDrawHistory,
      message: t.codexDeckClearMessage(count),
      confirmLabel: t.desktopDeleteHistory,
    );
    if (ok && mounted) {
      final cleared = await ref.read(codexHistoryProvider.notifier).clearAll();
      if (!cleared && mounted) {
        hintSnack(context, t.desktopCouldNotDeleteHistoryTryAgain);
      }
    }
  }

  Future<void> _remove(CodexDrawRecord r) async {
    final ok = await ref.read(codexHistoryProvider.notifier).remove(r.id);
    if (!ok && mounted) {
      hintSnack(context, context.l10n.desktopCouldNotDeleteHistoryTryAgain);
    }
  }

  void _detail(CodexDrawRecord r, {int imageIndex = 0}) {
    var pool = widget.entries;
    final sameBook = r.codex.id == widget.codex.id;
    var index = sameBook ? pool.indexWhere((e) => e.id == r.entry.id) : -1;
    if (widget.wide && sameBook && index < 0 && r.entry.path.isNotEmpty) {
      pool = widget.candidatesForDraw(r.entry.path);
      index = pool.indexWhere((e) => e.id == r.entry.id);
    }
    // Preserve the drawn image and prompt even if the catalog has changed.
    final entries = index < 0
        ? [r.entry]
        : (List<CodexEntry>.of(pool)..[index] = r.entry);
    showCodexDetailSheet(
      context,
      r.codex,
      widget.media,
      entries: entries,
      index: math.max(0, index),
      imageIndex: imageIndex,
    );
  }

  void _back() {
    if (_history) {
      setState(() => _history = false);
    } else {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(codexHistoryProvider);
    final allowed = {
      for (final b
          in ref.watch(codexIndexProvider).value ?? const <CodexMeta>[])
        b.id,
    };
    final blocked = ref.watch(codexBlocksProvider);
    final records = (history.value ?? const <CodexDrawRecord>[])
        .where(
          (r) =>
              allowed.contains(r.codex.id) &&
              !(blocked[r.codex.id]?.hides(r.entry.path) ?? false),
        )
        .toList();
    final recent = records
        .where(ref.watch(codexDrawSessionProvider).contains)
        .toList();
    final selected = ref.watch(codexSelectedDrawProvider);
    var currentIndex = recent.indexWhere((r) => r.id == selected);
    if (currentIndex < 0 && recent.isNotEmpty) currentIndex = 0;
    final current = currentIndex < 0 ? null : recent[currentIndex];
    final noRepeat = ref.watch(codexDrawRoundsProvider);
    final rounds = ref.read(codexDrawRoundsProvider.notifier);
    final scope = widget.scopeKey();
    final seen = rounds.seenCount(scope, widget.entries);
    final t = context.l10n;
    final count = widget.entries.length;
    void recall(CodexDrawRecord r) {
      ref.read(codexSelectedDrawProvider.notifier).select(r);
      _focus.requestFocus();
    }

    // Follow the thumbnail strip, which shows the newest draw on the left.
    final VoidCallback? previous = currentIndex > 0
        ? () => recall(recent[currentIndex - 1])
        : null;
    final VoidCallback? next =
        currentIndex >= 0 && currentIndex + 1 < recent.length
        ? () => recall(recent[currentIndex + 1])
        : null;
    final ready = !rounds.saving && !history.hasError;
    final canDraw = count > 0 && ready;
    final inTrio = widget.wide && _trio;
    final VoidCallback? draw = canDraw
        ? () => _draw(current, batch: inTrio)
        : null;
    final relatedPath = current?.entry.path;
    final sameBook = current != null && current.codex.id == widget.codex.id;
    final relatedCount =
        widget.wide && sameBook && relatedPath != null && relatedPath.isNotEmpty
        ? widget.candidatesForDraw(relatedPath).length
        : 0;
    final hand = widget.wide && _handScope == scope
        ? _hand
              .where(
                (r) =>
                    recent.any((saved) => r.id == saved.id) &&
                    widget.entries.any((e) => e.id == r.entry.id),
              )
              .toList()
        : const <CodexDrawRecord>[];
    void pick(CodexDrawRecord r) {
      recall(r);
      if (_trio) setState(() => _trio = false);
    }

    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): _back,
      if (!_history && draw != null)
        const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
            draw,
      if (!_history && !inTrio && previous != null)
        const SingleActivator(LogicalKeyboardKey.arrowLeft): previous,
      if (!_history && !inTrio && next != null)
        const SingleActivator(LogicalKeyboardKey.arrowRight): next,
    };
    final historyWidgets = <Widget>[
      if (_history) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${t.codexDeckHistory} · ${records.length}',
                  style: context.texts.titleSmall,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('codex-random-clear'),
                onPressed: (history.value?.isNotEmpty ?? false)
                    ? () => _clearHistory(history.value!.length)
                    : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(t.codexDeckClear),
              ),
            ],
          ),
        ),
        Expanded(
          child: history.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(codexHistoryProvider),
                child: Text(t.desktopCouldNotLoadDrawHistoryClickToRetry),
              ),
            ),
            data: (_) => CodexDrawHistoryList(
              records: records,
              grid: widget.wide,
              selectedId: current?.id,
              media: widget.media,
              onOpen: _detail,
              onImport: (r) =>
                  importCodexPrompt(context, ref, r.entry, section: true),
              onRemove: _remove,
            ),
          ),
        ),
        if (!widget.wide)
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton.tonalIcon(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: Text(t.codexDeckBack),
            ),
          ),
      ],
    ];
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        focusNode: _focus,
        child: widget.wide
            ? CodexWideDraw(
                key: const ValueKey('desktop-codex-random-workspace'),
                book: widget.codex,
                media: widget.media,
                current: current,
                scope: widget.scope(),
                count: count,
                seen: seen,
                noRepeat: noRepeat,
                onToggleRepeat: rounds.toggle,
                onReshuffle: noRepeat && seen > 0 && !rounds.saving
                    ? () => rounds.reshuffle(widget.scopeKey())
                    : null,
                history: _history
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: historyWidgets,
                      )
                    : null,
                onHistory: () => setState(() => _history = !_history),
                recent: recent,
                onSelect: pick,
                onOpen: _detail,
                onBack: _back,
                onPrevious: previous,
                onNext: next,
                onDraw: draw,
                trio: _trio,
                hand: hand,
                onLayout: (trio) {
                  if (_trio == trio) return;
                  setState(() {
                    _trio = trio;
                    _history = false;
                  });
                  if (trio && canDraw && hand.isEmpty) {
                    _draw(current, batch: true);
                  }
                  _focus.requestFocus();
                },
                relatedCount: relatedCount,
                onRelatedDraw: ready && relatedCount > 0
                    ? () => _draw(current, category: relatedPath)
                    : null,
                onBrowse:
                    sameBook && relatedPath != null && relatedPath.isNotEmpty
                    ? () => widget.onBrowseCategory?.call(relatedPath)
                    : null,
              )
            : Column(
                key: const ValueKey('desktop-codex-random-workspace'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('codex-draw-back'),
                          onPressed: _back,
                          tooltip: _history
                              ? t.codexDeckBack
                              : t.desktopBackToCodex,
                          icon: Icon(
                            _history ? Icons.arrow_back : Icons.close,
                            size: 19,
                          ),
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                t.desktopRandomInspiration,
                                style: context.texts.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                t.codexDeckCandidates(count),
                                key: const ValueKey('codex-random-candidates'),
                                style: context.texts.labelMedium,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 5),
                        Tooltip(
                          message: t.codexDeckHistory,
                          child: TextButton.icon(
                            key: const ValueKey('codex-random-history'),
                            onPressed: () =>
                                setState(() => _history = !_history),
                            icon: const Icon(Icons.history, size: 17),
                            label: Text('${records.length}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (_history)
                    ...historyWidgets
                  else ...[
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final filters = ColoredBox(
                            color: context.scheme.surface,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 12, 0),
                              child: _scopeControls(noRepeat, seen),
                            ),
                          );
                          return Scrollbar(
                            controller: _stageScroll,
                            child: CustomScrollView(
                              controller: _stageScroll,
                              slivers: [
                                if (box.maxHeight >= 320)
                                  PinnedHeaderSliver(child: filters)
                                else
                                  SliverToBoxAdapter(child: filters),
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    0,
                                    12,
                                    8,
                                  ),
                                  sliver: SliverLayoutBuilder(
                                    builder: (context, constraints) {
                                      final available =
                                          constraints.viewportMainAxisExtent -
                                          constraints.precedingScrollExtent;
                                      return SliverToBoxAdapter(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            const SizedBox(height: 8),
                                            if (current != null)
                                              CodexDrawCard(
                                                record: current,
                                                media: widget.media,
                                                onOpen: () => _detail(current),
                                                onPrevious: previous,
                                                onNext: next,
                                                availableHeight: math.max(
                                                  130 +
                                                      MediaQuery.textScalerOf(
                                                        context,
                                                      ).scale(140),
                                                  available - 64,
                                                ),
                                                imageHeight:
                                                    (box.maxWidth * .92).clamp(
                                                      130.0,
                                                      420.0,
                                                    ),
                                              )
                                            else
                                              SizedBox(
                                                height: (box.maxHeight * .42)
                                                    .clamp(110.0, 280.0),
                                                child: Center(
                                                  child: Text(
                                                    count == 0
                                                        ? t.noMatchingEntries
                                                        : t.codexDeckFirst,
                                                    style: context
                                                        .texts
                                                        .titleMedium,
                                                  ),
                                                ),
                                              ),
                                            CodexRecentDraws(
                                              records: recent,
                                              media: widget.media,
                                              selectedId: current?.id,
                                              onSelect: recall,
                                              onHistory: () => setState(
                                                () => _history = true,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(9, 5, 9, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('codex-random-draw'),
                            onPressed: draw,
                            icon: const Icon(Icons.casino_outlined, size: 18),
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  current == null
                                      ? t.desktopDrawAtRandom
                                      : t.shuffleAnother,
                                ),
                                const SizedBox(width: 8),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(5),
                                    color: context.scheme.onPrimary.withValues(
                                      alpha: .13,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    child: Text(
                                      'Space',
                                      style: context.texts.labelSmall?.copyWith(
                                        color: draw == null
                                            ? context.scheme.outline
                                            : context.scheme.onPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              for (final section in [true, false]) ...[
                                if (!section) const SizedBox(width: 5),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    key: ValueKey(
                                      section
                                          ? 'codex-draw-import-section'
                                          : 'codex-draw-append-main',
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                      ),
                                    ),
                                    onPressed: current == null
                                        ? null
                                        : () => importCodexPrompt(
                                            context,
                                            ref,
                                            current.entry,
                                            section: section,
                                          ),
                                    icon: Icon(
                                      section ? Icons.add : Icons.notes,
                                      size: 16,
                                    ),
                                    label: Text(
                                      section
                                          ? t.codexNewSection
                                          : t.codexAppendMain,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _scopeControls(bool noRepeat, int seen) {
    final t = context.l10n;
    final count = widget.entries.length;
    final rounds = ref.read(codexDrawRoundsProvider.notifier);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(flex: 6, child: widget.bookPicker),
                const SizedBox(width: 6),
                Expanded(flex: 5, child: widget.categoryPicker),
              ],
            ),
            if (widget.query.isNotEmpty || widget.newOnly)
              Wrap(
                spacing: 4,
                children: [
                  if (widget.query.isNotEmpty)
                    InputChip(
                      label: Text(
                        widget.query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: widget.onClearQuery,
                    ),
                  if (widget.newOnly)
                    InputChip(
                      label: Text(t.codexRecentAdditions),
                      onDeleted: widget.onToggleNew,
                    ),
                ],
              ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _toggle(
                        'codex-draw-only-favorites',
                        t.codexOnlyFavorites,
                        Icons.star_outline,
                        widget.favoritesOnly,
                        widget.onFavorites,
                      ),
                      _toggle(
                        'codex-draw-no-repeat',
                        t.codexDeckNoRepeat,
                        Icons.shuffle,
                        noRepeat,
                        rounds.toggle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  key: const ValueKey('codex-draw-reshuffle'),
                  onPressed: noRepeat && seen > 0
                      ? () => rounds.reshuffle(widget.scopeKey())
                      : null,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                  ),
                  child: Text(t.codexDeckReshuffle),
                ),
              ],
            ),
            if (noRepeat)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${t.codexDeckSeen} $seen/$count',
                  key: const ValueKey('codex-draw-seen'),
                  style: context.texts.labelSmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toggle(
    String key,
    String label,
    IconData icon,
    bool active,
    VoidCallback press,
  ) => FilterChip(
    key: ValueKey(key),
    selected: active,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    avatar: Icon(icon, size: 15),
    label: Text(label),
    labelPadding: const EdgeInsets.symmetric(horizontal: 2),
    onSelected: (_) => press(),
  );
}
