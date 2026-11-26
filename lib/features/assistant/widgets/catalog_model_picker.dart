import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/l10n.dart';
import '../model_catalog.dart';

/// 模型列表多选。条数可能上百,给个搜索框。[selected] 是已经加上的,返回勾完的全部;
/// 关掉返回 null。
typedef CatalogPick = ({
  Set<String> selected,
  Map<String, EndpointModelKind> overrides,
});
Future<CatalogPick?> showCatalogModelPicker(
  BuildContext context,
  Map<String, CatalogModel> models,
  Set<String> selected,
  Map<String, EndpointModelKind> overrides,
  bool image, {
  Map<String, String> displayNames = const {},
  bool allowClassification = true,
}) => showModalBottomSheet<CatalogPick>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ModelPicker(
    models: models,
    selected: selected,
    overrides: overrides,
    image: image,
    displayNames: displayNames,
    allowClassification: allowClassification,
  ),
);

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({
    required this.models,
    required this.selected,
    required this.overrides,
    required this.image,
    required this.displayNames,
    required this.allowClassification,
  });

  final Map<String, CatalogModel> models;
  final Map<String, EndpointModelKind> overrides;
  final bool image;
  final Map<String, String> displayNames;
  final bool allowClassification;
  final Set<String> selected;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _q = '';
  late final Set<String> _on = {...widget.selected};
  late final _overrides = Map.of(widget.overrides);
  bool _all = false;
  EndpointModelKind _kind(String m) => _overrides[m] ?? widget.models[m]!.kind;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final q = _q.trim().toLowerCase();
    final list = [
      for (final m in widget.models.keys)
        if ((_all ||
                _kind(m).supports(widget.image) ||
                _kind(m) == EndpointModelKind.unknown ||
                _on.contains(m)) &&
            (m.toLowerCase().contains(q) ||
                (widget.displayNames[m] ?? '').toLowerCase().contains(q)))
          m,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.models.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                  child: Text(
                    widget.allowClassification
                        ? context.l10n.noImageModelsAvailable
                        : context.l10n.planEmpty,
                    style: context.texts.bodyMedium,
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => _q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: context.l10n.searchNModels(
                        widget.models.length,
                      ),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                if (widget.allowClassification)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: FilterChip(
                        label: Text(context.l10n.catalogAll),
                        selected: _all,
                        onSelected: (v) => setState(() => _all = v),
                      ),
                    ),
                  ),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(context.l10n.noModelsInGroup),
                  ),
                Flexible(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final m = list[i];
                      final on = _on.contains(m);
                      final kind = _kind(m), l = context.l10n;
                      final source = _overrides.containsKey(m)
                          ? l.catalogAssigned
                          : switch (widget.models[m]!.source) {
                              ModelEvidence.unknown => l.catalogUnknown,
                              ModelEvidence.provider => l.catalogRemote,
                              ModelEvidence.directory => l.catalogDirectory,
                            };
                      String label(EndpointModelKind k) => switch (k) {
                        EndpointModelKind.chat => l.chatModelField,
                        EndpointModelKind.image => l.imageModelField,
                        EndpointModelKind.chatAndImage => l.catalogBoth,
                        EndpointModelKind.embedding => l.catalogEmbedding,
                        EndpointModelKind.transcription =>
                          l.catalogTranscription,
                        EndpointModelKind.speechSynthesis => l.catalogSpeech,
                        EndpointModelKind.other => l.catalogOther,
                        EndpointModelKind.unknown => l.catalogAuto,
                      };
                      return CheckboxListTile(
                        dense: true,
                        value: on,
                        controlAffinity: ListTileControlAffinity.trailing,
                        title: Text(
                          widget.displayNames[m] ?? m,
                          style: TextStyle(
                            fontWeight: on ? FontWeight.w700 : null,
                            color: on ? scheme.primary : null,
                          ),
                        ),
                        subtitle: !widget.allowClassification
                            ? null
                            : Text(
                                kind == EndpointModelKind.unknown
                                    ? source
                                    : '${label(kind)} · $source',
                              ),
                        secondary: !widget.allowClassification
                            ? const Icon(Icons.chat_bubble_outline, size: 18)
                            : PopupMenuButton<EndpointModelKind>(
                                tooltip: l.catalogAssign,
                                icon: const Icon(Icons.tune, size: 18),
                                onSelected: (k) => setState(() {
                                  if (k == EndpointModelKind.unknown) {
                                    _overrides.remove(m);
                                  } else {
                                    _overrides[m] = k;
                                  }
                                  if (_kind(m) != EndpointModelKind.unknown &&
                                      !_kind(m).supports(widget.image)) {
                                    _on.remove(m);
                                  }
                                }),
                                itemBuilder: (_) => [
                                  for (final k in EndpointModelKind.values)
                                    PopupMenuItem(
                                      value: k,
                                      child: Text(label(k)),
                                    ),
                                ],
                              ),
                        onChanged:
                            !on &&
                                kind != EndpointModelKind.unknown &&
                                !kind.supports(widget.image)
                            ? null
                            : (v) => setState(() {
                                if (v ?? false) {
                                  _on.add(m);
                                  if (kind == EndpointModelKind.unknown) {
                                    _overrides[m] = widget.image
                                        ? EndpointModelKind.image
                                        : EndpointModelKind.chat;
                                  }
                                } else {
                                  _on.remove(m);
                                }
                              }),
                      );
                    },
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, (
                      selected: _on,
                      overrides: _overrides,
                    )),
                    child: Text(
                      widget.models.isEmpty
                          ? context.l10n.close
                          : context.l10n.doneSelectedN(_on.length),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
