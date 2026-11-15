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
  });
  final String name;
  final Object tapGroupId;
  final VoidCallback onClose, onDelete;

  @override
  ConsumerState<FoldInspector> createState() => _FoldInspectorState();
}

class _FoldInspectorState extends ConsumerState<FoldInspector> {
  final _controller = RichTagController();
  final _focus = FocusNode();
  final _fieldKey = GlobalKey<AnnotatedFieldState>();
  late String _name;
  String _previous = '';
  bool _muting = false;
  Tok? _selected;
  int _anchorRevision = 0;
  List<String> _related = const [];
  String? _relatedName;

  EditorNotifier get _editor => ref.read(editorProvider.notifier);

  @override
  void initState() {
    super.initState();
    _name = widget.name;
    _loadBody();
    _controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(FoldInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _name = widget.name;
      _loadBody();
    }
  }

  void _loadBody() {
    final body = ref.read(editorProvider).foldBodies[_name] ?? '';
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
    super.dispose();
  }

  void _onController() {
    if (_muting) return;
    if (_previous != _controller.text) {
      _previous = _controller.text;
      _editor.editFoldBody(_name, _controller.text);
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
      if (next.foldBodies[_name] != _controller.text) {
        setState(_loadBody);
      }
    });
    final state = ref.watch(editorProvider);
    final settings =
        ref.watch(editorSettingsProvider).value ?? const EditorSettings();
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
    final disabled = tokens.isNotEmpty && tokens.every((t) => t.disabled);
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

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              Text('内容 ${tokens.length} 项', style: context.texts.labelMedium),
              if (link != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (name, label) in [
                      (link.positiveName, '正面'),
                      (link.negativeName, '负面'),
                    ])
                      TextButton(
                        key: ValueKey('fold-inspector-$label'),
                        style: TextButton.styleFrom(
                          backgroundColor: _name == name
                              ? context.scheme.primaryContainer
                              : null,
                        ),
                        onPressed: () => setState(() {
                          _name = name;
                          _loadBody();
                        }),
                        child: Text(label),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          DesktopTagPopover(
            tapGroupId: widget.tapGroupId,
            visible: _selected != null,
            anchor: () => _fieldKey.currentState?.selectionAnchor(),
            anchorRevision: _anchorRevision,
            onDismiss: () => setState(() => _selected = null),
            panel: _selected == null
                ? const SizedBox.shrink()
                : _memberPanel(_selected!, settings),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.sizeOf(context).height * .4).clamp(
                  120,
                  320,
                ),
              ),
              child: AnnotatedField(
                key: _fieldKey,
                controller: _controller,
                focusNode: _focus,
                hint: '输入块内提示词…',
                showTrans: settings.showTranslation,
                showWeightWash: settings.showWeightWash,
                fontSize: settings.fontSize,
                scrollable: true,
                minLines: 3,
                padding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击文字即可编辑；下方操作作用于整块。',
            style: context.texts.labelSmall!.copyWith(
              color: context.scheme.outline,
            ),
          ),
          const Divider(),
        ],
      ),
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
        count: null,
        related: const [],
        showWiki: false,
        copyText: _controller.text,
        content: content,
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
