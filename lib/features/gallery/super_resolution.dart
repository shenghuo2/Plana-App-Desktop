import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/models.dart';
import '../generate/generation_controller.dart';
import 'albums/album_models.dart';
import 'gallery_state.dart';
import 'upscale_model.dart';

/// 导入图片按实际像素校验，再把 JPEG 等格式转成 NAI 接受的 PNG。
/// PNG 原样保留，转换不裁切、不缩小、不填充背景。
Future<({Uint8List png, int width, int height})> prepareSuperResolutionImage(
  Uint8List bytes,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width, height = descriptor.height;
    _checkSize(width, height);
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    final png =
        bytes.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[i] == signature[i],
        ).every((matches) => matches);
    if (png) return (png: bytes, width: width, height: height);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final encoded = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))?.buffer.asUint8List();
    if (encoded == null) throw const FormatException('图片无法转换为 PNG');
    return (png: encoded, width: image.width, height: image.height);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

void _checkSize(int width, int height) {
  if (width < 16 || height < 16) {
    throw const FormatException('超分辨率需要图片宽高均不少于 16 像素');
  }
  if (!naiV5UpscaleSupportsSize(width, height)) {
    throw FormatException('源图 $width×$height 超过 3,145,728 像素，超分不受理');
  }
}

/// 导入页和图库共用的固定 2× 超分流程。保存目标和选择状态由入口在点击时捕获。
Future<void> superResolveImage(
  BuildContext context,
  WidgetRef ref, {
  required Uint8List png,
  required int width,
  required int height,
  required int seed,
  required GallerySaveTarget target,
  required int selectionRevision,
  GenerateState? input,
}) async {
  _checkSize(width, height);
  final gallery = ref.read(galleryProvider.notifier);
  await ref
      .read(generationProvider.notifier)
      .upscale(
        source: png,
        width: width,
        height: height,
        seed: seed,
        galleryTarget: target,
        input: input,
        canSelect: () => gallery.selectionRevision == selectionRevision,
      );
}
