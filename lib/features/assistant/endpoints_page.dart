library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/haptics.dart';
import '../../core/ui/editable_combo_field.dart';
import 'widgets/assistant_tag.dart';
import '../generate/widgets/common.dart'
    show
        confirmDialog,
        dragEndHaptic,
        dragProxy,
        dragStartHaptic,
        hintSnack,
        sharedAxisRoute;
import 'agent_model.dart'
    show
        assistantModelPrefProvider,
        assistantModelProvider,
        availableEndpointModel,
        imageChoiceKeyOf,
        kImageKeyPrefix,
        customEndpointIdOf,
        customModelKey;
import 'custom_endpoint.dart';
import 'llm/http_provider.dart' show llmProviderFor;
import '../../l10n/l10n.dart';

/// 打开接口管理页，并选中要编辑的接口。
Future<void> openEndpointsPage(BuildContext context, {String? editId}) =>
    Navigator.of(context).push(sharedAxisRoute(EndpointsPage(editId: editId)));

/// 「添加接口」那张卡的记号。
const _kAdd = '';

class EndpointsPage extends ConsumerStatefulWidget {
  const EndpointsPage({super.key, this.editId});

  final String? editId;

  @override
  ConsumerState<EndpointsPage> createState() => _EndpointsPageState();
}

class _EndpointsPageState extends ConsumerState<EndpointsPage> {
  /// 当前编辑的接口 id，或新建表单 [_kAdd]。
  late String _open = widget.editId ?? _kAdd;
  final _pending = <String>{};
  int _revision = 0;

  /// 展开的表单里有没保存的改动。
  bool _dirty = false;

  Future<bool> _discard() => confirmDialog(
    context,
    title: context.l10n.discardChangesQ,
    message: context.l10n.unsavedLost,
    confirmLabel: context.l10n.discardAction,
  );

  Future<void> _toggle(String id) async {
    if (id == _open || (_dirty && !await _discard())) return;
    if (!mounted) return;
    Haptics.selection();
    setState(() {
      _open = id;
      _dirty = false;
    });
  }

  void _saved(CustomEndpoint e) {
    Haptics.selection();
    setState(() {
      _open = e.id;
      _revision++;
      _dirty = false;
    });
    hintSnack(
      context,
      context.l10n.savedNamed(e.displayName),
      icon: Icons.check_circle_outline,
    );
  }

  Future<void> _delete(CustomEndpoint e) async {
    final ok = await confirmDialog(
      context,
      title: context.l10n.deleteEndpointQ,
      message: context.l10n.deleteEndpointBody,
      confirmLabel: context.l10n.delete,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(customEndpointsProvider.notifier).remove(e.id);
      if (mounted) await _repairSelection(e.id);
    } catch (error) {
      if (mounted) hintSnack(context, e.redactSecrets('$error'));
      return;
    }
    if (!mounted) return;
    Haptics.medium();
    if (_open == e.id) {
      setState(() {
        _open =
            ref.read(customEndpointsProvider).value?.firstOrNull?.id ?? _kAdd;
        _dirty = false;
      });
    }
  }

  Future<void> _repairSelection(String id) async {
    final selected = ref.read(assistantModelPrefProvider).value ?? '';
    if (customEndpointIdOf(imageChoiceKeyOf(selected) ?? selected) != id) {
      return;
    }
    final current = ref.read(customEndpointsProvider).value;
    if (current == null) return;
    final next = availableEndpointModel(selected, current);
    if (next != selected) {
      await ref.read(assistantModelPrefProvider.notifier).set(next);
    }
  }

  Future<void> _setEnabled(CustomEndpoint e, bool enabled) async {
    if (!_pending.add(e.id)) return;
    setState(() {});
    try {
      await ref
          .read(customEndpointsProvider.notifier)
          .setEnabled(e.id, enabled);
      if (!enabled && mounted) await _repairSelection(e.id);
    } catch (error) {
      if (mounted) hintSnack(context, e.redactSecrets('$error'));
    } finally {
      if (mounted) setState(() => _pending.remove(e.id));
    }
  }

  Widget _form(CustomEndpoint? source) => _EndpointForm(
    key: ValueKey((source?.id ?? _kAdd, _revision)),
    source: source,
    onDirty: (d) => setState(() => _dirty = d),
    onSaved: _saved,
  );

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(customEndpointsProvider);
    final list = saved.value ?? const <CustomEndpoint>[];
    final source = list.where((e) => e.id == _open).firstOrNull;
    final scratch = source == null;
    Widget library(bool wide) {
      final rows = ReorderableListView.builder(
        shrinkWrap: true,
        buildDefaultDragHandles: false,
        physics: wide ? null : const NeverScrollableScrollPhysics(),
        proxyDecorator: dragProxy,
        onReorderStart: dragStartHaptic,
        onReorderEnd: dragEndHaptic,
        onReorderItem: (from, to) =>
            ref.read(customEndpointsProvider.notifier).reorder(from, to),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final e = list[i];
          return ReorderableDelayedDragStartListener(
            key: ValueKey(e.id),
            index: i,
            child: ListTile(
              dense: true,
              selected: _open == e.id,
              selectedTileColor: context.scheme.secondaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: _ProviderMark(e.customService ? null : e.preset?.label),
              title: Text(
                e.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (e.allModels.isNotEmpty)
                    '${context.l10n.chatModelField} ${e.allModels.length}',
                  if (e.imageModels.isNotEmpty)
                    '${context.l10n.imageModelField} ${e.imageModels.length}',
                ].join(' · '),
              ),
              trailing: e.enabled
                  ? AssistantTag(context.l10n.inUse, active: true)
                  : null,
              onTap: () => _toggle(e.id),
            ),
          );
        },
      );
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.savedEndpoints,
                        style: context.texts.titleMedium,
                      ),
                    ),
                    AssistantTag('${list.length}'),
                  ],
                ),
              ),
              if (wide) Flexible(child: rows) else rows,
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _toggle(_kAdd),
                icon: const Icon(Icons.add),
                label: Text(context.l10n.addEndpoint),
              ),
            ],
          ),
        ),
      );
    }

    final editor = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
            child: Row(
              children: [
                if (scratch)
                  Icon(Icons.add_link, color: context.scheme.primary)
                else
                  _ProviderMark(
                    source.customService ? null : source.preset?.label,
                    size: 28,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    source?.displayName ?? context.l10n.addEndpoint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleLarge,
                  ),
                ),
                if (source != null) ...[
                  Tooltip(
                    message: source.enabled
                        ? context.l10n.disable
                        : context.l10n.enable,
                    child: Switch(
                      value: source.enabled,
                      onChanged: _pending.contains(source.id)
                          ? null
                          : (v) => _setEnabled(source, v),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _delete(source),
                    tooltip: context.l10n.delete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          _form(source),
        ],
      ),
    );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _discard() || !context.mounted) return;
        setState(() => _dirty = false);
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(context.l10n.myEndpoints)),
        body: saved.hasError
            ? Center(
                child: TextButton.icon(
                  onPressed: () => ref.invalidate(customEndpointsProvider),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    context.l10n.desktopCouldNotReadEndpointsClickToReload,
                  ),
                ),
              )
            : !saved.hasValue
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, bounds) {
                  if (bounds.maxWidth < 760) {
                    return ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        library(false),
                        const SizedBox(height: 12),
                        editor,
                      ],
                    );
                  }
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1360),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: bounds.maxWidth < 1000 ? 230 : 280,
                              child: library(true),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: SingleChildScrollView(
                                key: ValueKey(_open),
                                child: editor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _ProviderMark extends StatelessWidget {
  const _ProviderMark(this.label, {this.size = 24});
  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!kEndpointPresets.any((p) => p.label == label)) {
      return Icon(
        Icons.code,
        size: size,
        color: context.scheme.onSurfaceVariant,
      );
    }
    return Image.asset(
      'assets/assistant/providers/${label!.toLowerCase()}.png',
      width: size,
      height: size,
      color: label == 'OpenAI' ? context.scheme.onSurface : null,
      excludeFromSemantics: true,
    );
  }
}

/// 一张卡展开后的表单。[source] 为空 = 新建,保存后直接选上它的第一个模型。
class _EndpointForm extends ConsumerStatefulWidget {
  const _EndpointForm({
    super.key,
    this.source,
    required this.onDirty,
    required this.onSaved,
  });

  final CustomEndpoint? source;

  /// 有没有没保存的改动,变了才报。
  final ValueChanged<bool> onDirty;
  final ValueChanged<CustomEndpoint> onSaved;

  @override
  ConsumerState<_EndpointForm> createState() => _EndpointFormState();
}

class _EndpointFormState extends ConsumerState<_EndpointForm> {
  CustomEndpoint? get _src => widget.source;

  /// 新建那条的 id。测试和保存用同一个。
  late final String _newId = ref.read(customEndpointsProvider.notifier).newId();

  late AgentApiFormat _format = _src?.format ?? AgentApiFormat.openai;

  late final _name = TextEditingController(text: _src?.name ?? '');
  late final _base = TextEditingController(text: _src?.effectiveBase ?? '');
  final _baseFocus = FocusNode();
  late final _key = TextEditingController(text: _src?.apiKey ?? '');
  late EndpointRoute _wire = _src?.route ?? EndpointRoute.chat;
  late final _path = TextEditingController(
    text: (_src?.apiPath ?? '').isEmpty ? _wire.path : _src!.apiPath,
  );
  Map<String, EndpointModelKind>? _catalog;
  String? _catalogConfig;
  bool _saving = false;
  bool _switching = false;
  final _drafts = <String, CustomEndpoint>{};
  late final _headers = TextEditingController(
    text: formatHeaderLines(_src?.headers ?? const {}),
  );

  late List<String> _models = [...?_src?.allModels];

  /// 「添加模型」那格。没点添加就保存的,也算一个。
  final _modelInput = TextEditingController();

  /// 出图模型,和对话模型分开。
  late List<String> _imageModels = [...?_src?.imageModels];
  final _imageInput = TextEditingController();

  /// 点过「自定义」、地址还空着时也亮着它。
  late bool _customPicked = _src?.customService ?? false;

  bool _advanced = false;
  bool _obscureKey = true;

  /// 正在拉列表的那一格:对话模型 false、出图模型 true;没在拉为 null。
  bool? _loadingModels;
  bool _testing = false;

  /// 测试 / 校验的结果,显示在按钮上面。改了任何一格就清掉,免得留着过期的「连接正常」。
  ({bool ok, String text})? _result;

  /// 地址认得出的那一家;没填或认不出为 null。
  EndpointPreset? get _preset => _customPicked || _base.text.trim().isEmpty
      ? null
      : endpointPresetOf(_format, normalizeEndpointBase(_base.text, _format));

  bool get _custom =>
      _preset == null && (_customPicked || _base.text.trim().isNotEmpty);

  List<String> get _allModels => _withPending(_models, _modelInput);

  /// 服务商决定是否提供出图。自定义服务可自行指定出图模型。
  bool get _offersImages => _preset?.offersImages ?? true;
  String get _catalogKey =>
      jsonEncode([_base.text, _path.text, _key.text, _headers.text]);
  bool get _showImages =>
      !_offersImages ||
      _custom ||
      _catalogConfig != _catalogKey ||
      _catalog!.containsValue(EndpointModelKind.image) ||
      _allImageModels.isNotEmpty;

  List<String> get _allImageModels =>
      !_offersImages ? const [] : _withPending(_imageModels, _imageInput);

  static List<String> _withPending(List<String> list, TextEditingController c) {
    final pending = c.text.trim();
    return [
      ...list,
      if (pending.isNotEmpty && !list.contains(pending)) pending,
    ];
  }

  List<TextEditingController> get _fields => [
    _name,
    _base,
    _key,
    _path,
    _headers,
    _modelInput,
    _imageInput,
  ];

  /// 打开时的样子,和它比出有没有改动。
  String _initial = '';
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _snap = _texts();
    _initial = _fingerprint();
    for (final c in _fields) {
      c.addListener(_onEdit);
    }
  }

  String _snap = '';

  String _texts() => [for (final c in _fields) c.text].join('\u0000');

  String _fingerprint() => jsonEncode(_draft().toJson()..remove('enabled'));

  void _changed() {
    final d = _fingerprint() != _initial;
    if (d == _dirty) return;
    _dirty = d;
    widget.onDirty(d);
  }

  /// 文字变了就重建:实际请求地址、各格的后缀按钮、高级设置的摘要跟着刷新。
  /// 只挪光标、换焦点不算。
  void _onEdit() {
    if (_switching) return;
    final now = _texts();
    if (now == _snap) return;
    _snap = now;
    _wire = EndpointRoute.match(_path.text) ?? _wire;
    setState(() => _result = null);
    _changed();
  }

  @override
  void dispose() {
    for (final c in _fields) {
      c
        ..removeListener(_onEdit)
        ..dispose();
    }
    _baseFocus.dispose();
    super.dispose();
  }

  CustomEndpoint _draft() {
    final models = _allModels;
    return CustomEndpoint(
      id: _src?.id ?? _newId,
      enabled: _src?.enabled ?? true,
      customService: _custom,
      wire: _wire,
      name: _name.text.trim(),
      format: _format,
      baseUrl: normalizeEndpointBase(_base.text, _format),
      apiKey: _key.text.trim(),
      model: models.firstOrNull ?? '',
      models: models,
      imageModels: _allImageModels,
      apiPath: _path.text.trim(),
      headers: parseHeaderLines(_headers.text).headers,
    );
  }

  /// 缺了什么就返回那句话,填齐了返回 null。请求头不合格时顺手展开高级设置。
  Uri? get _address {
    try {
      final base = Uri.tryParse(_base.text.trim());
      final path = _path.text.trim();
      if (base == null ||
          !{'https', 'http'}.contains(base.scheme) ||
          base.host.isEmpty ||
          base.hasFragment ||
          path.contains('://') ||
          path.startsWith('//') ||
          path.contains('#')) {
        return null;
      }
      return _draft().chatUri;
    } on FormatException {
      return null;
    }
  }

  String? _missing({bool needModel = true}) {
    final b = _base.text.trim();
    if (b.isEmpty) return context.l10n.pickServiceOrUrl;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(b)) {
      return context.l10n.urlMustHttp;
    }
    if (_address == null) return context.l10n.urlMustHttp;
    final draft = _draft();
    if (!draft.hasCredentials) return context.l10n.noApiKeyYet;
    if (needModel &&
        (_allModels.any((m) => !_acceptModel(m, false)) ||
            _allImageModels.any((m) => !_acceptModel(m, true)) ||
            _allModels.any(_allImageModels.contains))) {
      return context.l10n.endpointModelTypeMismatch;
    }
    // 只填出图模型的也行:这个接口只拿来生成图片
    if (needModel && _allModels.isEmpty && _allImageModels.isEmpty) {
      return context.l10n.noModelYet;
    }
    final bad = parseHeaderLines(_headers.text).bad;
    if (bad != null) {
      _advanced = true;
      return context.l10n.headerLineBad(bad);
    }
    return null;
  }

  void _fail(String text) => setState(() => _result = (ok: false, text: text));

  void _pickPreset(EndpointPreset preset) => _switchService(preset);
  void _pickCustom() {
    _switchService(null);
    _baseFocus.requestFocus();
  }

  void _switchService(EndpointPreset? preset) {
    if (preset == _preset && (preset != null || _custom)) return;
    _drafts[_preset?.label ?? 'custom'] = _draft();
    final restored = _drafts[preset?.label ?? 'custom'];
    Haptics.selection();
    _switching = true;
    setState(() {
      _format = restored?.format ?? preset?.format ?? AgentApiFormat.openai;
      _wire = restored?.route ?? EndpointRoute.defaultFor(_format);
      _customPicked = preset == null;
      _base.text = restored?.baseUrl ?? preset?.base ?? '';
      _path.text = restored?.apiPath ?? _wire.path;
      _key.text = restored?.apiKey ?? '';
      _headers.text = formatHeaderLines(restored?.headers ?? {});
      _name.text = restored?.name ?? '';
      _models = [...?restored?.allModels];
      _imageModels = [...?restored?.imageModels];
      _modelInput.clear();
      _imageInput.clear();
      _obscureKey = true;
      _result = null;
      _snap = _texts();
    });
    _switching = false;
    _changed();
  }

  bool _acceptModel(String id, bool image) {
    final kind =
        (_catalogConfig == _catalogKey ? (_catalog?[id]) : null) ??
        (_src?.imageModels.contains(id) == true
            ? EndpointModelKind.image
            : _src?.allModels.contains(id) == true
            ? EndpointModelKind.chat
            : modelKind(id));
    return kind == EndpointModelKind.unknown ||
        kind == (image ? EndpointModelKind.image : EndpointModelKind.chat);
  }

  /// [image] = 出图模型那一格,否则对话模型。
  List<String> _listOf(bool image) => image ? _imageModels : _models;

  void _setList(bool image, List<String> v) =>
      image ? _imageModels = v : _models = v;

  TextEditingController _inputOf(bool image) =>
      image ? _imageInput : _modelInput;

  void _addModel({bool image = false}) {
    final input = _inputOf(image);
    final m = input.text.trim();
    if (m.isEmpty) return;
    if (!_acceptModel(m, image) || _listOf(!image).contains(m)) {
      return _fail(context.l10n.endpointModelTypeMismatch);
    }
    Haptics.selection();
    setState(() {
      final list = _listOf(image);
      if (!list.contains(m)) _setList(image, [...list, m]);
    });
    input.clear();
    _changed();
  }

  void _removeModel(String m, {bool image = false}) {
    Haptics.selection();
    setState(() {
      _setList(image, [..._listOf(image)]..remove(m));
      _result = null;
    });
    _changed();
  }

  Future<void> _paste(TextEditingController c) async {
    final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (t == null || t.isEmpty) return;
    c.text = t;
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  Future<void> _openKeyPage(String url) async {
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (ok) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      setState(() => _result = (ok: true, text: context.l10n.linkCopied(url)));
    }
  }

  /// 拉模型列表多选。列表里勾掉的移出去,手填的(列表里没有的)留着。
  Future<void> _pickModels({bool image = false}) async {
    if (image && !_offersImages) {
      await _showModelPicker(context, const [], const {});
      return;
    }
    final miss = _missing(needModel: false);
    if (miss != null) return _fail(miss);
    setState(() {
      _loadingModels = image;
      _result = null;
    });
    final draft = _draft();
    final config = _catalogKey;
    List<String> listed;
    try {
      final catalog = _catalogConfig == config && _catalog != null
          ? _catalog!
          : await llmProviderFor(draft).modelCatalog();
      if (!mounted || config != _catalogKey) return;
      _catalog = catalog;
      _catalogConfig = config;
      listed = [
        for (final entry in catalog.entries)
          if (!_listOf(!image).contains(entry.key) &&
              (entry.value ==
                      (image
                          ? EndpointModelKind.image
                          : EndpointModelKind.chat) ||
                  (entry.value == EndpointModelKind.unknown &&
                      (!image || _imageModels.contains(entry.key)))))
            entry.key,
      ];
      if (listed.isEmpty) return _fail(context.l10n.noModelsInGroup);
    } catch (e) {
      if (mounted) _fail(draft.redactSecrets('$e'));
      return;
    } finally {
      if (mounted) setState(() => _loadingModels = null);
    }
    if (!mounted) return;
    final current = _listOf(image);
    final picked = await _showModelPicker(context, listed, current.toSet());
    if (picked == null || !mounted || config != _catalogKey) return;
    setState(() {
      _setList(image, [
        for (final m in current)
          if (picked.contains(m) || !listed.contains(m)) m,
        for (final m in listed)
          if (picked.contains(m) && !current.contains(m)) m,
      ]);
    });
    _changed();
  }

  Future<void> _test() async {
    final miss = _missing();
    if (miss != null) return _fail(miss);
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _result = null;
    });
    final draft = _draft();
    final fingerprint = _fingerprint();
    try {
      // 只填了出图模型的不发对话,拉一次模型列表看通不通
      final Duration took;
      if (draft.allModels.isEmpty) {
        final watch = Stopwatch()..start();
        await llmProviderFor(draft).listModels();
        took = watch.elapsed;
      } else {
        took = await llmProviderFor(draft).ping();
      }
      if (!mounted || fingerprint != _fingerprint()) return;
      Haptics.selection();
      final secs = (took.inMilliseconds / 1000).toStringAsFixed(1);
      setState(
        () => _result = (
          ok: true,
          text: draft.allModels.length > 1
              ? context.l10n.modelConnOk(draft.model, secs)
              : context.l10n.connOk(secs),
        ),
      );
    } catch (e) {
      if (mounted && fingerprint == _fingerprint()) {
        _fail(draft.redactSecrets('$e'));
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final miss = _missing();
    if (miss != null) return _fail(miss);
    FocusScope.of(context).unfocus();
    final draft = _draft();
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(customEndpointsProvider.notifier)
          .put(draft, preserveEnabled: true);
      if (!mounted) return;
      final selected = ref.read(assistantModelPrefProvider).value ?? '';
      final endpoints = ref.read(customEndpointsProvider).requireValue;
      final next = _src == null && selected.isEmpty && endpoints.length == 1
          ? (draft.usable
                ? customModelKey(draft.id, draft.model)
                : '$kImageKeyPrefix${customModelKey(draft.id, draft.imageModels.first)}')
          : availableEndpointModel(selected, endpoints);
      if (next != selected) {
        await ref.read(assistantModelPrefProvider.notifier).set(next);
      }
      if (mounted) widget.onSaved(draft);
    } catch (error) {
      if (mounted) _fail(draft.redactSecrets('$error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final keyEmpty = _key.text.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.endpointConnection,
            style: context.texts.titleMedium,
          ),
          const SizedBox(height: 14),
          Text(context.l10n.endpointService, style: context.texts.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in kEndpointPresets)
                _serviceChip(p.label, _preset == p, () => _pickPreset(p)),
              _serviceChip(context.l10n.sizeCustom, _custom, _pickCustom),
            ],
          ),
          const SizedBox(height: 12),
          _pair(
            _row(
              context.l10n.endpointName,
              _field(_name, hint: _draft().providerLabel, monoText: false),
            ),
            _row(
              context.l10n.endpointPath,
              EditableComboField(
                controller: _path,
                enabled: true,
                fieldKey: const ValueKey('endpoint-request-path'),
                options: {
                  for (final route in EndpointRoute.values)
                    route.label: route.path,
                },
                emptyLabel: context.l10n.noMatchingInCat(
                  context.l10n.endpointPath,
                ),
                onChanged: (_) {},
                decoration: _fieldDecoration(hint: _wire.path),
              ),
            ),
          ),
          _pair(
            _row(
              context.l10n.urlField,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    _base,
                    focus: _baseFocus,
                    hint: switch (_format) {
                      AgentApiFormat.google => 'https://example.com/v1beta',
                      _ => 'https://example.com/v1',
                    },
                    keyboard: TextInputType.url,
                    suffix: _pasteBtn(_base),
                  ),
                  // 自定义地址下面写出实际请求的地址:贴了整条对话地址、少了 /v1 这类错
                  // 一眼看得出
                  if (_address case final uri?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
                      child: Text(
                        '$uri',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: mono(
                          context,
                          size: 11,
                          weight: FontWeight.w500,
                        ).copyWith(color: scheme.outline),
                      ),
                    ),
                ],
              ),
            ),
            _row(
              'Key',
              _field(
                _key,
                obscure: _obscureKey,
                keyboard: TextInputType.visiblePassword,
                suffix: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _pasteBtn(_key),
                    if (keyEmpty && _preset != null)
                      IconButton(
                        onPressed: () => _openKeyPage(_preset!.keyUrl),
                        icon: const Icon(Icons.open_in_new, size: 20),
                        tooltip: context.l10n.getKey,
                        color: scheme.primary,
                      )
                    else
                      IconButton(
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                        icon: Icon(
                          _obscureKey ? Icons.visibility : Icons.visibility_off,
                          size: 20,
                        ),
                        tooltip: _obscureKey
                            ? context.l10n.show
                            : context.l10n.hide,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          _pair(
            _modelsRow(context.l10n.chatModelField),
            _showImages
                ? _modelsRow(context.l10n.imageModelField, image: true)
                : null,
          ),
          _advancedHeader(),
          AnimatedSize(
            duration: Motion.medium,
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: _advanced
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _row(
                        context.l10n.headersField,
                        _field(
                          _headers,
                          hint: context.l10n.headersHint,
                          multiline: true,
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (_result case final r?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    r.ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: r.ok ? scheme.primary : scheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      r.text,
                      style: context.texts.labelMedium!.copyWith(
                        color: r.ok ? scheme.primary : scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                const Spacer(),
                OutlinedButton(
                  onPressed: _testing ? null : _test,
                  child: _testing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(context.l10n.test),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(context.l10n.save),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _serviceChip(String label, bool on, VoidCallback onTap) => ChoiceChip(
    avatar: _ProviderMark(label, size: 18),
    label: Text(label),
    selected: on,
    showCheckmark: false,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    onSelected: (_) => onTap(),
  );

  /// 模型那一格:已添加的一排可删的芯片 + 手填 / 从列表选。[image] = 出图模型。
  Widget _modelsRow(String label, {bool image = false}) {
    final scheme = context.scheme;
    final selected = ref.watch(assistantModelProvider)?.key;
    final pickerOnly = image && !_offersImages;
    final list = pickerOnly ? const <String>[] : _listOf(image);
    final input = _inputOf(image);
    final tone = image ? scheme.tertiary : scheme.primary;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .055),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: .20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                image ? Icons.image_outlined : Icons.chat_bubble_outline,
                color: tone,
                size: 17,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: context.texts.titleSmall)),
            ],
          ),
          const SizedBox(height: 10),
          if (list.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in list)
                    InputChip(
                      avatar:
                          selected ==
                              '${image ? kImageKeyPrefix : ''}${customModelKey(_src?.id ?? _newId, m)}'
                          ? const Icon(Icons.check, size: 15)
                          : null,
                      label: Text(m, style: mono(context, size: 12)),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onDeleted: () => _removeModel(m, image: image),
                      deleteButtonTooltipMessage: context.l10n.remove,
                    ),
                ],
              ),
            ),
          _field(
            pickerOnly ? null : input,
            onPick: pickerOnly ? () => _pickModels(image: true) : null,
            hint: list.isEmpty
                ? context.l10n.modelIdHint
                : context.l10n.addAnotherModel,
            action: TextInputAction.done,
            onSubmitted: pickerOnly ? null : (_) => _addModel(image: image),
            suffix: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!pickerOnly && input.text.trim().isNotEmpty)
                  IconButton(
                    onPressed: () => _addModel(image: image),
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: context.l10n.add,
                    color: scheme.primary,
                  ),
                _loadingModels == image
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        onPressed: _loadingModels == null
                            ? () => _pickModels(image: image)
                            : null,
                        icon: const Icon(Icons.format_list_bulleted, size: 20),
                        tooltip: context.l10n.modelList,
                        color: scheme.onSurfaceVariant,
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pair(Widget first, Widget? second) => LayoutBuilder(
    builder: (context, bounds) {
      if (second == null) return first;
      if (bounds.maxWidth < 540) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 14),
          Expanded(child: second),
        ],
      );
    },
  );

  Widget _row(String label, Widget child) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: context.texts.labelLarge),
        const SizedBox(height: 5),
        child,
      ],
    ),
  );

  /// 「高级设置」那一行,右边列出填过的几项。
  Widget _advancedHeader() {
    final scheme = context.scheme;
    final headers = parseHeaderLines(_headers.text).headers.length;
    final summary = [
      if (headers > 0) context.l10n.headersN(headers),
    ].join(' · ');
    return InkWell(
      onTap: () => setState(() => _advanced = !_advanced),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(Icons.tune, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.advancedSettings,
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (!_advanced && summary.isNotEmpty)
              Text(
                summary,
                style: context.texts.labelMedium!.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(width: 2),
            AnimatedRotation(
              turns: _advanced ? .5 : 0,
              duration: Motion.fast,
              child: Icon(Icons.expand_more, size: 20, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pasteBtn(TextEditingController c) => IconButton(
    onPressed: () => _paste(c),
    icon: const Icon(Icons.content_paste, size: 20),
    tooltip: context.l10n.paste,
    color: context.scheme.onSurfaceVariant,
  );

  Widget _field(
    TextEditingController? c, {
    VoidCallback? onPick,
    FocusNode? focus,
    String? hint,
    bool obscure = false,
    bool multiline = false,
    bool monoText = true,
    TextInputType? keyboard,
    TextInputAction? action,
    ValueChanged<String>? onSubmitted,
    Widget? suffix,
  }) {
    return TextField(
      key: ValueKey(onPick != null),
      controller: c,
      readOnly: onPick != null,
      mouseCursor: onPick == null ? null : SystemMouseCursors.click,
      onTap: onPick,
      focusNode: focus,
      obscureText: obscure,
      keyboardType: multiline ? TextInputType.multiline : keyboard,
      textInputAction: action,
      onSubmitted: onSubmitted,
      minLines: 1,
      maxLines: multiline ? 5 : 1,
      autocorrect: false,
      enableSuggestions: false,
      style: monoText ? mono(context, size: 13) : null,
      decoration: _fieldDecoration(hint: hint, suffix: suffix),
    );
  }

  InputDecoration _fieldDecoration({String? hint, Widget? suffix}) {
    final scheme = context.scheme;
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      hintText: hint,
      hintStyle: context.texts.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      border: outline,
      enabledBorder: outline,
      focusedBorder: outline.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      suffixIcon: suffix,
    );
  }
}

/// 模型列表多选。条数可能上百,给个搜索框。[selected] 是已经加上的,返回勾完的全部;
/// 关掉返回 null。
Future<Set<String>?> _showModelPicker(
  BuildContext context,
  List<String> models,
  Set<String> selected,
) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ModelPicker(models: models, selected: selected),
);

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.selected});

  final List<String> models;
  final Set<String> selected;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _q = '';
  late final Set<String> _on = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final q = _q.trim().toLowerCase();
    final list = [
      for (final m in widget.models)
        if (q.isEmpty || m.toLowerCase().contains(q)) m,
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
                    context.l10n.noImageModelsAvailable,
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
                Flexible(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final m = list[i];
                      final on = _on.contains(m);
                      return CheckboxListTile(
                        dense: true,
                        value: on,
                        controlAffinity: ListTileControlAffinity.trailing,
                        title: Text(
                          m,
                          style: TextStyle(
                            fontWeight: on ? FontWeight.w700 : null,
                            color: on ? scheme.primary : null,
                          ),
                        ),
                        onChanged: (v) => setState(() {
                          if (v ?? false) {
                            _on.add(m);
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
                    onPressed: () => Navigator.pop(context, _on),
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
