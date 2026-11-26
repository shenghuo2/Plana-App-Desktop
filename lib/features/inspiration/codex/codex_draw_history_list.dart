import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/section_navigation.dart';
import '../../../l10n/l10n.dart';
import 'codex_card_interactions.dart';
import 'codex_draw_card.dart';
import 'codex_history.dart';
import 'codex_models.dart';

String _digits(int n) => n.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year}-${_digits(d.month)}-${_digits(d.day)}';

class _DrawDay {
  _DrawDay(this.day, this.records);
  final DateTime day;
  final List<CodexDrawRecord> records;
}

List<_DrawDay> _groupDays(List<CodexDrawRecord> records) {
  final byDate = <DateTime, List<CodexDrawRecord>>{};
  for (final r in records) {
    final local = DateTime.fromMillisecondsSinceEpoch(r.savedAt);
    final day = DateTime(local.year, local.month, local.day);
    (byDate[day] ??= []).add(r);
  }
  final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
  final groups = <_DrawDay>[];
  for (final day in dates) {
    final items = byDate[day]!;
    groups.add(_DrawDay(day, items));
  }
  return groups;
}

class CodexDrawHistoryList extends StatefulWidget {
  const CodexDrawHistoryList({
    super.key,
    this.grid = false,
    required this.records,
    required this.selectedId,
    required this.media,
    required this.onOpen,
    required this.onImport,
    required this.onRemove,
  });
  final List<CodexDrawRecord> records;
  final bool grid;
  final CodexMedia media;
  final String? selectedId;
  final ValueChanged<CodexDrawRecord> onOpen, onImport, onRemove;

  @override
  State<CodexDrawHistoryList> createState() => _CodexDrawHistoryListState();
}

class _CodexDrawHistoryListState extends State<CodexDrawHistoryList>
    with WidgetsBindingObserver {
  final _scroll = ScrollController(keepScrollOffset: false);
  late List<_DrawDay> _days;
  late DateTime _today;
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    _days = _groupDays(widget.records);
    WidgetsBinding.instance.addObserver(this);
    _startDay();
  }

  @override
  void didUpdateWidget(CodexDrawHistoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.records != oldWidget.records) _days = _groupDays(widget.records);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(_startDay);
  }

  void _startDay() {
    _midnight?.cancel();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _midnight = Timer(
      DateTime(now.year, now.month, now.day + 1).difference(now),
      () {
        if (mounted) setState(_startDay);
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String _label(_DrawDay g) {
    final t = context.l10n;
    final today = _today;
    if (g.day == today) return t.today;
    if (g.day == DateTime(today.year, today.month, today.day - 1)) {
      return t.yesterday;
    }
    if (g.day == DateTime(today.year, today.month, today.day - 2)) {
      return t.codexDeckDayBefore;
    }
    return _date(g.day);
  }

  int _groupAt(num position, List<num> starts) {
    var lo = 0, hi = _days.length;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      if (starts[mid] <= position) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Widget _historyCard(CodexDrawRecord record) => CodexHoverPreviewArea(
    key: ValueKey(record.id),
    codex: record.codex,
    entry: record.entry,
    media: widget.media,
    builder: (preview, _) =>
        preview(widget.grid ? _gridCard(record) : _recordTile(record)),
  );

  Widget _recordTile(CodexDrawRecord record) {
    final time = DateTime.fromMillisecondsSinceEpoch(record.savedAt);
    return Material(
      color: record.id == widget.selectedId
          ? context.scheme.secondaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: ValueKey('codex-history-${record.id}'),
        onTap: () => widget.onOpen(record),
        borderRadius: BorderRadius.circular(10),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 42,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: context.scheme.surfaceContainerLow,
                  child: CodexDrawImage(
                    record,
                    widget.media,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    record.entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${_digits(time.hour)}:${_digits(time.minute)} · ${record.codex.displayTitle}${record.scope == null ? '' : ' · ${record.scope}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.codexNewSection,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 17),
              onPressed: () => widget.onImport(record),
            ),
            IconButton(
              tooltip: context.l10n.remove,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => widget.onRemove(record),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_days.isEmpty) {
      return Center(
        child: Text(
          context.l10n.desktopNoDrawsYetDrawsWillAppearHereIn,
          textAlign: TextAlign.center,
        ),
      );
    }
    final extent = math.max(
      58.0,
      MediaQuery.textScalerOf(context).scale(36) + 20,
    );
    final nav = _days.length >= 2;
    return LayoutBuilder(
      builder: (context, box) {
        final right = nav ? 58.0 : 12.0;
        final available = box.maxWidth - right - 8;
        final columns = widget.grid
            ? math.max(1, (available / 180).floor())
            : 1;
        final rowHeight = widget.grid
            ? 130.0 + MediaQuery.textScalerOf(context).scale(52)
            : extent;
        final headerHeight = widget.grid
            ? MediaQuery.textScalerOf(context).scale(22) + 12
            : extent;
        final rowStarts = <int>[];
        final offsets = <double>[];
        var rowCount = 0;
        var height = 0.0;
        for (final g in _days) {
          rowStarts.add(rowCount);
          offsets.add(height);
          final rows = (g.records.length + columns - 1) ~/ columns;
          rowCount += 1 + rows;
          height += headerHeight + rows * rowHeight;
        }
        return Stack(
          children: [
            Positioned.fill(
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _scroll,
                  key: const ValueKey('codex-draw-history-list'),
                  itemExtent: widget.grid ? null : extent,
                  itemExtentBuilder: widget.grid
                      ? (i, _) {
                          if (i >= rowCount) return null;
                          return rowStarts[_groupAt(i, rowStarts)] == i
                              ? headerHeight
                              : rowHeight;
                        }
                      : null,
                  padding: EdgeInsets.fromLTRB(
                    8,
                    0,
                    right,
                    nav
                        ? math.max(8, box.maxHeight - (height - offsets.last))
                        : 8,
                  ),
                  itemCount: rowCount,
                  itemBuilder: (context, i) {
                    final group = _groupAt(i, rowStarts);
                    final g = _days[group];
                    final row = i - rowStarts[group] - 1;
                    if (row < 0) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${_label(g)} · ${g.records.length}',
                          key: ValueKey('codex-draw-day-${_date(g.day)}'),
                          style: context.texts.titleSmall?.copyWith(
                            color: context.scheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    if (!widget.grid) return _historyCard(g.records[row]);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var j = 0; j < columns; j++)
                          Expanded(
                            child: row * columns + j < g.records.length
                                ? Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      2,
                                      2,
                                      6,
                                      6,
                                    ),
                                    child: _historyCard(
                                      g.records[row * columns + j],
                                    ),
                                  )
                                : const SizedBox(),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (nav)
              Positioned.fill(
                left: null,
                right: 10,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedBuilder(
                    animation: _scroll,
                    builder: (context, _) => SectionNavigation<_DrawDay>(
                      entries: _days,
                      activeIndex: _groupAt(
                        _scroll.hasClients ? _scroll.offset + .01 : 0,
                        offsets,
                      ),
                      idOf: (g) => _date(g.day),
                      labelOf: _label,
                      onSelect: (i) {
                        if (_scroll.hasClients) {
                          _scroll.jumpTo(
                            offsets[i].clamp(
                              0.0,
                              _scroll.position.maxScrollExtent,
                            ),
                          );
                        }
                      },
                      maxHeight: math.max(40, box.maxHeight - 20),
                      maxWidth: math.min(300, math.max(44, box.maxWidth - 20)),
                      keyPrefix: 'codex-draw-date',
                      ticksOnly: true,
                      semanticLabel: context.l10n.codexDeckDates,
                      describePosition: (n) =>
                          '$n / ${_days.length} · ${_label(_days[n - 1])}',
                      hint: context.l10n.codexGroupNavigationHint,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _gridCard(CodexDrawRecord record) {
    final time = DateTime.fromMillisecondsSinceEpoch(record.savedAt);
    return Material(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: record.id == widget.selectedId
              ? context.scheme.primary
              : context.scheme.outlineVariant,
        ),
      ),
      color: context.scheme.surfaceContainerLowest,
      child: InkWell(
        key: ValueKey('codex-history-${record.id}'),
        onTap: () => widget.onOpen(record),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: context.scheme.surfaceContainerLow,
                    child: CodexDrawImage(record, widget.media),
                  ),
                  Positioned(
                    top: 3,
                    right: 3,
                    child: IconButton.filledTonal(
                      tooltip: context.l10n.remove,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => widget.onRemove(record),
                      icon: const Icon(Icons.close, size: 15),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 3, 3, 3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.labelLarge,
                        ),
                        Text(
                          '${_digits(time.hour)}:${_digits(time.minute)} · ${record.codex.displayTitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.codexNewSection,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.playlist_add, size: 17),
                    onPressed: () => widget.onImport(record),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
