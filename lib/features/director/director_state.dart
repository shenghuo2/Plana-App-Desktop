import '../../l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anlas_provider.dart';
import '../../core/store/app_stores.dart';
import '../gallery/albums/album_models.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/gallery_state.dart';
import '../gallery/models.dart';
import 'director_codec.dart';
import 'director_models.dart';
import 'director_service.dart';

class DirectorState {
  const DirectorState({
    this.inputs = const [],
    this.selectedId,
    this.preview,
    this.options = const DirectorOptions(),
    this.busy = false,
    this.message = '',
    this.failed = false,
    this.latest = const [],
    this.hasPendingSave = false,
  });
  final List<DirectorInput> inputs;
  final String? selectedId;
  final ResultImage? preview;
  final DirectorOptions options;
  final bool busy, failed, hasPendingSave;
  final String message;
  final List<ResultImage> latest;
  DirectorInput? get source =>
      inputs.where((e) => e.id == selectedId).firstOrNull;

  DirectorState copyWith({
    List<DirectorInput>? inputs,
    String? selectedId,
    ResultImage? preview,
    DirectorOptions? options,
    bool? busy,
    String? message,
    bool? failed,
    List<ResultImage>? latest,
    bool? hasPendingSave,
  }) => DirectorState(
    inputs: inputs ?? this.inputs,
    selectedId: selectedId ?? this.selectedId,
    preview: preview ?? this.preview,
    options: options ?? this.options,
    busy: busy ?? this.busy,
    message: message ?? this.message,
    failed: failed ?? this.failed,
    latest: latest ?? this.latest,
    hasPendingSave: hasPendingSave ?? this.hasPendingSave,
  );
}

class _PendingResult {
  _PendingResult(this.output, this.operation, this.target);
  final DirectorOutput output;
  final ImageOperation operation;
  final GallerySaveTarget target;
  Uint8List? stamped;
  ResultImage? retry;
}

// Intentionally survives navigation: leaving the workbench does not cancel a
// paid request, lose its output, or touch the creation canvas's selected image.
final directorProvider = NotifierProvider<DirectorController, DirectorState>(
  DirectorController.new,
);

class DirectorController extends Notifier<DirectorState> {
  var _inputSequence = 0;
  final _pending = <_PendingResult>[];
  @override
  DirectorState build() => const DirectorState();

  void options(DirectorOptions value) => state = state.copyWith(options: value);
  void selectInput(String id) {
    if (state.inputs.any((e) => e.id == id)) {
      state = state.copyWith(selectedId: id);
    }
  }

  void selectPreview(ResultImage image) =>
      state = state.copyWith(preview: image);
  void removeInput(String id) {
    final inputs = state.inputs.where((e) => e.id != id).toList();
    state = DirectorState(
      inputs: inputs,
      selectedId: state.selectedId == id
          ? inputs.lastOrNull?.id
          : state.selectedId,
      preview: state.preview,
      options: state.options,
      busy: state.busy,
      message: state.message,
      failed: state.failed,
      latest: state.latest,
      hasPendingSave: state.hasPendingSave,
    );
  }

  void report(Object error) =>
      state = state.copyWith(message: directorError(error), failed: true);

  Future<void> addInput(
    String name,
    Uint8List bytes, {
    String? galleryId,
  }) async {
    final size = await compute((Uint8List value) {
      final image = decodeDirectorImage(value);
      return (image.width, image.height);
    }, bytes);
    if (!ref.mounted) return;
    if (state.inputs.length >= 64 ||
        state.inputs.fold<int>(bytes.length, (n, e) => n + e.bytes.length) >
            256 * 1024 * 1024) {
      throw const FormatException('待处理列表已满，请移除部分图片后再添加');
    }
    final image = DirectorInput(
      id: 'input${_inputSequence++}',
      name: name,
      bytes: bytes,
      width: size.$1,
      height: size.$2,
      galleryId: galleryId,
    );
    state = state.copyWith(
      inputs: [...state.inputs, image],
      selectedId: image.id,
    );
  }

  Future<void> addHistory(ResultImage image) async {
    final bytes =
        image.bytes ??
        await ref.read(appStoresProvider).gallery.readImage(image.id);
    if (bytes == null) throw const FormatException('图片已删除或尚未就绪');
    await addInput(
      image.operation == null
          ? 'plana_${image.seed}.png'
          : '${image.operation!.tool}_${image.id}.png',
      bytes,
      galleryId: image.id,
    );
  }

  Future<void> transform() async {
    if (state.busy || state.hasPendingSave || state.source == null) return;
    final source = state.source!, options = state.options;
    final access = ref.read(directorAccessProvider);
    if (!options.tool.local && !access.available) {
      state = state.copyWith(message: access.reason, failed: true);
      return;
    }
    final target = ref.read(gallerySaveTargetProvider);
    final jobId = DateTime.now().microsecondsSinceEpoch.toString();
    final runner = ref.read(directorRunnerProvider);
    state = state.copyWith(
      busy: true,
      failed: false,
      message: options.tool.local ? '正在本机整理像素…' : '正在转换，可继续选择其他图片…',
    );
    try {
      final outputs = await runner(source, options, access);
      if (!ref.mounted) return;
      if (outputs.isEmpty) throw const FormatException('没有返回可用图片');
      final send = directorSendSize(source.width, source.height);
      for (var i = 0; i < outputs.length; i++) {
        final output = outputs[i];
        final operation = ImageOperation(
          tool: options.tool.code,
          sourceId: source.galleryId,
          sourceName: source.name,
          jobId: jobId,
          variant: output.variant,
          parameters: {
            ...options.record(),
            'startedAt': int.parse(jobId) ~/ 1000,
            'resultIndex': i,
            'sourceWidth': source.width,
            'sourceHeight': source.height,
            if (!options.tool.local) 'sentWidth': send.width,
            if (!options.tool.local) 'sentHeight': send.height,
            'resultWidth': output.width,
            'resultHeight': output.height,
          },
        );
        _pending.add(_PendingResult(output, operation, target));
      }
      state = state.copyWith(latest: [], hasPendingSave: true);
      await _savePending();
    } catch (error) {
      if (ref.mounted) report(error);
    } finally {
      if (ref.mounted) {
        state = state.copyWith(
          busy: false,
          hasPendingSave: _pending.isNotEmpty,
        );
        if (!options.tool.local) ref.invalidate(anlasProvider);
      }
    }
  }

  Future<void> retrySave() async {
    if (state.busy || _pending.isEmpty) return;
    state = state.copyWith(busy: true, failed: false);
    try {
      await _savePending();
    } catch (_) {
      state = state.copyWith(
        failed: true,
        message: l10nNow.desktopTheResultIsStillInMemoryFreeSome,
      );
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> _savePending() async {
    final gallery = ref.read(galleryProvider.notifier);
    final completed = [...state.latest];
    while (_pending.isNotEmpty) {
      final next = _pending.first;
      next.stamped ??= await compute(
        (args) => stampDirectorResult(args.$1, args.$2),
        (next.output.bytes, next.operation),
      );
      if (!ref.mounted) return;
      try {
        final saved = await gallery.addResultToGallery(
          bytes: next.stamped!,
          width: next.output.width,
          height: next.output.height,
          seed: -1,
          badge: ResultBadge.director,
          operation: next.operation,
          target: next.target,
          select: false,
          notify: false,
          retryResult: next.retry,
        );
        completed.add(saved);
        _pending.removeAt(0);
        state = state.copyWith(
          preview: saved,
          latest: List.unmodifiable(completed),
          hasPendingSave: _pending.isNotEmpty,
        );
      } catch (_) {
        next.retry = ref
            .read(galleryProvider)
            .results
            .where(
              (r) =>
                  r.operation?.jobId == next.operation.jobId &&
                  r.operation?.parameters['resultIndex'] ==
                      next.operation.parameters['resultIndex'],
            )
            .firstOrNull;
        state = state.copyWith(
          preview: next.retry,
          failed: true,
          hasPendingSave: true,
          message: l10nNow.desktopConversionFinishedRetrySavingTheResultWithoutRunning,
        );
        return;
      }
    }
    final target = completed.lastOrNull;
    final destination = target == null
        ? ''
        : ref
              .read(albumsProvider)
              .ofImage(target.id)
              .map((id) => ref.read(albumsProvider).name(id))
              .join('、');
    state = state.copyWith(
      failed: false,
      message:
          '已保存 ${completed.length} 张结果到${destination.isEmpty ? '全部作品' : destination}',
    );
  }
}
