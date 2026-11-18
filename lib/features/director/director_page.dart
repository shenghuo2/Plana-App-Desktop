import '../../l10n/l10n.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anlas_provider.dart';
import '../../core/platform/clipboard_image.dart';
import '../../core/store/app_stores.dart';
import '../../core/ui/image_drop.dart';
import '../../core/util/image_pick.dart';
import '../assistant/widgets/desktop_settings_dropdown.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/desktop_image_save.dart';
import '../gallery/models.dart';
import '../gallery/result_clipboard.dart';
import '../gallery/save_settings.dart';
import '../gallery/widgets/result_thumb.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../import/desktop_image_drop.dart';
import 'director_codec.dart';
import 'director_models.dart';
import 'director_service.dart';
import 'director_state.dart';

Future<void> openDirectorTools(
  BuildContext context,
  WidgetRef ref,
  ResultImage image,
) async {
  final controller = ref.read(directorProvider.notifier);
  try {
    await controller.addHistory(image);
    if (!context.mounted) return;
    controller.selectPreview(image);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DirectorPage()));
  } catch (error) {
    if (context.mounted) hintSnack(context, directorError(error));
  }
}

final _directorBytes = FutureProvider.autoDispose.family<Uint8List?, String>(
  (ref, id) => ref.read(appStoresProvider).gallery.readImage(id),
);

class DirectorPage extends ConsumerStatefulWidget {
  const DirectorPage({super.key});
  @override
  ConsumerState<DirectorPage> createState() => _DirectorPageState();
}

class _DirectorPageState extends ConsumerState<DirectorPage> {
  final _inputs = ScrollController(), _history = ScrollController();
  final _tools = ScrollController(), _parameters = ScrollController();
  late final TextEditingController _prompt;
  bool _adding = false, _saving = false, _colorsInvalid = false;
  DirectorController get controller => ref.read(directorProvider.notifier);

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(
      text: ref.read(directorProvider).options.prompt,
    );
  }

  @override
  void dispose() {
    _inputs.dispose();
    _history.dispose();
    _tools.dispose();
    _parameters.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _add(List<PickedImage> images, {String? galleryId}) async {
    if (_adding) return;
    setState(() => _adding = true);
    final recipient = controller;
    try {
      for (final image in images) {
        await recipient.addInput(image.name, image.bytes, galleryId: galleryId);
      }
    } catch (error) {
      recipient.report(error);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _pick() async {
    try {
      await _add(await pickImageFiles(context));
    } catch (error) {
      if (mounted) controller.report(error);
    }
  }

  Future<void> _paste() async {
    try {
      final images = await DesktopClipboard.readImages(preferImage: true);
      if (!mounted) return;
      if (images.isEmpty) throw const FormatException('剪贴板中没有图片');
      await _add([
        for (final image in images)
          PickedImage(image.name ?? '剪贴板图片.png', image.bytes),
      ]);
    } catch (error) {
      if (mounted) controller.report(error);
    }
  }

  Future<void> _save(ResultImage image) async {
    if (_saving) return;
    setState(() => _saving = true);
    final store = ref.read(appStoresProvider).gallery;
    final settings = ref.read(saveSettingsProvider.future);
    try {
      final directory =
          ref.read(desktopSaveDirectoryProvider) ??
          await FilePicker.platform.getDirectoryPath(dialogTitle: '保存导演工具结果');
      if (directory == null || !mounted) return;
      final bytes = image.bytes ?? await store.readImage(image.id);
      if (bytes == null) throw const FormatException('图片已不可读取');
      final file = await saveDesktopImage(
        directory: directory,
        image: image,
        bytes: bytes,
        settings: await settings,
      );
      if (mounted) hintSnack(context, '已保存：${file.path}');
    } catch (error) {
      if (mounted) hintSnack(context, l10nNow.desktopCouldNotSaveCheckFolderPermissionsAndAvailable);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(directorProvider);
    final access = ref.watch(directorAccessProvider);
    final history = ref.watch(galleryViewProvider).results;
    final album = ref.watch(galleryBrowseAlbumProvider);
    final albumName = ref.watch(albumsProvider).name(album);
    final scheme = Theme.of(context).colorScheme;
    final balance = ref.watch(anlasProvider).value;
    return Scaffold(
      key: const ValueKey('director-page'),
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10nNow.desktopBackToCreate,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10nNow.desktopDirectorTools),
        actions: [
          if (state.busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              state.options.tool.local
                  ? '本机处理 · 免费'
                  : balance != null
                  ? '余额 ${balance.anlas} Anlas'
                  : '余额暂不可用',
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 960;
          final source = state.source;
          final preview = state.preview;
          final previewBytes =
              preview?.bytes ??
              (preview == null
                  ? null
                  : ref.watch(_directorBytes(preview.id)).value);
          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                color: scheme.surfaceContainerLow,
                child: Text(
                  state.options.tool.local
                      ? '本机像素网格整理'
                      : access.reason ?? '${access.label} · 使用当前主账户',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: narrow ? 84 : 112,
                        child: _drop(child: _inputSidebar(state, narrow)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _drop(
                          acceptPaste: true,
                          child: DirectorPreview(
                            key: const ValueKey('director-source'),
                            identity: source?.id,
                            title: l10nNow.desktopInputImages,
                            bytes: source?.bytes,
                            width: source?.width,
                            height: source?.height,
                            subtitle: source?.name ?? '选择文件、粘贴，或将右侧历史拖到这里',
                            empty: '添加要修改的图片',
                            footer: source == null
                                ? null
                                : _sourceFooter(source, state.options),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DirectorPreview(
                          key: const ValueKey('director-result'),
                          identity: preview?.id,
                          title: l10nNow.desktopResultAndHistoryPreview,
                          bytes: previewBytes,
                          width: preview?.width,
                          height: preview?.height,
                          subtitle: preview?.operation == null
                              ? '点击右侧历史可预览'
                              : '${directorVariantLabel(preview!.operation!.variant)} · 来源：${preview.operation!.sourceName}',
                          empty: preview == null ? '转换结果会显示在这里' : '正在读取图片…',
                          footer: preview == null
                              ? null
                              : _resultFooter(preview, state),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: narrow ? 88 : 128,
                        child: _historySidebar(history, state, albumName),
                      ),
                    ],
                  ),
                ),
              ),
              Material(
                color: scheme.surfaceContainerLow,
                shape: Border(top: BorderSide(color: scheme.outlineVariant)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_hasParameters(state.options.tool))
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight < 600 ? 108 : 176,
                        ),
                        child: Scrollbar(
                          controller: _parameters,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _parameters,
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                            child: _parameterControls(state.options),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Scrollbar(
                              controller: _tools,
                              child: SingleChildScrollView(
                                controller: _tools,
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    for (final tool in DirectorTool.values)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 4,
                                        ),
                                        child: Tooltip(
                                          message: tool.help,
                                          child: TextButton(
                                            key: ValueKey(
                                              'director-tool-${tool.code}',
                                            ),
                                            style: TextButton.styleFrom(
                                              minimumSize: const Size(76, 44),
                                              backgroundColor:
                                                  tool == state.options.tool
                                                  ? scheme.primaryContainer
                                                  : null,
                                              foregroundColor:
                                                  tool == state.options.tool
                                                  ? scheme.onPrimaryContainer
                                                  : scheme.onSurface,
                                            ),
                                            onPressed: () => controller.options(
                                              state.options.copyWith(
                                                tool: tool,
                                              ),
                                            ),
                                            child: Text(tool.label),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Tooltip(
                            message: _priceHint(state, access),
                            child: FilledButton.icon(
                              key: const ValueKey('director-transform'),
                              onPressed:
                                  state.busy ||
                                      source == null ||
                                      state.hasPendingSave ||
                                      (state.options.tool.local &&
                                          state.options.palette ==
                                              DirectorPalette.custom &&
                                          _colorsInvalid) ||
                                      (!state.options.tool.local &&
                                          !access.available)
                                  ? null
                                  : controller.transform,
                              icon: Icon(
                                state.options.tool.local
                                    ? Icons.grid_on
                                    : Icons.auto_fix_high,
                              ),
                              label: Text(
                                state.busy
                                    ? '处理中…'
                                    : state.options.tool.local
                                    ? '像素对齐'
                                    : '转换',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              state.message.isEmpty
                                  ? _priceHint(state, access)
                                  : state.message,
                              key: const ValueKey('director-status'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: state.failed
                                    ? scheme.error
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (state.hasPendingSave && !state.busy)
                            TextButton(
                              onPressed: controller.retrySave,
                              child: Text(l10nNow.desktopRetrySave),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _drop({required Widget child, bool acceptPaste = false}) =>
      ImageDropRegion(
        label: l10nNow.desktopAddToInputImages,
        multiple: true,
        enabled: !_adding,
        acceptPaste: acceptPaste,
        onDrop: (images, payload) => _add(images, galleryId: payload.imageId),
        child: child,
      );

  Widget _inputSidebar(DirectorState state, bool narrow) => Column(
    children: [
      Text(
        '待处理 · ${state.inputs.length}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: l10nNow.addImages,
            visualDensity: VisualDensity.compact,
            onPressed: _adding ? null : _pick,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
          IconButton(
            tooltip: l10nNow.desktopPasteImage,
            visualDensity: VisualDensity.compact,
            onPressed: _adding ? null : _paste,
            icon: const Icon(Icons.content_paste),
          ),
        ],
      ),
      Expanded(
        child: Scrollbar(
          controller: _inputs,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _inputs,
            itemCount: state.inputs.length,
            itemBuilder: (context, index) {
              final image = state.inputs[index];
              return Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 8, 8),
                child: Stack(
                  children: [
                    _thumbFrame(
                      selected: image.id == state.selectedId,
                      onTap: () => controller.selectInput(image.id),
                      child: Tooltip(
                        message: image.name,
                        child: Image.memory(
                          image.bytes,
                          width: double.infinity,
                          height: narrow ? 78 : 104,
                          fit: BoxFit.contain,
                          cacheWidth: (image.width < 320 ? image.width : 320),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton.filledTonal(
                        tooltip: l10nNow.desktopRemoveInputImage,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 26,
                          height: 26,
                        ),
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.close),
                        onPressed: () => controller.removeInput(image.id),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ],
  );

  Widget _historySidebar(
    List<ResultImage> history,
    DirectorState state,
    String album,
  ) => Column(
    children: [
      Text(l10nNow.history),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Tooltip(
          message: album,
          child: Text(
            '$album · ${history.length}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
      Expanded(
        child: Scrollbar(
          controller: _history,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _history,
            itemCount: history.length,
            itemBuilder: (context, index) {
              final image = history[index];
              return Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 10, 8),
                child: GalleryImageDrag(
                  result: image,
                  child: _thumbFrame(
                    selected: state.preview?.id == image.id,
                    onTap: () => controller.selectPreview(image),
                    child: Column(
                      children: [
                        ResultThumb(
                          result: image,
                          width: 112,
                          height: 94,
                          radius: 6,
                          fit: BoxFit.contain,
                        ),
                        if (image.operation != null)
                          Text(
                            DirectorTool.values
                                    .where(
                                      (e) => e.code == image.operation!.tool,
                                    )
                                    .firstOrNull
                                    ?.label ??
                                '导演结果',
                            maxLines: 1,
                            style: const TextStyle(fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ],
  );

  Widget _thumbFrame({
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          width: 2,
          color: selected ? colors.primary : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(3), child: child),
      ),
    );
  }

  Widget _sourceFooter(DirectorInput source, DirectorOptions options) {
    final send = directorSendSize(source.width, source.height);
    return Text(
      options.tool.local ? '整理已有像素画' : '发送副本 ${send.width} × ${send.height}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12),
    );
  }

  Widget _resultFooter(ResultImage preview, DirectorState state) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (state.latest.length > 1)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < state.latest.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(
                      state.latest[i].operation?.variant == null
                          ? '结果 ${i + 1}'
                          : directorVariantLabel(
                              state.latest[i].operation!.variant,
                            ),
                    ),
                    selected: preview.id == state.latest[i].id,
                    onSelected: (_) =>
                        controller.selectPreview(state.latest[i]),
                  ),
                ),
            ],
          ),
        ),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        children: [
          TextButton.icon(
            onPressed: _adding
                ? null
                : () async {
                    try {
                      await controller.addHistory(preview);
                    } catch (error) {
                      if (mounted) controller.report(error);
                    }
                  },
            icon: const Icon(Icons.west, size: 18),
            label: Text(l10nNow.desktopAddAsInput),
          ),
          TextButton.icon(
            onPressed: () => copyResultToClipboard(context, ref, preview),
            icon: const Icon(Icons.content_copy, size: 18),
            label: Text(l10nNow.copy),
          ),
          Tooltip(
            message: l10nNow.desktopUsesYourGallerySaveSettingsJPGFillsTransparent,
            child: TextButton.icon(
              onPressed: _saving ? null : () => _save(preview),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(l10nNow.save),
            ),
          ),
        ],
      ),
    ],
  );

  String _priceHint(DirectorState state, DirectorAccess access) {
    if (state.options.tool.local) return '本机处理，不消耗 Anlas；用于已有像素画的网格整理。';
    if (!access.available) return access.reason ?? '没有可用接口';
    if (access.key!.isThirdParty) return '费用由当前第三方服务决定；请确认该服务支持导演工具。';
    final source = state.source;
    if (source == null) return '选择图片后显示费用估算。';
    final cost = directorAnlasEstimate(
      state.options.tool,
      source.width,
      source.height,
    );
    return '预计最多 $cost Anlas／次；订阅优惠以服务实际扣费为准。';
  }

  bool _hasParameters(DirectorTool tool) =>
      tool == DirectorTool.emotion ||
      tool == DirectorTool.colorize ||
      tool.local;

  Widget _dropdown<T>(
    String id,
    String label,
    T value,
    List<T> values,
    String Function(T) labelOf,
    ValueChanged<T> onChanged, {
    double width = 160,
  }) => SizedBox(
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(height: 4),
        DesktopSettingsDropdown<T>(
          id: id,
          label: label,
          value: value,
          options: values,
          labelOf: labelOf,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Widget _parameterControls(DirectorOptions options) {
    if (options.tool.local) {
      return Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          _dropdown(
            'director-palette',
            '调色板',
            options.palette,
            DirectorPalette.values,
            (v) => switch (v) {
              DirectorPalette.off => '关闭',
              DirectorPalette.auto => '自动',
              DirectorPalette.custom => '自定义',
            },
            (v) {
              setState(() => _colorsInvalid = false);
              controller.options(options.copyWith(palette: v));
            },
          ),
          if (options.palette == DirectorPalette.custom)
            SizedBox(
              width: 110,
              child: TextFormField(
                initialValue: '${options.colors}',
                keyboardType: TextInputType.number,
                autovalidateMode: AutovalidateMode.always,
                validator: (text) {
                  final n = int.tryParse(text ?? '');
                  return n == null || n < 2 || n > 256 ? '请输入 2–256' : null;
                },
                decoration: InputDecoration(
                  labelText: l10nNow.desktopPaletteSize2256,
                  border: OutlineInputBorder(),
                ),
                onChanged: (s) {
                  final value = int.tryParse(s);
                  setState(
                    () => _colorsInvalid =
                        value == null || value < 2 || value > 256,
                  );
                  if (value != null && value >= 2 && value <= 256) {
                    controller.options(options.copyWith(colors: value));
                  }
                },
              ),
            ),
          SizedBox(
            width: 200,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10nNow.desktopAvoidOverRefining),
              value: options.avoidOverRefining,
              onChanged: (v) =>
                  controller.options(options.copyWith(avoidOverRefining: v)),
            ),
          ),
          SizedBox(
            width: 160,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10nNow.desktopUpscaleOutput),
              value: options.upscale,
              onChanged: (v) =>
                  controller.options(options.copyWith(upscale: v)),
            ),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        if (options.tool == DirectorTool.emotion)
          _dropdown(
            'director-emotion',
            '表情',
            options.emotion,
            directorEmotions.keys.toList(),
            (v) => directorEmotions[v]!,
            (v) => controller.options(options.copyWith(emotion: v)),
          ),
        _dropdown(
          'director-defry',
          options.tool == DirectorTool.emotion ? '变化程度' : '降噪与色彩修正',
          options.defry,
          [0, 1, 2, 3, 4, 5],
          (v) => options.tool == DirectorTool.emotion
              ? directorEmotionLevels[v]
              : '$v',
          (v) => controller.options(options.copyWith(defry: v)),
        ),
        SizedBox(
          width: 330,
          child: TextField(
            controller: _prompt,
            maxLength: 10000,
            minLines: 1,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10nNow.desktopPromptOptional,
              border: OutlineInputBorder(),
              counterText: '',
            ),
            onChanged: (v) => controller.options(
              ref.read(directorProvider).options.copyWith(prompt: v),
            ),
          ),
        ),
      ],
    );
  }
}

/// Independent view transforms: selecting a history image resets only its pane.
class DirectorPreview extends StatefulWidget {
  const DirectorPreview({
    super.key,
    required this.identity,
    required this.title,
    required this.bytes,
    required this.width,
    required this.height,
    required this.subtitle,
    required this.empty,
    this.footer,
  });
  final String? identity;
  final String title, subtitle, empty;
  final Uint8List? bytes;
  final int? width, height;
  final Widget? footer;
  @override
  State<DirectorPreview> createState() => _DirectorPreviewState();
}

class _DirectorPreviewState extends State<DirectorPreview> {
  final _transform = TransformationController();
  @override
  void didUpdateWidget(DirectorPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _transform.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: l10nNow.desktopFitToWindow,
                  icon: const Icon(Icons.fit_screen_outlined, size: 20),
                  onPressed: () => _transform.value = Matrix4.identity(),
                ),
              ],
            ),
          ),
          Expanded(
            child: widget.bytes == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(widget.empty, textAlign: TextAlign.center),
                    ),
                  )
                : ClipRect(
                    child: CustomPaint(
                      painter: _Checkerboard(colors),
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: .5,
                        maxScale: 12,
                        child: Center(
                          child: Image.memory(
                            widget.bytes!,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Text(
              widget.width == null
                  ? widget.subtitle
                  : '${widget.width} × ${widget.height} · ${widget.subtitle}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (widget.footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: widget.footer!,
            ),
        ],
      ),
    );
  }
}

class _Checkerboard extends CustomPainter {
  const _Checkerboard(this.colors);
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = colors.surfaceContainerLow,
    );
    final paint = Paint()..color = colors.surfaceContainerHighest;
    for (var y = 0.0; y < size.height; y += 12) {
      for (var x = 0.0; x < size.width; x += 12) {
        if (((x / 12).floor() + (y / 12).floor()).isEven) {
          canvas.drawRect(Rect.fromLTWH(x, y, 12, 12), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard oldDelegate) => colors != oldDelegate.colors;
}
