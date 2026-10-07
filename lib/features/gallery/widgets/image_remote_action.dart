import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/external_image_push_config.dart';
import '../external_image_push.dart';
import '../gallery_state.dart';
import '../models.dart';

/// One action shared by the canvas toolbar and the desktop viewer.
class ImageRemoteAction extends ConsumerWidget {
  const ImageRemoteAction({
    super.key,
    required this.result,
    this.enabled = true,
    this.style,
    this.outlined = false,
  });

  final ResultImage? result;
  final bool enabled;
  final ButtonStyle? style;
  final bool outlined;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auto = ref.watch(favoriteAutoUploadProvider);
    // Viewer snapshots may outlive a favorite toggle; read the live record.
    final stored = ref.watch(
      galleryProvider.select(
        (gallery) =>
            gallery.results.where((r) => r.id == result?.id).firstOrNull,
      ),
    );
    final image = stored ?? result;
    final uploading = ref.watch(
      externalImagePushUploadsProvider.select(
        (uploads) => uploads.pending.contains(image?.id),
      ),
    );
    final canAct =
        enabled && image != null && (auto ? stored != null : !uploading);
    final VoidCallback? action = canAct
        ? () {
            if (auto) {
              ref.read(galleryProvider.notifier).toggleFavorite(image.id);
            } else {
              unawaited(
                ref
                    .read(externalImagePushUploadsProvider.notifier)
                    .upload(image),
              );
            }
          }
        : null;
    final icon = auto
        ? Icon(
            image?.favorite == true ? Icons.star : Icons.star_outline,
            size: 18,
          )
        : uploading
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.cloud_upload_outlined, size: 18);
    final label = Text(
      auto
          ? (image?.favorite == true ? '已收藏' : '收藏')
          : uploading
          ? '上传中'
          : '远端上传',
    );
    final key = ValueKey(
      auto ? 'image-favorite-action' : 'image-remote-upload-action',
    );
    return Tooltip(
      message: auto
          ? image?.favorite == true
                ? '取消收藏；远端图片会保留'
                : '收藏并上传原图到远端'
          : '上传原图到远端',
      child: outlined
          ? OutlinedButton.icon(
              key: key,
              style: style,
              onPressed: action,
              icon: icon,
              label: label,
            )
          : TextButton.icon(
              key: key,
              style: style,
              onPressed: action,
              icon: icon,
              label: label,
            ),
    );
  }
}
