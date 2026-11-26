import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/prompt_block.dart';
import '../../../l10n/l10n.dart';
import '../../editor/inspiration_shortcuts.dart';
import '../../inspiration/tag_library.dart';
import '../../inspiration/tag_models.dart';
import '../assistant_models.dart';

class ProposalBlocks extends ConsumerStatefulWidget {
  const ProposalBlocks({super.key, required this.draw});
  final DrawProposal draw;

  @override
  ConsumerState<ProposalBlocks> createState() => _ProposalBlocksState();
}

class _ProposalBlocksState extends ConsumerState<ProposalBlocks> {
  PromptBlock? _selected;

  Future<void> _save(PromptBlock block) async {
    final partner = block.counterpartIn(widget.draw.blocks);
    final TagLibraryState library =
        ref.read(tagLibraryProvider).value ??
        await ref.read(tagLibraryProvider.future);
    if (!mounted) return;
    await showPromptInspirationEditor(
      ref,
      library,
      preferredCategory: tagCategoryByWebId(block.kind.libraryId),
      allowNegativeOnly: block.negative,
      draft: (
        name: block.name,
        positive: block.negative ? partner?.text ?? '' : block.text,
        negative: block.negative ? block.text : partner?.text ?? '',
        tags: const [],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draw = widget.draw;
    final selected = draw.blocks.contains(_selected) ? _selected : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.temporaryInspirationBlocks,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final block in draw.blocks.where(
              (b) => !b.negative || b.counterpartIn(draw.blocks) == null,
            ))
              ChoiceChip(
                avatar: Icon(
                  kTagCategoryIcons[block.icon ??
                          block.counterpartIn(draw.blocks)?.icon] ??
                      tagCategoryDef(
                        tagCategoryByWebId(block.kind.libraryId)!,
                      ).icon,
                  size: 17,
                ),
                label: Text(block.title),
                selected:
                    selected == block ||
                    selected?.counterpartIn(draw.blocks) == block,
                onSelected: (open) =>
                    setState(() => _selected = open ? block : null),
              ),
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: 8),
          Text(
            [
              if (selected.character >= 0 &&
                  selected.character < draw.characters.length)
                draw.characters[selected.character].name,
              selected.negative
                  ? context.l10n.negativePrompt
                  : context.l10n.positivePrompt,
            ].join(' · '),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          if (selected.counterpartIn(draw.blocks) case final partner?)
            Wrap(
              children: [
                for (final side
                    in selected.negative
                        ? [partner, selected]
                        : [selected, partner])
                  ChoiceChip(
                    label: Text(
                      side.negative
                          ? context.l10n.negativeShort
                          : context.l10n.positiveShort,
                    ),
                    selected: side == selected,
                    onSelected: (_) => setState(() => _selected = side),
                  ),
              ],
            ),
          SelectableText(selected.text),
          TextButton.icon(
            icon: const Icon(Icons.library_add_outlined),
            label: Text(context.l10n.saveSelectionAsInspiration),
            onPressed: () => _save(selected),
          ),
        ],
      ],
    );
  }
}
