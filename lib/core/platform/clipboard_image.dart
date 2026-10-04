import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, compute, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../util/log.dart';

/// 剪贴板这一趟拿回来的东西:一张图、一段文本,以及这张图是不是从文件管理器
/// 里「复制文件」来的。
///
/// **图和文本同时回来是有意的** —— 要不要贴图,取决于调用点看没看到可用的文本
/// (见 [DesktopClipboard.readImage]);分两次问剪贴板,中间可能被别的程序换掉,
/// 判据和结果就对不上了。
class ClipboardContent {
  const ClipboardContent({
    this.image,
    this.format,
    this.name,
    this.text,
    this.fromFile = false,
  });

  static const empty = ClipboardContent();

  /// 图片原始字节,没图时 null。
  final Uint8List? image;

  /// 这张图**从哪儿来**的,没图时 null。
  ///
  /// - `png`:剪贴板里就放着 PNG 字节(macOS 侧一律转成 PNG 再交出来);
  /// - `dib`:Windows 的 CF_DIB(裸 DIB,没有 BMP 文件头),要补头才能解;
  /// - `file`:从一个图片文件里读来的(资源管理器 / 访达里「复制文件」)。
  ///
  /// 它是来源标记,**不是**「这些字节长什么样」—— 怎么处理一律按字节认,
  /// 见 [DesktopClipboard.ensurePng]。
  final String? format;

  /// 图的文件名(从文件管理器复制时系统会带过来),拿不到就没有。
  final String? name;

  /// 纯文本(PNG 之外的第二个用途)。
  final String? text;

  /// 图是从「复制文件」来的。这种时候哪怕剪贴板里带着文件名(资源管理器复制
  /// 文件时就会带),用户要的也是那张图,不是文件名的文本。
  final bool fromFile;

  bool get hasImage => image != null && image!.isNotEmpty;

  /// 有**能拿来用**的文本:空串和纯空白不算 —— 从某些程序里复制图片时,
  /// 剪贴板里会顺带躺着一个空文本块,那不是「用户想贴文字」。
  bool get hasText => text != null && text!.trim().isNotEmpty;
}

/// 桌面端剪贴板图片读写。
///
/// Flutter 自带的 [Clipboard] 只有文本,图片得问系统要:走原生通道
/// `plana/clipboard`(macOS:`NSPasteboard`,见 macos/Runner/ClipboardChannel.swift;
/// Windows:剪贴板 API,见 windows/runner/clipboard_channel.cpp)。
///
/// 非桌面平台、或者原生侧没注册上,一律当作「剪贴板里没图」返回 —— 调用点据此
/// 落回文本粘贴 / 选图,不会因为少一个原生实现就报错。
class DesktopClipboard {
  const DesktopClipboard._();

  static const channel = MethodChannel('plana/clipboard');

  /// 读剪贴板。原生侧没实现、读不到、被别的程序占着,一律返回
  /// [ClipboardContent.empty] —— 「剪贴板里没图」和「这台机器读不了剪贴板」
  /// 对调用点是一回事,都该落回文本粘贴。
  static Future<ClipboardContent> read() async {
    try {
      final map = await channel.invokeMapMethod<String, Object?>('read');
      if (map == null) return ClipboardContent.empty;
      final image = map['image'];
      return ClipboardContent(
        image: image is Uint8List ? image : null,
        format: map['format'] as String?,
        name: map['name'] as String?,
        text: map['text'] as String?,
        fromFile: map['fromFile'] == true,
      );
    } catch (e) {
      // 剪贴板是「顺手就有」的东西:原生侧被别的程序占着、没实现,都不该
      // 让粘贴这个动作本身失败。
      logd('[clipboard] 读取剪贴板失败: $e');
      return ClipboardContent.empty;
    }
  }

  /// 把一张图写进系统剪贴板,成功返回 true。
  ///
  /// [bytes] 是任意格式的原图字节(库里的作品、参考图都行),原生侧需要的容器
  /// 格式在这里统一备好:PNG 各端都认,Windows 另外要一份 DIB —— 老程序
  /// (画图、Word)不认 PNG 格式,只认 CF_DIB。
  static Future<bool> writeImage(Uint8List bytes) async {
    if (bytes.isEmpty) return false;
    try {
      final png = await ensurePng(bytes);
      final args = <String, Object?>{
        'image': png,
        if (defaultTargetPlatform == TargetPlatform.windows)
          'dib': await _dibOf(png),
      };
      return await channel.invokeMethod<bool>('write', args) ?? false;
    } catch (e) {
      logd('[clipboard] 写入剪贴板失败: $e');
      return false;
    }
  }

  /// 从剪贴板取一张能直接用的图(PNG 字节 + 名字),没有就返回 null。
  ///
  /// [preferImage] 为 false 时,**剪贴板里同时有能用的文本就不取图** —— 焦点多半
  /// 在一个输入框里,用户按 Ctrl/⌘+V 想贴的是文字;要图的话有「从剪贴板粘贴」
  /// 这个明确入口。从文件管理器复制的文件例外(见 [ClipboardContent.fromFile])。
  static Future<ClipboardImageBytes?> readImage({bool preferImage = false}) async {
    final content = await read();
    if (!content.hasImage) return null;
    if (!preferImage && content.hasText && !content.fromFile) return null;
    try {
      final png = await ensurePng(content.image!, format: content.format);
      return ClipboardImageBytes(name: content.name, bytes: png);
    } catch (e) {
      // 剪贴板里躺着的可能是「一张图」之外的东西(某些程序把原始像素块塞进来),
      // 读不出来就当没有,别把异常抛给粘贴动作。
      logd('[clipboard] 剪贴板里的图读不出来: $e');
      return null;
    }
  }

  /// 把 [bytes] 统一成 PNG:已经是 PNG 的原样返回(库里的作品都是 PNG,这条
  /// 路径不该有多余的解码开销),其余按**字节**判断后解码重编码。
  ///
  /// 为什么不照 [format] 走:那个字段是「图是从哪儿来的」(png / dib / file),
  /// 不是「这些字节长什么样」。原样信它、把 JPEG 的字节贴在「png」标签上交出去,
  /// 接收方会照着标签解,解出来是花的 —— 这里只认字节。
  static Future<Uint8List> ensurePng(Uint8List bytes, {String? format}) async {
    if (_isBmpHeader(bytes)) {
      // BMP 那份要先补上文件头才好解(裸 DIB 没有 BM 那 14 字节)。
      return compute(_toPng, wrapDibAsBmp(bytes));
    }
    if (_isPng(bytes)) return bytes;
    return compute(_toPng, bytes);
  }

  /// PNG → 裸 DIB(Windows 的 CF_DIB:去掉了 BMP 那 14 字节文件头)。
  static Future<Uint8List> _dibOf(Uint8List png) => compute(_toDib, png);
}

/// [DesktopClipboard.readImage] 的结果:PNG 字节 + 能拿到的原始文件名。
class ClipboardImageBytes {
  const ClipboardImageBytes({required this.bytes, this.name});

  final Uint8List bytes;
  final String? name;
}

/// [DesktopClipboard.readImage] 的默认返回名。
const kClipboardImageName = '剪贴板图片.png';

/// 打包冒烟用的开关,见 [runMacOsClipboardSmokeTest]。
const kMacOsClipboardSmokeTestEnvironment = 'PLANA_MACOS_CLIPBOARD_SMOKE_TEST';

/// 把一个几像素的 PNG 写进系统剪贴板再读回来,对不上就抛。
///
/// 只在 CI 的 macOS 打包校验里跑(`PLANA_MACOS_CLIPBOARD_SMOKE_TEST=1`)。
/// 验的不是 Dart 逻辑(那有单元测试),而是**原生通道真的在这个包里注册上了**:
/// Swift 文件没进 Xcode 工程、方法名对不上这类事,构建和启动都看不出问题,
/// 要等用户按 ⌘V 才发现 —— 那时候已经发出去了。会覆盖剪贴板内容,故只在 CI 跑。
Future<void> runMacOsClipboardSmokeTest() async {
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
  if (!await DesktopClipboard.writeImage(png)) {
    throw StateError('写入剪贴板失败(原生通道未注册?)');
  }
  final content = await DesktopClipboard.read();
  if (!content.hasImage) {
    throw StateError('刚写进去的图读不回来(原生通道未注册?)');
  }
  if (content.format != 'png') {
    throw StateError('剪贴板回包的格式不对: ${content.format}');
  }
  final decoded = img.decodeImage(content.image!);
  if (decoded == null || decoded.width != 2 || decoded.height != 2) {
    throw StateError('读回来的图不是写进去那张: ${decoded?.width}x${decoded?.height}');
  }
}

bool _isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

bool _isBmpHeader(Uint8List bytes) =>
    bytes.length > 2 && bytes[0] == 0x42 && bytes[1] == 0x4D;

Uint8List _toPng(Uint8List bytes) {
  final decoded = img.decodeImage(bytes, frame: 0);
  if (decoded == null) throw const FormatException('剪贴板里的图片无法解码');
  return Uint8List.fromList(img.encodePng(decoded));
}

Uint8List _toDib(Uint8List png) {
  final decoded = img.decodeImage(png, frame: 0);
  if (decoded == null) throw const FormatException('剪贴板里的图片无法解码');
  // 24 位不透明图:CF_DIB 的通用档,画图 / Word / Photoshop 都吃;32 位带 alpha
  // 的那档要配 BITFIELDS 才行,而接收方对它的支持远比 24 位参差。
  final bmp = img.encodeBmp(decoded.convert(numChannels: 3));
  return Uint8List.sublistView(bmp, 14); // 去掉 "BM" 文件头,剩下的就是 DIB
}

/// 给裸 DIB 补一个 BMP 文件头,好交给 `image` 包解码。
///
/// Windows 剪贴板里给的是 CF_DIB —— 从 BITMAPINFOHEADER 开始,**没有** BMP 文件
/// 开头那 14 字节。补的时候 bfOffBits 不能照抄「14 + 头大小」:调色板(≤8 位色)
/// 和 40 字节头后面挂的三色掩码(BI_BITFIELDS)都得算进去,少了这块,像素数据
/// 的起点就会偏,解出来整张图是错位的。
///
/// 已经带 "BM" 文件头的原样返回。
Uint8List wrapDibAsBmp(Uint8List dib) {
  if (_isBmpHeader(dib)) return dib;
  if (dib.length < 40) throw const FormatException('DIB 头不完整');
  final headerSize = _u32(dib, 0);
  final bitCount = _u16(dib, 14);
  final compression = _u32(dib, 16);
  final colorsUsed = _u32(dib, 32);
  final paletteEntries = bitCount <= 8
      ? (colorsUsed != 0 ? colorsUsed : 1 << bitCount)
      : 0;
  // 40 字节头 + BI_BITFIELDS:三个掩码紧跟在头后面,但它们不算在 biSize 里。
  final masks =
      headerSize == 40 && (compression == 3 || compression == 6) ? 12 : 0;
  final offset = 14 + headerSize + paletteEntries * 4 + masks;
  if (offset > 14 + dib.length) throw const FormatException('DIB 像素偏移越界');
  final out = Uint8List(14 + dib.length);
  final header = ByteData.sublistView(out);
  header
    ..setUint8(0, 0x42) // 'B'
    ..setUint8(1, 0x4D) // 'M'
    ..setUint32(2, out.length, Endian.little)
    ..setUint32(10, offset, Endian.little);
  out.setRange(14, out.length, dib);
  return out;
}

int _u16(Uint8List bytes, int at) =>
    ByteData.sublistView(bytes).getUint16(at, Endian.little);

int _u32(Uint8List bytes, int at) =>
    ByteData.sublistView(bytes).getUint32(at, Endian.little);
