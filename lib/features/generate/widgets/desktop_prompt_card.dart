import '../../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_text_scale.dart';
import '../../editor/editor_page.dart';
import '../../editor/editor_state.dart';
import '../../editor/widgets/prompt_fullscreen_dialog.dart';

/// A persistent, independent editor session for each sidebar prompt.
class DesktopPromptCard extends StatefulWidget {
  const DesktopPromptCard({
    super.key,
    this.charId,
    this.sectionId,
    this.framed = true,
    this.scrollAnchor,
  });
  final bool framed;
  final String? charId;
  final String? sectionId;
  final GlobalKey? scrollAnchor;

  @override
  State<DesktopPromptCard> createState() => _DesktopPromptCardState();
}

class _DesktopPromptCardState extends State<DesktopPromptCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final editor = OriginalTextBaseline(
      child: ProviderScope(
        overrides: [
          editorProvider.overrideWith(
            () => EditorNotifier(immediateWriteBack: true),
          ),
        ],
        child: EditorPage(
          positive: true,
          charId: widget.charId,
          sectionId: widget.sectionId,
          embedded: true,
          scrollAnchor: widget.scrollAnchor,
        ),
      ),
    );
    if (!widget.framed || widget.charId != null || widget.sectionId != null) {
      return editor;
    }
    return Material(
      color: context.scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: const EdgeInsets.all(12), child: editor),
    );
  }
}

/// Opens the same prompt target in a large desktop editing dialog.
class PromptFullscreenButton extends ConsumerWidget {
  const PromptFullscreenButton({super.key, this.charId, this.sectionId});

  final String? charId;
  final String? sectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: l10nNow.desktopOpenFullScreenPromptEditor,
      icon: const Icon(Icons.open_in_full, size: 16),
      constraints: const BoxConstraints.tightFor(width: 26, height: 32),
      padding: EdgeInsets.zero,
      onPressed: () async {
        final sessions = ref.read(editorSessionsProvider);
        sessions.flushPending();
        await showPromptFullscreenDialog(
          context,
          builder: (_) => OriginalTextBaseline(
            child: ProviderScope(
              overrides: [
                editorProvider.overrideWith(
                  () => EditorNotifier(immediateWriteBack: true),
                ),
              ],
              child: EditorPage(
                positive: true,
                floatingPanels: true,
                charId: charId,
                sectionId: sectionId,
              ),
            ),
          ),
        );
      },
    );
  }
}
