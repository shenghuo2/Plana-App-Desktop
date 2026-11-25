import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop.dart';
import '../../core/store/app_stores.dart';
import '../../core/theme/app_skin.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/editor_theme.dart';
import '../../core/ui/image_drop.dart';
import '../../core/util/image_pick.dart';
import '../../l10n/l10n.dart';
import '../gallery/widgets/gallery_grid_sheet.dart';
import '../import/image_metadata.dart';
import '../import/import_panel.dart';
import 'metadata_diff.dart';

part 'metadata_compare_preview.dart';

String _letter(int slot) => slot == 0 ? 'A' : 'B';

class _Side {
  const _Side(this.image, this.meta);
  final PickedImage image;
  final ImageMetadata? meta;
}

class _Comparison {
  _Comparison(this.a, this.b, this.l)
    : params = diffParams(a, b, l),
      pos = diffTags(a.prompt, b.prompt),
      neg = diffTags(a.negativePrompt, b.negativePrompt),
      characters = diffCharacters(a, b);
  final ImageMetadata a, b;
  final AppLocalizations l;
  final List<ParamRow> params;
  final List<TagDiff> pos, neg;
  final List<CharDiff> characters;
  late final counts = _countTags();

  Map<TagChange, int> _countTags() {
    final result = <TagChange, int>{};
    for (final group in [
      pos,
      neg,
      for (final c in characters) ...[c.prompt, c.uc],
    ]) {
      for (final tag in group) {
        result.update(tag.change, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return result;
  }

  String report() {
    final out = StringBuffer(l.compareImages);
    void tags(String label, List<TagDiff> diffs) {
      for (final tag in diffs.where((t) => t.change != TagChange.same)) {
        final change = switch (tag.change) {
          TagChange.onlyA => l.onlyInA,
          TagChange.onlyB => l.onlyInB,
          TagChange.weight =>
            '${fmtWeight(tag.weightA!)} → ${fmtWeight(tag.weightB!)}',
          TagChange.moved => l.orderChanged,
          TagChange.same => '',
        };
        out.write('\n$label · $change · ${tag.text}');
      }
    }

    for (final p in params.where((p) => p.differs)) {
      out.write('\n${p.label}   ${p.a ?? '—'} → ${p.b ?? '—'}');
    }
    tags(l.positivePrompt, pos);
    tags(l.negativePrompt, neg);
    for (final c in characters) {
      final name = l.characterN(c.index + 1);
      if (c.posA != c.posB) {
        out.write('\n$name   ${c.posA ?? '—'} → ${c.posB ?? '—'}');
      }
      tags('$name · ${l.positivePrompt}', c.prompt);
      tags('$name · ${l.negativePrompt}', c.uc);
    }
    if (out.length == l.compareImages.length) out.write('\n${l.identical}');
    return out.toString();
  }
}

class MetadataCompareView extends ConsumerStatefulWidget {
  const MetadataCompareView({super.key, this.desktopViewportHeight});
  final double? desktopViewportHeight;
  @override
  ConsumerState<MetadataCompareView> createState() =>
      _MetadataCompareViewState();
}

class _MetadataCompareViewState extends ConsumerState<MetadataCompareView> {
  final _sides = <_Side?>[null, null];
  final _inspectorScroll = ScrollController();
  _Comparison? _comparison;
  bool _loading = false, _showSame = false, _diffOnly = false;
  TagChange? _filter;
  double _fraction = .56;

  @override
  void dispose() {
    _inspectorScroll.dispose();
    super.dispose();
  }

  Future<void> _fill(
    int slot,
    Future<List<PickedImage>> Function() read,
  ) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final picked = await read();
      if (picked.isEmpty || !mounted) return;
      final sides = <_Side>[];
      for (final image in picked.take(2)) {
        sides.add(_Side(image, await extractImageMetadata(image.bytes)));
      }
      if (!mounted) return;
      setState(() {
        _sides[slot] = sides.first;
        if (sides.length == 2) _sides[1 - slot] = sides.last;
        _comparison = null;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.importFailed(error.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _files(int slot) => _fill(slot, () => pickImageFiles(context));
  Future<void> _gallery(int slot) => _fill(slot, () async {
    final store = ref.read(appStoresProvider).gallery;
    final image = await showGalleryGrid(
      context,
      desktop: ref.read(desktopModeProvider),
      pickImage: true,
    );
    if (image == null || !mounted) return [];
    final bytes = image.bytes ?? await store.readImage(image.id);
    if (!mounted) return [];
    if (bytes == null) throw StateError(context.l10n.imageNotReady);
    return [PickedImage('plana_${image.seed}.png', bytes)];
  });

  void _swap() => setState(() {
    final first = _sides.first;
    _sides[0] = _sides.last;
    _sides[1] = first;
    _comparison = null;
  });
  void _clear([int? slot]) => setState(() {
    if (slot != 1) _sides[0] = null;
    if (slot != 0) _sides[1] = null;
    _comparison = null;
  });
  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.copied)));
  }

  void _use(int slot) {
    final image = _sides[slot]!.image;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ImportImagePanel(
          bytes: image.bytes,
          fileName: image.name,
          displayName: image.baseName,
        ),
      ),
    );
  }

  Color _colorOf(TagChange change) => switch (change) {
    TagChange.onlyA => context.scheme.error,
    TagChange.onlyB => context.editor.oc,
    TagChange.weight => context.editor.weightUp,
    TagChange.moved => context.editor.weightDown,
    TagChange.same => context.scheme.onSurface,
  };

  List<TagDiff> _visibleTags(List<TagDiff> tags) => [
    for (final t in tags)
      if ((_filter == null || t.change == _filter) &&
          (!_diffOnly || t.change != TagChange.same))
        t,
  ];

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final a = _sides[0]?.meta, b = _sides[1]?.meta;
    if (a != null &&
        b != null &&
        (_comparison == null || _comparison!.l != l)) {
      _comparison = _Comparison(a, b, l);
    }
    final preview = _ComparePreview(
      sides: List.of(_sides),
      busy: _loading,
      files: _files,
      gallery: _gallery,
      clear: _clear,
      swap: _swap,
      drop: (slot, files) => _fill(slot, () async => files),
    );
    final any = _sides.any((s) => s != null);
    final desktop = widget.desktopViewportHeight != null;
    final actions = Wrap(
      alignment: desktop ? WrapAlignment.end : WrapAlignment.start,
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (any)
          Text(
            _sides.every((s) => s != null)
                ? l.compareReady
                : l.compareEmptySlot(_letter(_sides.indexOf(null))),
            style: context.texts.labelMedium,
          ),
        OutlinedButton.icon(
          icon: const Icon(Icons.swap_horiz, size: 17),
          label: Text(l.swapAB),
          onPressed: any && !_loading ? _swap : null,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.delete_outline, size: 17),
          label: Text(l.compareClear),
          onPressed: any && !_loading ? _clear : null,
        ),
      ],
    );
    return Padding(
      padding: desktop
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: LayoutBuilder(
        builder: (context, box) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final height = widget.desktopViewportHeight ?? box.maxHeight;
          final wide = box.maxWidth >= 860 * scale && height >= 470 * scale;
          final body = _inspector(wide);
          final gap = SizedBox(height: desktop ? 16 : 8);
          if (!wide) {
            final children = [
              actions,
              gap,
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              SizedBox(height: 450 * scale, child: preview),
              const SizedBox(height: 12),
              body,
            ];
            return desktop
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  )
                : ListView(primary: false, children: children);
          }
          final width = box.maxWidth - 14;
          final previewWidth = (width * _fraction)
              .clamp(400 * scale, width - 358 * scale)
              .toDouble();
          return SizedBox(
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                actions,
                gap,
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: previewWidth, child: preview),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (d) => setState(() {
                            final min = 400 * scale / width;
                            final max = 1 - 358 * scale / width;
                            _fraction =
                                (_fraction.clamp(min, max) + d.delta.dx / width)
                                    .clamp(min, max);
                          }),
                          child: SizedBox(
                            width: 14,
                            child: Center(
                              child: Container(
                                width: 3,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: context.scheme.outlineVariant,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _inspector(bool bounded) {
    final l = context.l10n;
    final diff = _comparison;
    final labels = {
      TagChange.onlyA: l.onlyInA,
      TagChange.onlyB: l.onlyInB,
      TagChange.weight: l.weight,
      TagChange.moved: l.compareTagPosition,
    };
    final filters = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final kind in <TagChange?>[null, ...labels.keys])
          Builder(
            builder: (context) {
              final selected = _filter == kind;
              final accent = kind == null
                  ? context.scheme.primary
                  : _colorOf(kind);
              final n = kind == null ? 0 : (diff?.counts[kind] ?? 0);
              final emphasizeCount = selected || n > 0;
              return ChoiceChip(
                label: kind == null
                    ? Text(l.compareAllChanges)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            labels[kind]!,
                            style: TextStyle(
                              color: selected
                                  ? accent
                                  : context.scheme.onSurface,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 14),
                          ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 20),
                            child: Text(
                              '$n',
                              semanticsLabel: l.differentN(n),
                              textAlign: TextAlign.end,
                              strutStyle: const StrutStyle(
                                fontSize: 11.5,
                                height: 1,
                                forceStrutHeight: true,
                              ),
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1,
                                fontWeight: emphasizeCount
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: emphasizeCount
                                    ? accent
                                    : context.scheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                shape: const StadiumBorder(),
                side: BorderSide(
                  color: selected
                      ? accent.withValues(alpha: .42)
                      : context.scheme.outlineVariant.withValues(alpha: .8),
                ),
                selectedColor: accent.withValues(alpha: .13),
                padding: kind == null
                    ? const EdgeInsets.symmetric(horizontal: 6)
                    : const EdgeInsets.fromLTRB(6, 0, 2, 0),
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                showCheckmark: false,
                selected: selected,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: diff == null
                    ? null
                    : (_) => setState(
                        () => _filter = _filter == kind ? null : kind,
                      ),
              );
            },
          ),
        TextButton.icon(
          icon: Icon(
            _diffOnly ? Icons.check_box : Icons.check_box_outline_blank,
            size: 17,
          ),
          label: Text(l.compareDiffOnly),
          onPressed: diff == null
              ? null
              : () => setState(() => _diffOnly = !_diffOnly),
        ),
      ],
    );
    final emptySlot = _sides.indexOf(null);
    final slot = emptySlot >= 0
        ? emptySlot
        : _sides.indexWhere((s) => s?.meta == null);
    final empty = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.compare_outlined, color: context.scheme.primary, size: 30),
        const SizedBox(height: 12),
        Text(
          l.compareEmpty,
          style: context.texts.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          l.compareInspectHint,
          textAlign: TextAlign.center,
          style: context.texts.bodySmall,
        ),
        for (final (i, s) in _sides.indexed)
          if (s != null && s.meta == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.noMetadataFor(_letter(i)),
                textAlign: TextAlign.center,
              ),
            ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            FilledButton(
              onPressed: _loading ? null : () => _files(slot),
              child: Text(l.compareOpenFile),
            ),
            OutlinedButton(
              onPressed: _loading ? null : () => _gallery(slot),
              child: Text(l.comparePickGallery),
            ),
          ],
        ),
      ],
    );
    final details = diff == null
        ? Center(
            child: Padding(padding: const EdgeInsets.all(20), child: empty),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _paramsSection(diff.params),
              for (final (label, tags, a, b) in [
                (l.positivePrompt, diff.pos, diff.a.prompt, diff.b.prompt),
                (
                  l.negativePrompt,
                  diff.neg,
                  diff.a.negativePrompt,
                  diff.b.negativePrompt,
                ),
              ])
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _promptSection(label, tags, a, b),
                ],
              if (diff.characters.isNotEmpty) ...[
                const SizedBox(height: 12),
                _sectionLabel(l.characterPrompts),
                for (final c in diff.characters)
                  if (_filter == null ||
                      [...c.prompt, ...c.uc].any((t) => t.change == _filter) ||
                      (_filter == TagChange.moved && c.posA != c.posB))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _charCard(c),
                    ),
              ],
              const Divider(),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final i in [0, 1])
                    OutlinedButton(
                      onPressed: () => _use(i),
                      child: Text(l.compareUseSide(_letter(i))),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(l.compareCopyReport),
                    onPressed: () => _copy(diff.report()),
                  ),
                ],
              ),
            ],
          );
    final content = Padding(padding: const EdgeInsets.all(12), child: details);
    return _ComparePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: filters,
          ),
          const Divider(height: 1),
          if (bounded)
            Expanded(
              child: diff == null
                  ? content
                  : Scrollbar(
                      controller: _inspectorScroll,
                      child: SingleChildScrollView(
                        controller: _inspectorScroll,
                        child: content,
                      ),
                    ),
            )
          else
            content,
        ],
      ),
    );
  }

  Widget _badge(int i) {
    final color = i == 0 ? context.scheme.error : context.editor.oc;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        i == 0 ? 'A' : 'B',
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }

  // ---------------- 分区 ----------------

  Widget _sectionLabel(String text, {Widget? trailing}) {
    return Row(
      children: [
        Flexible(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: context.scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (trailing != null) const SizedBox(width: 8),
        ?trailing,
      ],
    );
  }

  Widget _status(String text) => Text(
    text,
    style: TextStyle(fontSize: 12.5, color: context.scheme.outline),
  );

  BoxDecoration get _card => BoxDecoration(
    color: context.scheme.surfaceContainerLow,
    border: Border.all(
      color: context.scheme.outlineVariant.withValues(alpha: .65),
    ),
    borderRadius: BorderRadius.circular(11),
  );

  Widget _paramsSection(List<ParamRow> rows) {
    final scheme = context.scheme;
    final diff = rows.where((r) => r.differs).toList();
    final same = rows.where((r) => !r.differs).toList();
    Widget divider() => Divider(
      height: 1,
      thickness: 1,
      color: scheme.outlineVariant.withValues(alpha: .4),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(
          context.l10n.genParams,
          trailing: _status(
            diff.isEmpty
                ? context.l10n.identical
                : context.l10n.differentN(diff.length),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          decoration: _card,
          child: Column(
            children: [
              if (diff.isNotEmpty)
                _paramRow(null, _badge(0), _badge(1), vertical: 8),
              for (final r in diff) ...[
                divider(),
                _paramRow(
                  r,
                  _value(r.a, scheme.error),
                  _value(r.b, context.editor.oc),
                ),
              ],
              if (same.isNotEmpty) ...[
                if (diff.isNotEmpty) divider(),
                InkWell(
                  onTap: () => setState(() => _showSame = !_showSame),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
                    child: Row(
                      children: [
                        Text(
                          context.l10n.identicalN(same.length),
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          _showSame ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: scheme.outline,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showSame)
                  for (final r in same) ...[
                    divider(),
                    _paramRow(
                      r,
                      _value(
                        r.a,
                        scheme.onSurfaceVariant,
                        weight: FontWeight.w400,
                      ),
                      null,
                    ),
                  ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 一行参数:键名 | A | B;[b] 为 null 时 [a] 占满两栏(相同项)。
  Widget _paramRow(ParamRow? r, Widget a, Widget? b, {double vertical = 10}) {
    final scheme = context.scheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: vertical),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: r == null
                ? null
                : Text(
                    // 原始键名多是 snake_case,下划线 / 点后允许折行
                    r.rawKey
                        ? r.label.replaceAllMapped(
                            RegExp(r'[_.]'),
                            (m) => '${m[0]}​',
                          )
                        : r.label,
                    style: r.rawKey
                        ? mono(
                            context,
                            size: 12,
                            weight: FontWeight.w400,
                            color: scheme.onSurfaceVariant,
                          )
                        : TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                  ),
          ),
          const SizedBox(width: 8),
          if (b == null)
            Expanded(child: a)
          else ...[
            Expanded(
              child: Align(alignment: Alignment.topLeft, child: a),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.topLeft, child: b),
            ),
          ],
        ],
      ),
    );
  }

  Widget _value(
    String? v,
    Color color, {
    FontWeight weight = FontWeight.w500,
  }) => Text(
    v ?? '—',
    style: mono(
      context,
      size: 13.5,
      weight: weight,
      color: v == null ? context.scheme.outline : color,
    ),
  );

  Widget _promptSection(String label, List<TagDiff> tags, String a, String b) {
    final l = context.l10n;
    final visible = _visibleTags(tags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(label, style: context.texts.titleSmall),
            Wrap(
              children: [
                for (final (i, raw) in [a, b].indexed)
                  TextButton(
                    onPressed: raw.isEmpty ? null : () => _copy(raw),
                    child: Text(l.copyWhat(_letter(i))),
                  ),
              ],
            ),
          ],
        ),
        if (visible.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: _card,
            child: _tagText(visible),
          )
        else
          _status(tagsDiffer(tags) ? l.compareNoMatches : l.identical),
        if (a.isNotEmpty || b.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            maintainState: false,
            title: Text(l.compareOriginals, style: context.texts.labelMedium),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, raw) in [a, b].indexed)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _badge(i),
                            const SizedBox(height: 6),
                            SelectableText(raw.isEmpty ? '—' : raw),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  Widget _tagText(List<TagDiff> d) {
    final scheme = context.scheme;
    final spans = <InlineSpan>[];
    for (final (i, t) in d.indexed) {
      if (i > 0) {
        spans.add(
          TextSpan(
            text: ', ',
            style: TextStyle(color: scheme.outline),
          ),
        );
      }
      final c = _colorOf(t.change);
      spans.add(
        TextSpan(
          text: t.text,
          style: t.change == TagChange.same
              ? null
              : TextStyle(
                  color: c,
                  backgroundColor: c.withValues(alpha: .13),
                  decoration: t.change == TagChange.onlyA
                      ? TextDecoration.lineThrough
                      : null,
                  decorationColor: c,
                ),
        ),
      );
      if (t.change == TagChange.weight) {
        spans.add(
          TextSpan(
            text: ' ${fmtWeight(t.weightA!)}→${fmtWeight(t.weightB!)}',
            style: mono(context, size: 12, color: c),
          ),
        );
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      style: TextStyle(fontSize: 14, height: 1.6, color: scheme.onSurface),
    );
  }

  Widget _charCard(CharDiff c) {
    final scheme = context.scheme;
    final posChanged = c.posA != c.posB;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                context.l10n.characterN(c.index + 1),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              if (posChanged)
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: c.posA ?? '—',
                          style: TextStyle(color: scheme.error),
                        ),
                        const TextSpan(text: ' → '),
                        TextSpan(
                          text: c.posB ?? '—',
                          style: TextStyle(color: context.editor.oc),
                        ),
                      ],
                    ),
                    style: mono(
                      context,
                      size: 12.5,
                      weight: FontWeight.w500,
                      color: scheme.outline,
                    ),
                  ),
                )
              else if (c.posA != null)
                Text(
                  c.posA!,
                  style: mono(
                    context,
                    size: 12.5,
                    weight: FontWeight.w400,
                    color: scheme.outline,
                  ),
                ),
              const Spacer(),
              if (!c.differs) _status(context.l10n.identical),
            ],
          ),
          if (_visibleTags(c.prompt).isNotEmpty) ...[
            const SizedBox(height: 5),
            _tagText(_visibleTags(c.prompt)),
          ],
          if (_visibleTags(c.uc).isNotEmpty) ...[
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3.5, right: 6),
                  child: Text(
                    'UC',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.error.withValues(alpha: .85),
                    ),
                  ),
                ),
                Expanded(child: _tagText(_visibleTags(c.uc))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
