import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class EditableComboField extends StatefulWidget {
  const EditableComboField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.decoration,
    required this.onChanged,
    required this.options,
    required this.emptyLabel,
    this.fieldKey,
    this.menuKey,
    this.toggleKey,
  });

  final Map<String, String> options;
  final String emptyLabel;
  final Key? fieldKey;
  final Key? menuKey;
  final Key? toggleKey;
  final TextEditingController controller;
  final bool enabled;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;

  @override
  State<EditableComboField> createState() => _EditableComboFieldState();
}

class _EditableComboFieldState extends State<EditableComboField> {
  final _menu = MenuController();
  final _focus = FocusNode();
  final _scroll = ScrollController(keepScrollOffset: false);
  String _query = '';
  int _highlight = -1;

  List<String> get _options => [
    for (final name in widget.options.keys)
      if (name.toLowerCase().contains(_query) ||
          widget.options[name]!.toLowerCase().contains(_query))
        name,
  ];

  double get _rowHeight =>
      math.max(40, MediaQuery.textScalerOf(context).scale(16) + 16);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && _menu.isOpen) _menu.close();
  }

  @override
  void didUpdateWidget(EditableComboField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _menu.isOpen) _menu.close();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _show(String text) {
    setState(() {
      _query = text.trim().toLowerCase();
      _highlight = -1;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_menu.isOpen) return;
    final box = context.findRenderObject() as RenderBox;
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    final available =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom -
        bottom;
    if (available < _rowHeight * 3) {
      Scrollable.ensureVisible(context, alignment: .5);
    }
    _menu.open();
  }

  void _choose(String name) {
    final id = widget.options[name]!;
    widget.controller.value = TextEditingValue(
      text: id,
      selection: TextSelection.collapsed(offset: id.length),
    );
    widget.onChanged(id);
    _menu.close();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_menu.isOpen && key == LogicalKeyboardKey.escape) {
      _menu.close();
      return KeyEventResult.handled;
    }
    final down = key == LogicalKeyboardKey.arrowDown;
    if (down || key == LogicalKeyboardKey.arrowUp) {
      if (!_menu.isOpen) _show('');
      final count = _options.length;
      if (count > 0) {
        final previous = _highlight < 0 && !down ? count : _highlight;
        setState(
          () => _highlight = (previous + (down ? 1 : -1)).clamp(0, count - 1),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients || _highlight < 0) return;
          final position = _scroll.position;
          final top = _rowHeight * _highlight;
          final bottom = top + _rowHeight;
          if (top < position.pixels) {
            _scroll.jumpTo(top);
          } else if (bottom > position.pixels + position.viewportDimension) {
            _scroll.jumpTo(
              (bottom - position.viewportDimension).clamp(
                0,
                position.maxScrollExtent,
              ),
            );
          }
        });
      }
      return KeyEventResult.handled;
    }
    if (_menu.isOpen &&
        _highlight >= 0 &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _choose(_options[_highlight]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _overlay(BuildContext context, RawMenuOverlayInfo info) {
    final anchor = info.anchorRect;
    final top = anchor.bottom + 2;
    final insets = MediaQuery.of(context);
    final height =
        (info.overlaySize.height -
                math.max(insets.padding.bottom, insets.viewInsets.bottom) -
                top -
                4)
            .clamp(0.0, 260.0);
    final options = _options;
    final colors = Theme.of(context).colorScheme;
    return Positioned(
      left: anchor.left,
      top: top,
      width: anchor.width,
      child: TapRegion(
        groupId: info.tapRegionGroupId,
        onTapOutside: (_) => _menu.close(),
        child: TextFieldTapRegion(
          child: Material(
            key: widget.menuKey,
            elevation: 4,
            color: colors.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: BorderSide(color: colors.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: options.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(widget.emptyLabel),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      primary: false,
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemExtent: _rowHeight,
                      itemCount: options.length,
                      itemBuilder: (context, index) =>
                          _optionRow(options[index], index, colors),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _optionRow(String name, int index, ColorScheme colors) {
    final selected = widget.controller.text == widget.options[name]!;
    return Semantics(
      selected: selected,
      child: Ink(
        color: index == _highlight ? colors.secondaryContainer : null,
        child: InkWell(
          canRequestFocus: false,
          onTap: () => _choose(name),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected) const Icon(Icons.check, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: _menu,
    childFocusNode: _focus,
    overlayBuilder: _overlay,
    builder: (context, menu, child) => Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        enabled: widget.enabled,
        focusNode: _focus,
        onTap: () {
          if (!menu.isOpen) _show('');
        },
        onChanged: (value) {
          widget.onChanged(value);
          _show(value);
        },
        onSubmitted: (_) => menu.close(),
        decoration: widget.decoration.copyWith(
          suffixIcon: ExcludeFocus(
            child: IconButton(
              key: widget.toggleKey,
              tooltip: MaterialLocalizations.of(context).showMenuTooltip,
              onPressed: widget.enabled
                  ? () {
                      if (menu.isOpen && _query.isEmpty) {
                        menu.close();
                      } else {
                        _show('');
                      }
                    }
                  : null,
              icon: const Icon(Icons.arrow_drop_down),
            ),
          ),
        ),
      ),
    ),
  );
}
