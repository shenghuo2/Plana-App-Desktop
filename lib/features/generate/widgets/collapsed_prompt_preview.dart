import '../../editor/widgets/fold_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../../editor/editor_models.dart';
import '../../editor/editor_settings.dart';

/// Read-only card summary. Keep editor folds and weight colors without editing
/// the draft or displaying its expanded generation payload.
class CollapsedPromptPreview extends ConsumerWidget {
  const CollapsedPromptPreview({
    super.key,
    required this.draft,
    this.enabled = true,
    this.links = const [],
    this.maxLines = 1,
    this.style,
    this.emptyText = '点击编辑…',
  });

  final String draft;
  final List<PromptFoldLink> links;
  final bool enabled;
  final int maxLines;
  final TextStyle? style;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final palette =
        Theme.of(context).extension<EditorPalette>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? EditorPalette.dark
            : EditorPalette.light);
    final base = style ?? context.texts.bodyMedium!;
    if (draft.trim().isEmpty) {
      return Text(emptyText, style: base.copyWith(color: scheme.outline));
    }
    final showWash = ref.watch(
      editorSettingsProvider.select((s) => s.value?.showWeightWash ?? true),
    );
    final (text, bodies) = collapseFolds(draft);
    final folds = parseFoldRefs(text, bodies);
    final icons = foldIconsOf(links);
    final disabledFolds = {
      for (final f in folds)
        if (foldBodyDisabled(bodies[f.name]!)) f.name,
    };
    final weights = <WeightSpan>[];
    final tokens = parseToks(text, weightSpans: weights);
    final boundaries = {
      0,
      text.length,
      for (final w in weights) ...[w.start, w.end],
      for (final t in tokens) ...[t.segStart, t.segEnd],
      for (final f in folds) ...[f.start, f.end],
    }.toList()..sort();

    return LayoutBuilder(
      builder: (context, box) {
        final spans = <InlineSpan>[];
        for (var i = 0; i < boundaries.length - 1; i++) {
          final start = boundaries[i], end = boundaries[i + 1];
          final fold = folds.where((f) => f.start <= start && start < f.end);
          final tok = tokens.where(
            (t) => t.segStart <= start && start < t.segEnd,
          );
          final disabled =
              !enabled ||
              tok.any((t) => t.disabled) ||
              fold.any((f) => disabledFolds.contains(f.name));
          final foreground = disabled
              ? base.copyWith(
                  color: scheme.outline,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: scheme.outline,
                )
              : base;
          if (fold.isNotEmpty) {
            final f = fold.first;
            if (start != f.start) continue;
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  constraints: BoxConstraints(maxWidth: box.maxWidth),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: disabled
                        ? scheme.surfaceContainerHighest
                        : scheme.primary.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text.rich(
                    foldLabelSpan(f.name, icons[f.name], hash: true),
                    // WidgetSpan scales its child with the surrounding text.
                    textScaler: TextScaler.noScaling,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: foreground.copyWith(
                      color: disabled ? scheme.outline : scheme.primary,
                    ),
                  ),
                ),
              ),
            );
            continue;
          }
          Color? wash;
          if (showWash) {
            if (disabled) {
              wash = scheme.onSurface.withValues(alpha: .1);
            } else {
              for (final w in weights) {
                if (start < w.start || start >= w.end) continue;
                final color = palette.weightWash(w.mult);
                if (color != null) {
                  wash = wash == null ? color : Color.alphaBlend(color, wash);
                }
              }
              if (tok.any(
                (t) => isSdWeightSeg(text.substring(t.segStart, t.segEnd)),
              )) {
                final color = scheme.tertiary.withValues(alpha: .16);
                wash = wash == null ? color : Color.alphaBlend(color, wash);
              }
            }
          }
          spans.add(
            TextSpan(
              text: text.substring(start, end),
              style: foreground.copyWith(backgroundColor: wash),
            ),
          );
        }
        return Text.rich(
          TextSpan(children: spans),
          style: base,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
