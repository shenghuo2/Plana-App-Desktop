import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/ui_prefs.dart';
import '../../core/util/prompt_block.dart';
import '../../core/theme/theme_settings.dart';
import '../../l10n/l10n.dart';
import '../generate/canvas_state.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../inspiration/tag_editor_page.dart';
import '../inspiration/tag_library.dart';
import '../inspiration/tag_models.dart';
import 'editor_models.dart';
import 'editor_state.dart';

/// Opens the library's own editor. Its save result belongs only to the prompt
/// and canvas that opened it, even when multiple blocks use the same entry.
Future<void> openPromptInspiration(
  WidgetRef ref, {
  Set<int>? selected,
  String? foldName,
  required VoidCallback onApplied,
}) async {
  assert((selected == null) != (foldName == null));
  final context = ref.context;
  final state = ref.read(editorProvider);
  final canvas = ref.read(canvasWorkspaceProvider).activeId;
  final placement = foldName == null ? null : state.placementOf(foldName);
  if (foldName != null && placement == null) return;
  final slot = selected == null
      ? null
      : selectedFoldSlot(state.activeText, state.foldBodies, selected);
  var pos = state.foldBodies[placement?.positive?.name] ?? '';
  var neg = state.foldBodies[placement?.negative?.name] ?? '';
  if (selected != null) {
    final draft =
        slot?.body(state.foldBodies) ??
        stripFolds(
          expandFolds(
            extractUnitsDraft(state.activeText, state.foldBodies, selected),
            state.foldBodies,
          ),
        ).trim();
    if (draft.isEmpty) return;
    if (state.activePositive) {
      pos = draft;
    } else {
      neg = draft;
    }
  }

  final TagLibraryState library =
      ref.read(tagLibraryProvider).value ??
      await ref.read(tagLibraryProvider.future);
  if (!context.mounted) return;
  final source = placement == null
      ? null
      : _sourceOf(library, placement, pos, neg);
  final temporaryKind = PromptBlockKind.values
      .where((kind) => kind.libraryId == placement?.link?.temporaryCategory)
      .firstOrNull;
  final foldTitle =
      placement?.positive?.name ??
      (placement?.negative?.name ?? '').replaceFirst(RegExp(r'·排除$'), '');
  await showPromptInspirationEditor(
    ref,
    library,
    source: source,
    preferredCategory: temporaryKind == null
        ? null
        : tagCategoryByWebId(temporaryKind.libraryId),
    allowNegativeOnly: !state.activePositive || placement?.negative != null,
    draft: (
      name: temporaryKind == null
          ? foldTitle
          : foldTitle
                .replaceFirst('${temporaryKind.glyph} ', '')
                .replaceFirst(
                  RegExp(
                    ' · ${temporaryKind.label}'
                    r'(?=(?: \d+)?$)',
                  ),
                  '',
                ),
      positive: pos,
      negative: neg,
      tags: const [],
    ),
    onSaved: (entry) {
      if (!context.mounted) return;
      if (selected != null &&
          !ref.read(themeSettingsProvider).foldAfterInspirationSave) {
        return;
      }
      if (!identical(ref.read(editorProvider), state) ||
          ref.read(canvasWorkspaceProvider).activeId != canvas ||
          (selected != null && slot == null)) {
        hintSnack(context, context.l10n.savedWithoutFolding);
        return;
      }
      ref
          .read(editorProvider.notifier)
          .applySavedInspiration(
            entryId: entry.id,
            title: entry.name,
            selection: slot,
            editing: placement,
            rename: source?.name != entry.name,
            positiveBody: entry.positive == source?.positive
                ? null
                : entry.positive,
            negativeBody: entry.negative == source?.negative
                ? null
                : entry.negative,
          );
      onApplied();
    },
  );
}

/// Shared by a canvas selection, a placed block and a read-only AI proposal.
Future<void> showPromptInspirationEditor(
  WidgetRef ref,
  TagLibraryState library, {
  required TagDraft draft,
  TagEntry? source,
  TagCategory? preferredCategory,
  bool allowNegativeOnly = false,
  ValueChanged<TagEntry>? onSaved,
}) async {
  final cats = library.visibleCategories;
  const pref = 'promptInspirationSave';
  final previous = ref.read(uiPrefsProvider).lastPages[pref];
  final last = previous == null ? null : tagCategoryByWebId(previous);
  final cat =
      source?.category ??
      (cats.contains(preferredCategory) ? preferredCategory : null) ??
      (cats.contains(last) ? last : null) ??
      cats.firstOrNull;
  if (cat == null) return;
  await showTagEditor(
    ref.context,
    cat: cat,
    edit: source,
    categories: cats,
    lastPageKey: pref,
    allowNegativeOnly: allowNegativeOnly,
    draft: draft,
    onSaved: onSaved,
  );
}

TagEntry? _sourceOf(
  TagLibraryState library,
  PlacedPromptFold placed,
  String pos,
  String neg,
) {
  if (placed.link?.temporaryCategory != null) return null;
  final id = placed.link?.sourceEntryId;
  if (id != null) {
    final local = library.entries.where((e) => e.id == id).firstOrNull;
    if (local != null || !id.startsWith('pub_')) return local;
    return library.entries
        .where((e) => e.publicId == id.substring(4))
        .singleOrNull;
  }
  // Legacy drafts contain the displayed name and words only. A duplicate or
  // an unrelated namesake must never be treated as the source for an update.
  bool matches(String name, String base) =>
      name == base ||
      RegExp(
        '^${RegExp.escape(base)}(?: · | )'
        r'(?:[2-9]|[1-9]\d+)$',
      ).hasMatch(name);
  return library.entries.where((entry) {
    final title = sanitizeFoldName(entry.name);
    return (placed.positive == null ||
            (matches(placed.positive!.name, title) &&
                pos == entry.positive.trim())) &&
        (placed.negative == null ||
            (matches(placed.negative!.name, '$title·排除') &&
                neg == entry.negative.trim()));
  }).singleOrNull;
}
