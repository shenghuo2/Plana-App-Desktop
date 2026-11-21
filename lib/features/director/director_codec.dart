import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

import '../gallery/image_operation.dart';
import 'director_models.dart';

const directorMaxInputPixels = 24000000;
const directorMaxFileBytes = 64 * 1024 * 1024;

img.Image decodeDirectorImage(Uint8List bytes) {
  if (bytes.length > directorMaxFileBytes) {
    throw const FormatException('图片文件过大，请选择小于 64 MB 的图片');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width < 1 || info.height < 1) {
    throw const FormatException('无法读取图片，请选择 PNG、JPG 或 WebP 图片');
  }
  if (info.width * info.height > directorMaxInputPixels ||
      info.width > 16384 ||
      info.height > 16384) {
    throw const FormatException('图片超过本机处理上限，请先缩小至 2400 万像素以内');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('图片解码失败');
  return img.bakeOrientation(decoded);
}

({int width, int height}) directorSendSize(int width, int height) {
  var w = width, h = height;
  final area = w * h;
  if (area > 3143728) {
    final scale = math.sqrt(3143728 / area);
    w = math.max(1, (w * scale).floor());
    h = math.max(1, (h * scale).floor());
  }
  if (w * h < 1011712) {
    final scale = math.sqrt(1048576 / (w * h));
    w = math.max(1, (w * scale).floor());
    h = math.max(1, (h * scale).floor());
  }
  return (width: w, height: h);
}

/// The public client prices these operations with its 28-step augmentation
/// calculation. This is a non-subscriber estimate, never a relay quote.
int directorAnlasEstimate(DirectorTool tool, int width, int height) {
  if (tool.local) return 0;
  var area = (width * height).toDouble();
  area = area.clamp(1048576, 3145728);
  final base = math.max(
    2,
    (2.951823174884865e-6 * area + 5.753298233447344e-7 * area * 28).ceil(),
  );
  return tool == DirectorTool.removeBackground ? base * 3 + 5 : base;
}

({String image, int width, int height}) prepareDirectorImage(Uint8List bytes) {
  var source = decodeDirectorImage(bytes);
  final size = directorSendSize(source.width, source.height);
  if (size.width > 16384 || size.height > 16384) {
    throw const FormatException('图片过于狭长，请调整图片比例后再转换');
  }
  if (source.width != size.width || source.height != size.height) {
    source = img.copyResize(
      source,
      width: size.width,
      height: size.height,
      interpolation: img.Interpolation.average,
    );
  }
  return (
    image: base64Encode(img.encodePng(source)),
    width: source.width,
    height: source.height,
  );
}

List<DirectorOutput> decodeDirectorResponse(
  Uint8List bytes,
  DirectorTool tool,
) {
  if (bytes.length > directorMaxFileBytes) {
    throw const FormatException('导演接口响应过大，已停止解析');
  }
  final png =
      bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71;
  final files = <Uint8List>[];
  if (png) {
    files.add(bytes);
  } else if (bytes.length > 4 && bytes[0] == 80 && bytes[1] == 75) {
    late Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw const FormatException('导演接口返回的压缩包损坏或不受支持');
    }
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile || !file.name.toLowerCase().endsWith('.png')) continue;
      total += file.size;
      if (files.length >= 12 || total > directorMaxFileBytes) {
        throw const FormatException('返回的图片数量或大小超出处理上限');
      }
      try {
        files.add(Uint8List.fromList(file.content));
      } catch (_) {
        throw const FormatException('无法解压导演接口返回的图片');
      }
    }
  } else {
    throw const FormatException('接口未返回图片，请确认服务支持导演工具协议');
  }
  if (files.isEmpty) throw const FormatException('导演接口返回的压缩包中没有图片');
  const variants = ['masked', 'generated', 'blend'];
  return [
    for (var i = 0; i < files.length; i++)
      () {
        final image = decodeDirectorImage(files[i]);
        return DirectorOutput(
          files[i],
          image.width,
          image.height,
          variant: tool == DirectorTool.removeBackground && files.length == 3
              ? variants[i]
              : null,
        );
      }(),
  ];
}

Uint8List stampDirectorResult(Uint8List bytes, ImageOperation operation) {
  final image = decodeDirectorImage(bytes);
  // A processed image is not a new generation with its source's seed/prompt.
  image.textData = {'PlanaDirector': jsonEncode(operation.toJson())};
  image.exif.clear();
  return Uint8List.fromList(img.encodePng(image));
}
