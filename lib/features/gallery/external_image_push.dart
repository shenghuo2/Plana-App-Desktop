/// Upload original gallery images, including new favorites, to the remote API.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/net/external_image_push_client.dart';
import '../../core/net/external_image_push_config.dart';
import '../../core/store/app_stores.dart';
import '../generate/generation_controller.dart' show genNoticeProvider;
import 'models.dart';

final externalImagePushClientProvider = Provider<ExternalImagePushClient>(
  (_) => ExternalImagePushClient(),
);

class ImageUploadFailure {
  const ImageUploadFailure(this.result, this.message);
  final ResultImage result;
  final String message;
}

class ImageUploadState {
  const ImageUploadState({this.pending = const {}, this.failures = const {}});
  final Set<String> pending;
  final Map<String, ImageUploadFailure> failures;
  bool get busy => pending.isNotEmpty;
}

final externalImagePushUploadsProvider =
    NotifierProvider<ExternalImagePushUploadsNotifier, ImageUploadState>(
      ExternalImagePushUploadsNotifier.new,
    );

class ExternalImagePushUploadsNotifier extends Notifier<ImageUploadState> {
  final _inFlight = <String, Completer<bool>>{};

  @override
  ImageUploadState build() => const ImageUploadState();

  /// Lock before the first await. Manual upload and a favorite gesture for the
  /// same image share one request, including credential and lazy image reads.
  Future<bool> upload(ResultImage result) {
    final existing = _inFlight[result.id];
    if (existing != null) return existing.future;
    final completion = Completer<bool>();
    _inFlight[result.id] = completion;
    state = ImageUploadState(
      pending: {...state.pending, result.id},
      failures: {...state.failures}..remove(result.id),
    );
    unawaited(_perform(result).then(completion.complete));
    return completion.future;
  }

  Future<bool> _perform(ResultImage result) async {
    try {
      final stores = ref.read(appStoresProvider);
      final client = ref.read(externalImagePushClientProvider);
      final settingsNotifier = ref.read(
        externalImagePushSettingsProvider.notifier,
      );
      final settings = await ref.read(externalImagePushSettingsProvider.future);
      if (!ref.mounted) return false;
      final credentials = await settingsNotifier.credentials();
      if (!ref.mounted) return false;
      if (!settings.isConfigured || credentials == null) {
        throw const ExternalImagePushException(
          '请先在「我的 → 远端上传」配置 API 地址和 Token',
        );
      }
      final bytes = result.bytes ?? await stores.gallery.readImage(result.id);
      if (!ref.mounted) return false;
      if (bytes == null || bytes.isEmpty) {
        throw const ExternalImagePushException('原图暂时无法读取，请稍后重试');
      }
      final capturedAt = result.createdAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(result.createdAt, isUtc: true)
          : DateTime.now().toUtc();
      final receipt = await client.upload(
        endpoint: externalImagePushAssetUri(credentials.endpoint),
        token: credentials.token,
        imageBytes: bytes,
        source: {
          'adapter': 'plana-app',
          'page_url': kNovelAiUrl,
          'captured_at': capturedAt.toIso8601String(),
          'source_name': credentials.sourceName,
          if (result.seed >= 0) 'seed_hint': result.seed,
          'metadata': {
            'gallery_id': result.id,
            'width': result.width,
            'height': result.height,
            'badge': result.badge.name,
            'app_version': kAppVersion,
          },
        },
        fileName: '${result.id}.png',
      );
      if (ref.mounted) {
        ref
            .read(genNoticeProvider.notifier)
            .show(receipt.deduplicated ? '远端已存在此图片' : '图片已上传到远端');
      }
      return true;
    } catch (error) {
      final message = error is ExternalImagePushException
          ? error.message
          : '上传失败，请检查配置与网络后重试';
      if (ref.mounted) {
        state = ImageUploadState(
          pending: state.pending,
          failures: {
            ...state.failures,
            result.id: ImageUploadFailure(result.stripped(), message),
          },
        );
        ref.read(genNoticeProvider.notifier).show('$message · 可在任务状态中重试');
      }
      return false;
    } finally {
      _inFlight.remove(result.id);
      if (ref.mounted) {
        state = ImageUploadState(
          pending: {...state.pending}..remove(result.id),
          failures: state.failures,
        );
      }
    }
  }

  Future<bool> retry(String id) {
    final failure = state.failures[id];
    return failure == null ? Future.value(false) : upload(failure.result);
  }

  void dismissFailure(String id) {
    state = ImageUploadState(
      pending: state.pending,
      failures: {...state.failures}..remove(id),
    );
  }
}
