import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'director_codec.dart';
import 'director_models.dart';

/// Independent local grid reconstruction. Edge projections locate repeated
/// cell boundaries; samples from cell interiors avoid blurred boundary colors.
/// This does not reproduce NovelAI's proprietary Pixel Snap implementation.
class PixelGrid {
  const PixelGrid(this.step, this.offset, this.confidence);
  final double step, offset, confidence;
}

double _difference(img.Pixel a, img.Pixel b) {
  final alphaA = a.a / 255, alphaB = b.a / 255;
  return ((a.r * alphaA - b.r * alphaB).abs() +
          (a.g * alphaA - b.g * alphaB).abs() +
          (a.b * alphaA - b.b * alphaB).abs() +
          (a.a - b.a).abs()) /
      4;
}

PixelGrid detectPixelGrid(img.Image image, {required bool horizontal}) {
  final length = horizontal ? image.width : image.height;
  final cross = horizontal ? image.height : image.width;
  if (length < 6) return const PixelGrid(1, 0, 0);
  final edges = List<double>.filled(length, 0);
  final stride = math.max(1, cross ~/ 160);
  for (var p = 1; p < length; p++) {
    for (var q = 0; q < cross; q += stride) {
      edges[p] += horizontal
          ? _difference(image.getPixel(p - 1, q), image.getPixel(p, q))
          : _difference(image.getPixel(q, p - 1), image.getPixel(q, p));
    }
  }
  // Collapse a softened boundary to its local maximum before periodic voting.
  // Otherwise resampling blur spreads one edge over several phase bins and
  // hides an otherwise regular (including fractional) pixel grid.
  final peaks = List<double>.filled(length, 0);
  for (var p = 1; p < length - 1; p++) {
    final value = edges[p];
    final left = edges[math.max(1, p - 2)];
    final right = edges[math.min(length - 1, p + 2)];
    if (value >= edges[p - 1] &&
        value > edges[p + 1] &&
        value > math.max(left, right) * 1.35) {
      peaks[p] = value + .5 * (edges[p - 1] + edges[p + 1]);
    }
  }
  final total = peaks.fold<double>(0, (a, b) => a + b);
  if (total < cross / stride * 12) return const PixelGrid(1, 0, 0);
  // Evaluate fractional periods too: a pixel image may have been rescaled by
  // a non-integer factor. Work on projections, never full images per candidate.
  var best = const PixelGrid(1, 0, 0);
  var bestScore = 0.0;
  final maxStep = math.min(64, length / 4);
  for (var step = 2.0; step <= maxStep; step += .25) {
    final bins = List<double>.filled((step * 2).ceil(), 0);
    for (var p = 1; p < length; p++) {
      bins[((p % step) * 2).round() % bins.length] += peaks[p];
    }
    for (var phase = 0; phase < bins.length; phase++) {
      final center = bins[phase];
      final neighbors =
          bins[(phase + 1) % bins.length] +
          bins[(phase + bins.length - 1) % bins.length];
      final share = (center + neighbors * .6) / total;
      final baseline = 2.2 / bins.length;
      final score = (share - baseline) / (1 - baseline);
      // Multiples of a grid explain fewer edges; tiny periods that occur by
      // chance have too little concentration above their uniform baseline.
      if (share > .60 &&
          (score > bestScore + .005 ||
              ((score - bestScore).abs() <= .005 && step > best.step))) {
        bestScore = score;
        best = PixelGrid(step, phase / 2, score);
      }
    }
  }
  return bestScore >= .42 ? best : const PixelGrid(1, 0, 0);
}

List<double> _boundaries(int size, PixelGrid grid) {
  if (grid.step <= 1) return [for (var i = 0; i <= size; i++) i.toDouble()];
  final out = <double>[0];
  for (var p = grid.offset; p < size - .5; p += grid.step) {
    if (p > .5) out.add(p);
  }
  out.add(size.toDouble());
  return out;
}

int _median(List<int> values) {
  values.sort();
  return values[values.length ~/ 2];
}

img.Image _sampleCells(img.Image image, PixelGrid x, PixelGrid y) {
  final bx = _boundaries(image.width, x), by = _boundaries(image.height, y);
  final out = img.Image(
    width: bx.length - 1,
    height: by.length - 1,
    numChannels: 4,
  );
  for (final pixel in out) {
    final channels = List.generate(4, (_) => <int>[]);
    for (final fy in [.3, .5, .7]) {
      for (final fx in [.3, .5, .7]) {
        final sx = (bx[pixel.x] + (bx[pixel.x + 1] - bx[pixel.x]) * fx)
            .floor()
            .clamp(0, image.width - 1);
        final sy = (by[pixel.y] + (by[pixel.y + 1] - by[pixel.y]) * fy)
            .floor()
            .clamp(0, image.height - 1);
        final p = image.getPixel(sx, sy);
        channels[0].add(p.r.toInt());
        channels[1].add(p.g.toInt());
        channels[2].add(p.b.toInt());
        channels[3].add(p.a.toInt());
      }
    }
    pixel.setRgba(
      _median(channels[0]),
      _median(channels[1]),
      _median(channels[2]),
      _median(channels[3]),
    );
  }
  return out;
}

bool _hasInteriorDetail(img.Image image, PixelGrid x, PixelGrid y) {
  if (x.step < 4 || y.step < 4) return false;
  var detailed = 0, total = 0;
  for (
    var cy = y.offset + y.step / 2;
    cy < image.height - y.step;
    cy += y.step
  ) {
    for (
      var cx = x.offset + x.step / 2;
      cx < image.width - x.step;
      cx += x.step
    ) {
      final a = image.getPixel(
        (cx - x.step * .22).floor(),
        (cy - y.step * .22).floor(),
      );
      final b = image.getPixel(
        (cx + x.step * .22).floor(),
        (cy + y.step * .22).floor(),
      );
      if (_difference(a, b) > 22) detailed++;
      total++;
    }
  }
  return total > 0 && detailed / total > .18;
}

img.Image _palette(img.Image source, DirectorOptions options) {
  if (options.palette == DirectorPalette.off) return source;
  if (options.palette == DirectorPalette.auto) {
    // Merge only near colors. A small tolerance cleans color noise without
    // forcing every picture down to the same arbitrary palette size.
    final colors = <(int, int, int)>[];
    final mapping = <int, (int, int, int)>{};
    for (final p in source) {
      if (p.a == 0) continue;
      final key = (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
      final color = mapping.putIfAbsent(key, () {
        for (final c in colors) {
          if ((c.$1 - p.r).abs() <= 6 &&
              (c.$2 - p.g).abs() <= 6 &&
              (c.$3 - p.b).abs() <= 6) {
            return c;
          }
        }
        final c = (p.r.toInt(), p.g.toInt(), p.b.toInt());
        if (colors.length < 256) colors.add(c);
        return c;
      });
      p.setRgba(color.$1, color.$2, color.$3, p.a);
    }
    return source;
  }
  final quantized = img
      .quantize(
        source,
        numberOfColors: options.colors,
        method: img.QuantizeMethod.octree,
      )
      .convert(numChannels: 4);
  // Quantizers may drop alpha; restore it pixel-for-pixel.
  for (final p in quantized) {
    p.a = source.getPixel(p.x, p.y).a;
  }
  return quantized;
}

DirectorOutput snapDirectorPixels(Uint8List bytes, DirectorOptions options) {
  options.validate();
  final source = decodeDirectorImage(bytes);
  var x = detectPixelGrid(source, horizontal: true);
  var y = detectPixelGrid(source, horizontal: false);
  if (x.step <= 1 && y.step <= 1) {
    throw const FormatException('未检测到稳定的像素网格，请选择已有像素画');
  }
  if (!options.avoidOverRefining && _hasInteriorDetail(source, x, y)) {
    x = PixelGrid(math.max(1, x.step / 2), x.offset, x.confidence);
    y = PixelGrid(math.max(1, y.step / 2), y.offset, y.confidence);
  }
  var result = _palette(_sampleCells(source, x, y), options);
  if (options.upscale) {
    result = img.copyResize(
      result,
      width: source.width,
      height: source.height,
      interpolation: img.Interpolation.nearest,
    );
  }
  return DirectorOutput(
    Uint8List.fromList(img.encodePng(result)),
    result.width,
    result.height,
  );
}
