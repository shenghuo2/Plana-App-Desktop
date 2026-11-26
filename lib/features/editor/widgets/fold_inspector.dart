import 'fold_icon.dart';
import '../../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/suggestions.dart';
import '../data/tag_completion.dart';
import '../data/tag_favorites.dart';
import '../editor_models.dart';
import '../editor_settings.dart';
import '../editor_state.dart';
import 'annotated_field.dart';
import 'desktop_tag_popover.dart';
import 'prompt_fullscreen_dialog.dart';
import 'rich_tag_controller.dart';
import 'tag_panel.dart';

/// Edits a block's body without replacing its reference in the parent prompt.
/// Both levels of popover share a tap region, so member actions do not dismiss
/// the inspector before their click is delivered.
class FoldInspector extends ConsumerStatefulWidget {
  const FoldInspector({
    super.key,
    required this.name,
    required this.tapGroupId,
    required this.onClose,
    required this.onDelete,
    this.onEditInspiration,
    this.initialPositive,
    this.fullscreen = false,
  });
  final String name;
  final Object tapGroupId;
  final VoidCallback onClose, onDelete;
  final ValueChanged<String>? onEditInspiration;
  final bool fullscreen;
  final bool? initialPositive;

  @override
  ConsumerState<FoldInspector> createState() => _FoldInspectorState();
}

class _FoldInspectorState extends ConsumerState<FoldInspector> {
  final _controller = RichTagController();
  final _focus = FocusNode();
  final _scroll = ScrollController(keepScrollOffset: false);
  final _fieldKey = GlobalKey<AnnotatedFieldState>();
  late String _name;
  bool? _missingPositive;
  bool _attachingSide = false;
  String _previous = '';
  bool _muting = false;
  bool _cursorDragging = false;
  Tok? _selected;
  int _anchorRevision = 0;
  List<String> _related = const [];
  String? _relatedName;
  bool _openingFullscreen = false;

  EditorNotifier get _editor => ref.read(editorProvider.notifier);

  @override
  void initState() {
    super.initState();
    _name = widget.name;
    final link = ref.read(editorProvider).placementOf(_name)?.link;
    if (link != null && widget.initialPositive != null) {
      _selectSide(link, widget.initialPositive!);
    }
    _loadBody();
    _controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(FoldInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _name = widget.name;
      _missingPositive = null;
      _loadBody();
    }
  }

  void _loadBody() {
    final body = _missingPositive == null
        ? ref.read(editorProvider).foldBodies[_name] ?? ''
        : '';
    if (body == _previous && _controller.text == body) return;
    _muting = true;
    _controller.value = TextEditingValue(
      text: body,
      selection: const TextSelection.collapsed(offset: -1),
    );
    _previous = body;
    _selected = null;
    _muting = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onController() {
    if (_muting) return;
    if (_previous != _controller.text) {
      _previous = _controller.text;
      if (_missingPositive case final positive?) {
        if (_previous.trim().isEmpty) return;
        _attachingSide = true;
        try {
          final name = _editor.addTemporaryFoldSide(
            widget.name,
            positive: positive,
            body: _previous,
          );
          if (name != null) {
            _name = name;
            _missingPositive = null;
          }
        } finally {
          _attachingSide = false;
        }
      } else {
        _editor.editFoldBody(_name, _controller.text);
      }
      setState(() => _selected = null);
    } else {
      _route();
    }
  }

  void _route() {
    final text = _controller.text;
    final selection = _controller.selection;
    final tokens = parseToks(text);
    final at = selection.isValid ? selection.extentOffset : -1;
    final index = tokIndexAt(text, at, tokens);
    final tok = index < 0 || at >= text.length ? null : tokens[index];
    if (_selected?.segStart != tok?.segStart) _anchorRevision++;
    setState(() => _selected = tok);
    if (_relatedName != tok?.name) {
      _relatedName = tok?.name;
      _related = const [];
      if (tok != null) {
        ref.read(tagCompletionProvider).relatedOf(tok.name).then((related) {
          if (mounted && _relatedName == tok.name) {
            setState(() => _related = related);
          }
        });
      }
    }
  }

  void _change(String text, int caret, {bool keepPanel = true}) {
    _muting = true;
    _previous = text;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret.clamp(0, text.length)),
    );
    _muting = false;
    _editor.editFoldBody(_name, text, structural: true);
    if (keepPanel) {
      _route();
    } else {
      setState(() => _selected = null);
    }
  }

  void _selectSide(PromptFoldLink link, bool positive) {
    final name = positive ? link.positiveName : link.negativeName;
    _missingPositive = name.isEmpty ? positive : null;
    _name = name.isEmpty ? widget.name : name;
    _selected = null;
    _loadBody();
  }

  void _openFullscreen() {
    if (_openingFullscreen) return;
    _openingFullscreen = true;
    final name = widget.name;
    final link = ref.read(editorProvider).placementOf(name)?.link;
    final side =
        _missingPositive ?? (link == null ? null : link.positiveName == _name);
    final delete = widget.onDelete;
    final edit = widget.onEditInspiration;
    final group = Object();
    // The modal keeps this editor session, but replaces the small popover.
    // Capture actions before dismissing: the parent no longer has a selection.
    widget.onClose();
    showPromptFullscreenDialog(
      context,
      builder: (context) => FoldInspector(
        name: name,
        initialPositive: side,
        fullscreen: true,
        tapGroupId: group,
        onEditInspiration: edit,
        onClose: () => Navigator.of(context).pop(),
        onDelete: () {
          delete();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget _memberPanel(Tok tok, EditorSettings settings) => TagPanel(
    key: const ValueKey('fold-member-actions'),
    tok: tok,
    count: countOf(tok.name),
    related: _related,
    weightStep: settings.weightStep,
    onWrap: (up) =>
        _change(wrapBracket(_controller.text, tok, up: up), tok.nameStart),
    onSetMult: (mult) {
      final next = setTokMult(_controller.text, tok, mult);
      _change(next.$1, next.$2);
    },
    onClear: () {
      final next = clearWeight(_controller.text, tok);
      _change(next.$1, next.$2);
    },
    onToggleDisabled: () =>
        _change(toggleTokDisabled(_controller.text, tok), tok.nameStart),
    onDelete: () {
      final next = deleteTok(_controller.text, tok);
      _change(next.$1, next.$2, keepPanel: false);
    },
    onRename: (name) =>
        _change(renameTok(_controller.text, tok, name), tok.nameStart),
    onAddRelated: (name) {
      final next = insertUnitAt(_controller.text, tok.segEnd, name);
      _change(next.$1, next.$2, keepPanel: false);
    },
    onClose: () => setState(() => _selected = null),
    favorited: ref.watch(tagFavoriteKeysProvider).contains(metaKey(tok.name)),
    onToggleFavorite: () =>
        ref.read(tagFavoritesProvider.notifier).toggle(tok.name),
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(editorProvider, (_, next) {
      if (_attachingSide) return;
      final link = next.foldLinks
          .where(
            (l) =>
                l.positiveName == widget.name || l.negativeName == widget.name,
          )
          .firstOrNull;
      if (_missingPositive == null &&
          link != null &&
          _name != widget.name &&
          link.positiveName != _name &&
          link.negativeName != _name) {
        setState(() => _selectSide(link, link.positiveName.isEmpty));
      } else if (_missingPositive == null &&
          next.foldBodies[_name] != _controller.text) {
        setState(_loadBody);
      }
    });
    final state = ref.watch(editorProvider);
    final settings =
        ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    _controller.showTrans = settings.showTranslation;
    final link = state.foldLinks
        .where(
          (l) => l.positiveName == widget.name || l.negativeName == widget.name,
        )
        .firstOrNull;
    final tokens = parseToks(_controller.text);
    final mixed = tokens.any(
      (t) => (t.effMult - tokens.first.effMult).abs() > .0001,
    );
    final mult = tokens.isEmpty || mixed ? 1.0 : tokens.first.effMult;
    final disabled = allFoldMembersDisabled(tokens);
    final blockTok = Tok(
      segStart: 0,
      segEnd: _name.length,
      coreStart: 0,
      coreEnd: _name.length,
      innerStart: 0,
      innerEnd: _name.length,
      nameStart: 0,
      nameEnd: _name.length,
      braceLevel: 0,
      numMult: mult,
      disabled: disabled,
      name: '#$_name',
    );
    void whole(String Function(String, int, int) edit) {
      if (tokens.isEmpty) return;
      _change(
        edit(_controller.text, 0, tokens.length - 1),
        0,
        keepPanel: false,
      );
    }

    final header = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          Text('内容 ${tokens.length} 项', style: context.texts.labelMedium),
          if (link != null && (link.paired || link.temporaryCategory != null))
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (positive, name, label) in [
                  (true, link.positiveName, '正面'),
                  (false, link.negativeName, '负面'),
                ])
                  TextButton(
                    key: ValueKey('fold-inspector-$label'),
                    style: TextButton.styleFrom(
                      backgroundColor:
                          (_missingPositive == null
                              ? _name == name
                              : _missingPositive == positive)
                          ? context.scheme.primaryContainer
                          : null,
                    ),
                    onPressed: () =>
                        setState(() => _selectSide(link, positive)),
                    child: Text(
                      positive
                          ? context.l10n.positiveShort
                          : context.l10n.negativeShort,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
    final content = DesktopTagPopover(
      tapGroupId: widget.tapGroupId,
      visible: _selected != null && !_cursorDragging,
      anchor: () => _fieldKey.currentState?.selectionAnchor(),
      anchorRevision: _anchorRevision,
      onDismiss: () => setState(() => _selected = null),
      panel: _selected == null
          ? const SizedBox.shrink()
          : _memberPanel(_selected!, settings),
      child: AnnotatedField(
        key: _fieldKey,
        controller: _controller,
        focusNode: _focus,
        onCursorDrag: (dragging) => setState(() => _cursorDragging = dragging),
        hint: switch (_missingPositive) {
          true => context.l10n.emptyTemporaryPrompt(context.l10n.positiveShort),
          false => context.l10n.emptyTemporaryPrompt(
            context.l10n.negativeShort,
          ),
          null => '输入块内提示词…',
        },
        showTrans: settings.showTranslation,
        showWeightWash: settings.showWeightWash,
        fontSize: settings.fontSize,
        scrollable: true,
        scrollController: _scroll,
        minLines: 3,
        padding: const EdgeInsets.symmetric(vertical: 4),
      ),
    );
    final footer = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          l10nNow.desktopClickTextToEditItTheControlsBelow,
          style: context.texts.labelSmall!.copyWith(
            color: context.scheme.outline,
          ),
        ),
        const Divider(),
      ],
    );
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          if (_selected != null) {
            setState(() => _selected = null);
          } else {
            widget.onClose();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TagPanel(
        key: const ValueKey('fold-inspector'),
        tok: blockTok,
        titleSpan: foldLabelSpan(
          _name,
          foldIconsOf(state.foldLinks)[_name],
          hash: true,
        ),
        count: null,
        related: const [],
        showWiki: false,
        copyText: _controller.text,
        content: content,
        contentHeader: header,
        contentFooter: footer,
        constrainContent: true,
        expandContent: widget.fullscreen,
        temporaryInspiration: link?.temporaryCategory != null,
        onFullscreen: widget.fullscreen ? null : _openFullscreen,
        onEditInspiration: widget.onEditInspiration == null
            ? null
            : () {
                final name = _name;
                if (widget.fullscreen) widget.onClose();
                widget.onEditInspiration!(name);
              },
        mixedWeight: mixed,
        weightStep: settings.weightStep,
        onWrap: (up) =>
            whole((text, first, last) => batchWrap(text, first, last, up: up)),
        onSetMult: (mult) =>
            whole((text, first, last) => batchSetMult(text, first, last, mult)),
        onClear: () => whole(batchClearWeight),
        onToggleDisabled: () => whole(
          (text, first, last) => batchSetDisabled(text, first, last, !disabled),
        ),
        onDelete: widget.onDelete,
        onClose: widget.onClose,
        onAddRelated: (_) {},
      ),
    );
  }
}
