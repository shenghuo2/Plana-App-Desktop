import '../../l10n/l10n.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/store/app_stores.dart';
import '../../core/ui/image_drop.dart';
import '../../core/util/image_pick.dart';
import '../gallery/gallery_state.dart';
import '../gallery/widgets/history_image_picker.dart';
import '../generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import '../import/image_metadata.dart';
import '../import/metadata_detail_page.dart';
import 'metadata_draft.dart';
import 'metadata_export.dart';
import 'metadata_processing.dart';
import 'metadata_tool_link.dart';
import 'metadata_sampler_field.dart';

class DesktopMetadataProcessor extends ConsumerStatefulWidget {
  const DesktopMetadataProcessor({super.key});

  @override
  ConsumerState<DesktopMetadataProcessor> createState() =>
      _DesktopMetadataProcessorState();
}

class _DesktopMetadataProcessorState
    extends ConsumerState<DesktopMetadataProcessor> {
  final _input = TextEditingController();
  late final TextEditingController _output;
  final _previewScroll = ScrollController();
  final _previewFocus = FocusNode(debugLabel: 'Metadata batch previews');
  static const _previewStride = 148.0;
  late final Map<String, TextEditingController> _fields;
  ImageMetadata? _meta;
  Uint8List? _bytes;
  String? _imagePath;
  String _imageName = '';
  int _tab = 0;
  bool _pickedNewImage = false;
  bool _strip = true, _subfolder = true;
  bool _loading = false, _choosing = false, _processing = false;
  final _files = <File>[];
  final _selected = <String>{};
  final _historyFiles = <String>{};
  final _memoryImages = <String, Uint8List>{};
  final _errors = <String, String>{};
  MetadataBatchJob? _job;
  (int, int)? _progress;
  String? _status, _lastDirectory;
  MetadataBatchResult? _result;
  bool get _busy => _loading || _choosing || _processing;

  MetadataDraftNotifier get _drafts => ref.read(metadataDraftProvider.notifier);

  @override
  void initState() {
    super.initState();
    final draft = ref.read(metadataDraftProvider);
    _fields = {
      for (final entry in MetadataDraft.defaults.entries)
        if (entry.value is! bool)
          entry.key: TextEditingController(
            text: draft.fields[entry.key]?.toString() ?? '',
          ),
    };
    _output = TextEditingController(text: draft.outputDirectory);
    if (draft.imagePath case final path?) _restorePreview(path);
  }

  Future<void> _restorePreview(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted || _pickedNewImage) return;
      final meta = await extractImageMetadata(bytes);
      if (!mounted || _pickedNewImage) return;
      // Reading the preview must preserve edits made after the file was opened.
      setState(() {
        _bytes = bytes;
        _meta = meta;
        _imagePath = path;
        _imageName = p.basename(path);
      });
    } on FileSystemException {
      // The file may have moved. Its editable parameters are still in the draft.
    }
  }

  @override
  void dispose() {
    _job?.cancel();
    _input.dispose();
    _output.dispose();
    _previewScroll.dispose();
    _previewFocus.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  String? get _destination {
    final root = _output.text.trim().isNotEmpty
        ? _output.text.trim()
        : (_tab == 1 ? _input.text.trim() : '');
    if (root.isEmpty) return null;
    return p.normalize(
      p.absolute(
        _tab == 1 && _subfolder
            ? p.join(root, _strip ? 'metadata_stripped' : 'metadata_edited')
            : root,
      ),
    );
  }

  Future<void> _pickImage() async {
    setState(() => _loading = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: '选择要处理的图片',
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
        compressionQuality: 0,
      );
      if (!mounted || picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      await _readImage(bytes, file.name, file.path);
    } catch (error) {
      if (mounted) hintSnack(context, '读取图片失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickHistory({required bool multiple}) async {
    if (_busy) return;
    setState(() => _choosing = true);
    try {
      final picked = await showHistoryImagePicker(context, multiple: multiple);
      if (!mounted || picked == null || picked.isEmpty) return;
      final gallery = ref.read(appStoresProvider).gallery;
      if (!multiple) {
        final item = picked.single;
        final bytes =
            item.bytes ?? await ref.read(galleryImageProvider(item.id).future);
        if (!mounted) return;
        if (bytes == null) {
          hintSnack(context, l10nNow.desktopCouldNotLoadTheImageItsFileMay);
          return;
        }
        final file = gallery.imageFileForPreview(item.id);
        final exists = await file.exists();
        if (!mounted) return;
        await _readImage(
          bytes,
          '${item.id}.png',
          exists ? file.path : null,
          restorePath: file.path,
        );
      } else {
        setState(() {
          for (final item in picked) {
            final file = gallery.imageFileForPreview(item.id);
            _addBatchImage(file, keepOnRefresh: true, bytes: item.bytes);
          }
        });
        _focusPreviews();
      }
    } catch (error) {
      if (mounted) hintSnack(context, '读取历史图片失败：$error');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _dropImages(
    List<PickedImage> images,
    ImageDropPayload payload,
  ) async {
    if (_busy) return;
    setState(() => _loading = true);
    try {
      final gallery = ref.read(appStoresProvider).gallery;
      String? pathAt(int index) => payload.paths.isNotEmpty
          ? payload.paths[index]
          : payload.imageId == null
          ? null
          : gallery.imageFileForPreview(payload.imageId!).path;
      if (_tab == 0) {
        await _readImage(images.single.bytes, images.single.name, pathAt(0));
      } else {
        setState(() {
          for (var i = 0; i < images.length; i++) {
            final path = pathAt(i);
            if (path == null) continue;
            _addBatchImage(
              File(path),
              keepOnRefresh: true,
              bytes: images[i].bytes,
            );
          }
        });
        _focusPreviews();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addBatchImage(
    File file, {
    bool keepOnRefresh = false,
    Uint8List? bytes,
  }) {
    final existing = _files
        .where((f) => p.equals(f.path, file.path))
        .firstOrNull;
    if (existing == null) _files.add(file);
    final path = (existing ?? file).path;
    _selected.add(path);
    if (keepOnRefresh) _historyFiles.add(path);
    if (bytes != null) _memoryImages[path] = bytes;
  }

  void _removeBatchImage(File file) {
    setState(() {
      _files.remove(file);
      _selected.remove(file.path);
      _historyFiles.remove(file.path);
      _memoryImages.remove(file.path);
    });
  }

  void _keepHistoryImages() {
    _files.removeWhere((file) => !_historyFiles.contains(file.path));
    _selected.retainWhere(_historyFiles.contains);
  }

  Future<void> _readImage(
    Uint8List bytes,
    String name,
    String? path, {
    String? restorePath,
  }) async {
    _pickedNewImage = true;
    final meta = await extractImageMetadata(bytes);
    if (!mounted) return;
    _drafts.readImage(meta, restorePath ?? path);
    final fields = ref.read(metadataDraftProvider).fields;
    setState(() {
      _bytes = bytes;
      _imagePath = path;
      _imageName = name;
      _meta = meta;
      for (final entry in _fields.entries) {
        entry.value.text = fields[entry.key].toString();
      }
      _errors.clear();
    });
  }

  Future<void> _reread() async {
    setState(() => _loading = true);
    try {
      final restorePath = ref.read(metadataDraftProvider).imagePath;
      final bytes = _imagePath == null
          ? _bytes!
          : await File(_imagePath!).readAsBytes();
      await _readImage(bytes, _imageName, _imagePath, restorePath: restorePath);
      if (mounted) hintSnack(context, l10nNow.desktopImageSettingsReloaded);
    } catch (error) {
      if (mounted) hintSnack(context, '读取失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _browse({required bool input}) async {
    setState(() => _choosing = true);
    String? chosen;
    try {
      chosen = await FilePicker.platform.getDirectoryPath(
        dialogTitle: input ? '选择输入文件夹' : '选择输出文件夹',
      );
      if (!mounted || chosen == null) return;
      setState(() => (input ? _input : _output).text = chosen!);
      if (!input) _drafts.setOutputDirectory(chosen);
    } catch (error) {
      if (mounted) hintSnack(context, '无法选择文件夹：$error');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
    if (mounted && input && chosen != null) await _scan();
  }

  Future<void> _scan() async {
    if (_busy || _input.text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _keepHistoryImages();
    });
    try {
      final files = await listMetadataImages(Directory(_input.text.trim()));
      if (!mounted) return;
      setState(() {
        for (final file in files) {
          _addBatchImage(file);
        }
      });
      _focusPreviews();
    } catch (error) {
      if (mounted) hintSnack(context, '无法读取输入文件夹：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? _snapshot(MetadataDraft draft) {
    _errors.clear();
    try {
      return draft.buildComment();
    } on MetadataFieldErrors catch (error) {
      _errors.addAll(error.fields);
      setState(() => _tab = 0);
      hintSnack(context, l10nNow.desktopCheckTheHighlightedGenerationSettings);
      return null;
    }
  }

  Future<void> _saveSingle({required bool strip}) async {
    if (_bytes == null || _busy) return;
    final draft = ref.read(metadataDraftProvider);
    final comment = strip ? null : _snapshot(draft);
    if (!strip && comment == null) return;
    if (_destination == null) await _browse(input: false);
    if (!mounted || _destination == null) return;
    final destination = _destination!;
    setState(() {
      _processing = true;
      _result = null;
      _status = strip ? '正在清除元数据…' : '正在写入元数据…';
    });
    try {
      final directory = await Directory(destination).create(recursive: true);
      final file = await exportMetadataCopy(
        directory: directory,
        sourceName: _imageName,
        bytes: _bytes!,
        comment: comment,
        source: draft.source,
      );
      if (!mounted) return;
      setState(() {
        _lastDirectory = destination;
        _result = MetadataBatchResult([file.path], const [], false);
        _status = '已导出 1 张';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _startBatch() async {
    if (_busy || _selected.isEmpty) return;
    final draft = ref.read(metadataDraftProvider);
    final comment = _strip ? null : _snapshot(draft);
    if (!_strip && comment == null) return;
    if (_destination == null) await _browse(input: false);
    if (!mounted || _destination == null) return;
    final destination = _destination!;
    final job = MetadataBatchJob(
      files: _files.where((f) => _selected.contains(f.path)).toList(),
      directory: Directory(destination),
      comment: comment,
      memoryImages: _memoryImages,
      source: draft.source,
    );
    setState(() {
      _job = job;
      _processing = true;
      _result = null;
      _progress = (0, job.files.length);
      _status = '准备处理…';
    });
    try {
      final result = await job.run(
        onProgress: (done, total, name) {
          if (!mounted) return;
          setState(() {
            _progress = (done, total);
            _status = '$done / $total · $name';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _lastDirectory = destination;
        _status =
            '${result.cancelled ? '已取消 · ' : ''}已导出 ${result.outputs.length} 张'
            '${result.errors.isEmpty ? '' : '，${result.errors.length} 张失败'}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '处理失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _job = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _openOutput() async {
    try {
      if (!await launchUrl(
        Uri.directory(_lastDirectory!, windows: Platform.isWindows),
      )) {
        throw const FileSystemException('请复制输出路径，在资源管理器中打开');
      }
    } catch (error) {
      if (mounted) hintSnack(context, '无法打开文件夹：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(singleMetadataRequestProvider, (_, _) {
      if (_tab != 0) setState(() => _tab = 0);
    });
    return ImageDropRegion(
      label: _tab == 0 ? '读取图片元数据' : '加入批量处理',
      enabled: !_busy,
      multiple: _tab == 1,
      onDrop: _dropImages,
      child: Column(
        key: const ValueKey('desktop-metadata-tool'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final description = Text(
                l10nNow.desktopReadAndEditGenerationSettingsThenExportThe,
                style: context.texts.bodySmall!.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              );
              final modes = SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.image_outlined, size: 18),
                    label: Text(l10nNow.desktopSingleImage),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.photo_library_outlined, size: 18),
                    label: Text(l10nNow.desktopBatchProcessing),
                  ),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() => _tab = s.first),
              );
              final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
              if (constraints.maxWidth >= 760 * scale) {
                return Row(
                  children: [
                    Expanded(child: description),
                    const SizedBox(width: 16),
                    modes,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [description, const SizedBox(height: 12), modes],
              );
            },
          ),
          const SizedBox(height: 16),
          if (_loading) const LinearProgressIndicator(),
          if (_tab == 0) _single() else _batch(),
          if (_status != null) ...[const SizedBox(height: 14), _results()],
        ],
      ),
    );
  }

  Widget _card(String title, Widget child, {Key? key, Widget? action}) =>
      Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: 14),
        child: Material(
          color: context.scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(title, style: context.texts.titleSmall),
                    ),
                    ?action,
                  ],
                ),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
        ),
      );

  Widget _single() {
    final parameters = _editor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          '当前图片',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                _imagePath ??
                    (_imageName.isEmpty
                        ? '尚未选择图片 · PNG / JPEG / WebP'
                        : _imageName),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('metadata-select-image'),
                    onPressed: _busy ? null : _pickImage,
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 18,
                    ),
                    label: Text(l10nNow.selectImage),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('metadata-history-single'),
                    onPressed: _busy
                        ? null
                        : () => _pickHistory(multiple: false),
                    icon: const Icon(Icons.history, size: 18),
                    label: Text(l10nNow.desktopChooseFromHistory),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _bytes == null ? null : _reread,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10nNow.desktopReloadMetadata),
                  ),
                  if (_meta != null)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(
                              sharedAxisRoute(
                                MetadataDetailPage(
                                  meta: _meta!,
                                  bytes: _bytes!,
                                  fileName: _imageName,
                                  standalone: true,
                                ),
                              ),
                            ),
                      child: Text(l10nNow.desktopViewDetailsAndImport),
                    ),
                ],
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final preview = _card(
              '图片预览',
              Column(
                children: [
                  SizedBox(
                    height: 350,
                    width: double.infinity,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: ColoredBox(
                        color: context.scheme.surfaceContainer,
                        child: _bytes == null
                            ? const Center(
                                child: Icon(Icons.image_outlined, size: 52),
                              )
                            : Image.memory(
                                _bytes!,
                                fit: BoxFit.contain,
                                cacheWidth: 700,
                                errorBuilder: (_, _, _) => Center(
                                  child: Text(
                                    l10nNow.desktopCouldNotDecodeImage,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _bytes == null
                        ? '选择图片后显示预览'
                        : _meta == null
                        ? '未检测到生成参数，可以直接填写新参数'
                        : '已读取 ${_meta!.source} 的生成参数',
                    style: context.texts.bodySmall,
                  ),
                ],
              ),
            );
            final editor = _card('生成参数', parameters);
            if (constraints.maxWidth < 700) {
              return Column(children: [preview, editor]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: constraints.maxWidth * .34, child: preview),
                const SizedBox(width: 16),
                Expanded(child: editor),
              ],
            );
          },
        ),
        _card(
          '导出图片',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _directoryField(input: false),
              const SizedBox(height: 10),
              Text(l10nNow.desktopExportAPNGCopyAndKeepTheOriginal),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('metadata-strip-single'),
                    onPressed: _busy || _bytes == null
                        ? null
                        : () => _saveSingle(strip: true),
                    icon: const Icon(
                      Icons.cleaning_services_outlined,
                      size: 18,
                    ),
                    label: Text(l10nNow.desktopRemoveMetadataAndExport),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('metadata-write-single'),
                    onPressed: _busy || _bytes == null
                        ? null
                        : () => _saveSingle(strip: false),
                    icon: const Icon(Icons.save_alt, size: 18),
                    label: Text(l10nNow.desktopWriteMetadataAndExport),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(String name, String label, {int lines = 1}) {
    final decoration = InputDecoration(
      labelText: label,
      errorText: _errors[name],
      border: const OutlineInputBorder(),
      isDense: true,
    );
    void onChanged(String value) {
      _drafts.editFields({name: value});
      if (_errors.containsKey(name)) setState(() => _errors.remove(name));
    }

    if (name == 'sampler') {
      return MetadataSamplerField(
        controller: _fields[name]!,
        enabled: !_busy,
        decoration: decoration,
        onChanged: onChanged,
      );
    }
    return TextField(
      key: ValueKey('metadata-field-$name'),
      controller: _fields[name],
      enabled: !_busy,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 3,
      decoration: decoration,
      onChanged: onChanged,
    );
  }

  Widget _editor() {
    final (sm, smDyn, advanced) = ref.watch(
      metadataDraftProvider.select(
        (d) => (d.fields['sm'] == true, d.fields['sm_dyn'] == true, d.advanced),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field('prompt', '正向提示词', lines: 4),
        const SizedBox(height: 16),
        _field('uc', '负向提示词', lines: 3),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 16,
              children: [
                for (final entry in {
                  'steps': '步数',
                  'scale': '引导强度',
                  'seed': '种子',
                  'sampler': context.l10n.desktopSampler,
                }.entries)
                  SizedBox(width: width, child: _field(entry.key, entry.value)),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('SMEA'),
              selected: sm,
              onSelected: _busy
                  ? null
                  : (v) =>
                        _drafts.editFields({'sm': v, if (!v) 'sm_dyn': false}),
            ),
            FilterChip(
              label: const Text('SMEA Dynamic'),
              selected: sm && smDyn,
              onSelected: _busy || !sm
                  ? null
                  : (v) => _drafts.editFields({'sm_dyn': v}),
            ),
          ],
        ),
        ExpansionTile(
          key: const PageStorageKey('metadata-advanced-parameters'),
          initiallyExpanded: advanced,
          onExpansionChanged: _drafts.setAdvanced,
          tilePadding: EdgeInsets.zero,
          title: Text(l10nNow.desktopMoreSettings),
          childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
          children: [
            for (final entry in const {
              'noise_schedule': '噪声调度',
              'cfg_rescale': 'CFG Rescale',
              'strength': '重绘强度',
              'noise': '噪声强度',
            }.entries)
              Padding(
                // EditableText restores its own horizontal scroll offset. It must
                // not read the bool stored under the parent ExpansionTile key.
                key: PageStorageKey('metadata-parameter-${entry.key}'),
                padding: const EdgeInsets.only(bottom: 14),
                child: _field(entry.key, entry.value),
              ),
          ],
        ),
      ],
    );
  }

  Widget _directoryField({required bool input}) => Row(
    children: [
      Expanded(
        child: TextField(
          key: ValueKey(
            input ? 'metadata-input-directory' : 'metadata-output-directory',
          ),
          controller: input ? _input : _output,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: input ? '输入文件夹' : '输出文件夹',
            hintText: input
                ? '选择或粘贴文件夹路径'
                : (_tab == 1 && _input.text.trim().isNotEmpty
                      ? '留空则使用输入文件夹'
                      : '选择保存位置'),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: input ? (_) => _scan() : null,
          onChanged: (value) => setState(() {
            if (input) {
              _keepHistoryImages();
            } else {
              _drafts.setOutputDirectory(value);
            }
          }),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        key: ValueKey(
          input ? 'metadata-browse-input' : 'metadata-browse-output',
        ),
        tooltip: input ? '选择输入文件夹' : '选择输出文件夹',
        onPressed: _busy ? null : () => _browse(input: input),
        icon: const Icon(Icons.folder_open_outlined),
      ),
      if (input)
        IconButton(
          tooltip: l10nNow.desktopRefreshImages,
          onPressed: _busy ? null : _scan,
          icon: const Icon(Icons.refresh),
        ),
    ],
  );

  Widget _batch() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _card(
        '输入图片',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _directoryField(input: true),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('metadata-history-batch'),
                onPressed: _busy ? null : () => _pickHistory(multiple: true),
                icon: const Icon(Icons.history, size: 18),
                label: Text(l10nNow.desktopChooseFromHistory),
              ),
            ),
            const SizedBox(height: 12),
            _batchPreviews(),
          ],
        ),
      ),
      _card(
        '输出目录',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _directoryField(input: false),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _subfolder,
              onChanged: _busy ? null : (v) => setState(() => _subfolder = v!),
              title: Text(l10nNow.desktopCreateAResultsSubfolderRecommended),
            ),
            SelectableText(
              '实际输出：${_destination ?? '请先选择文件夹'}',
              key: const ValueKey('metadata-actual-output'),
              style: context.texts.bodySmall,
            ),
          ],
        ),
      ),
      _card(
        '处理内容',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10nNow.desktopClearMetadataOnly),
              subtitle: Text(_strip ? '清除生成参数和隐藏元数据' : '将「单张处理」中当前编辑的参数写入所选图片'),
              value: _strip,
              onChanged: _busy ? null : (v) => setState(() => _strip = v),
            ),
            if (!_strip)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => setState(() => _tab = 0),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(l10nNow.desktopViewAndEditMetadata),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              l10nNow
                  .desktopExportPNGCopiesDuplicateFilenamesAreNumberedAutomatically,
            ),
          ],
        ),
      ),
      FilledButton.icon(
        key: const ValueKey('metadata-start-batch'),
        onPressed: _busy || _selected.isEmpty ? null : _startBatch,
        icon: const Icon(Icons.play_arrow),
        label: Text(
          '开始批量处理${_selected.isEmpty ? '' : '（${_selected.length} 张）'}',
        ),
      ),
    ],
  );

  void _focusPreviews() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tab == 1 && _files.isNotEmpty) {
        _previewFocus.requestFocus();
      }
    });
  }

  void _movePreview(int direction) {
    if (!_previewScroll.hasClients) return;
    final position = _previewScroll.position;
    _previewScroll.jumpTo(
      (position.pixels + direction * _previewStride).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  Widget _batchPreviews() => Column(
    key: const ValueKey('metadata-batch-previews'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '图片预览 · ${_files.length} 张 · 已选 ${_selected.length}',
              style: context.texts.bodySmall,
            ),
          ),
          if (_files.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      if (_selected.length == _files.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(_files.map((f) => f.path));
                      }
                    }),
              child: Text(_selected.length == _files.length ? '取消全选' : '全选'),
            ),
          if (_files.isNotEmpty) ...[
            IconButton(
              tooltip: l10nNow.desktopPreviousImageLabelLabel,
              onPressed: () {
                _previewFocus.requestFocus();
                _movePreview(-1);
              },
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: l10nNow.desktopNextImageLabelLabel,
              onPressed: () {
                _previewFocus.requestFocus();
                _movePreview(1);
              },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ],
      ),
      const SizedBox(height: 8),
      if (_files.isEmpty)
        Container(
          height: 110,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _input.text.trim().isEmpty
                ? '选择输入文件夹或从历史选图，在这里预览图片'
                : '没有图片，请确认路径后刷新（不含子文件夹）',
          ),
        )
      else
        Focus(
          focusNode: _previewFocus,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            final direction = event.logicalKey == LogicalKeyboardKey.arrowLeft
                ? -1
                : event.logicalKey == LogicalKeyboardKey.arrowRight
                ? 1
                : 0;
            if (direction == 0) return KeyEventResult.ignored;
            _movePreview(direction);
            return KeyEventResult.handled;
          },
          child: Listener(
            onPointerDown: (_) => _previewFocus.requestFocus(),
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent || !_previewScroll.hasClients) {
                return;
              }
              // 普通竖向滚轮交给外层页面；Shift + 滚轮才在预览条横移。
              if (event.scrollDelta.dx == 0 &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                return;
              }
              final delta = event.scrollDelta.dx != 0
                  ? event.scrollDelta.dx
                  : event.scrollDelta.dy;
              final position = _previewScroll.position;
              final target = (position.pixels + delta).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              );
              if (target == position.pixels) return;
              GestureBinding.instance.pointerSignalResolver.register(event, (
                _,
              ) {
                _previewFocus.requestFocus();
                _previewScroll.jumpTo(target);
              });
            },
            child: SizedBox(
              height: 204,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  scrollbars: false,
                  dragDevices: {
                    ...ScrollConfiguration.of(context).dragDevices,
                    PointerDeviceKind.mouse,
                  },
                ),
                child: Scrollbar(
                  key: const ValueKey('metadata-preview-scrollbar'),
                  controller: _previewScroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 8,
                  child: ListView.separated(
                    key: const PageStorageKey(
                      'metadata-batch-thumbnails-scroll',
                    ),
                    controller: _previewScroll,
                    padding: const EdgeInsets.only(bottom: 18),
                    primary: false,
                    scrollDirection: Axis.horizontal,
                    itemCount: _files.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final file = _files[index];
                      final selected = _selected.contains(file.path);
                      return SizedBox(
                        width: 138,
                        child: Column(
                          children: [
                            Expanded(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Material(
                                    color: context.scheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(12),
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: () => showDialog<void>(
                                        context: context,
                                        builder: (_) => Dialog(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 800,
                                              maxHeight: 680,
                                            ),
                                            child: Column(
                                              children: [
                                                ListTile(
                                                  title: Text(
                                                    p.basename(file.path),
                                                  ),
                                                  trailing: const CloseButton(),
                                                ),
                                                Expanded(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          16,
                                                        ),
                                                    child: _imagePreview(file),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: _imagePreview(
                                          file,
                                          key: ValueKey(
                                            'metadata-thumbnail-${p.basename(file.path)}',
                                          ),
                                          cacheWidth: 240,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    child: Checkbox(
                                      value: selected,
                                      onChanged: _busy
                                          ? null
                                          : (v) => setState(() {
                                              if (v!) {
                                                _selected.add(file.path);
                                              } else {
                                                _selected.remove(file.path);
                                              }
                                            }),
                                    ),
                                  ),
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: IconButton.filledTonal(
                                      tooltip: context.l10n
                                          .metadataRemoveBatchImage(
                                            p.basename(file.path),
                                          ),
                                      onPressed: _busy
                                          ? null
                                          : () => _removeBatchImage(file),
                                      style: IconButton.styleFrom(
                                        backgroundColor: context.scheme.surface,
                                        foregroundColor: context.scheme.error,
                                        fixedSize: const Size.square(32),
                                        minimumSize: const Size.square(32),
                                        padding: EdgeInsets.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Tooltip(
                              message: file.path,
                              child: Text(
                                p.basename(file.path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _imagePreview(File file, {Key? key, int? cacheWidth}) {
    Widget error(BuildContext context, Object error, StackTrace? stack) =>
        const Center(child: Icon(Icons.broken_image_outlined));
    final bytes = _memoryImages[file.path];
    return bytes == null
        ? Image.file(
            file,
            key: key,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            errorBuilder: error,
          )
        : Image.memory(
            bytes,
            key: key,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            errorBuilder: error,
          );
  }

  Widget _results() => _card(
    '处理结果',
    Column(
      key: const ValueKey('metadata-results'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_progress case (final done, final total)?) ...[
          LinearProgressIndicator(value: total == 0 ? null : done / total),
          const SizedBox(height: 10),
        ],
        SelectableText(_status!),
        if (_job != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                _job?.cancel();
                setState(() => _status = '正在完成当前图片，随后取消…');
              },
              child: Text(l10nNow.desktopCancelProcessing),
            ),
          ),
        if (_result case final result?) ...[
          if (result.outputs.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              '保存位置：$_lastDirectory',
              style: context.texts.bodySmall,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openOutput,
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(l10nNow.desktopOpenOutputFolder),
              ),
            ),
            ExpansionTile(
              key: const PageStorageKey('metadata-exported-files'),
              tilePadding: EdgeInsets.zero,
              title: Text(l10nNow.desktopExportedFiles),
              children: [
                SelectableText(
                  result.outputs.join('\n'),
                  style: context.texts.bodySmall,
                ),
              ],
            ),
          ],
          if (result.errors.isNotEmpty)
            ExpansionTile(
              key: const PageStorageKey('metadata-export-errors'),
              initiallyExpanded: true,
              tilePadding: EdgeInsets.zero,
              title: Text('失败详情（${result.errors.length}）'),
              children: [
                SelectableText(
                  result.errors.join('\n'),
                  style: context.texts.bodySmall,
                ),
              ],
            ),
        ],
      ],
    ),
  );
}
