import Cocoa
import FlutterMacOS

/// 剪贴板里的图片读写。
///
/// Flutter 自带的 `Clipboard` 只有文本,图片这半截只能在原生侧做。Dart 那头的
/// 门面在 `lib/core/platform/clipboard_image.dart` —— **通道名和几个键要对上**,
/// 那边认 `read` / `write`,以及 image / format / name / fromFile / text。
///
/// 写:PNG 和 TIFF 各放一份。PNG 是给现代程序(浏览器、聊天工具、本 app 自己)
/// 的;TIFF 是给只认位图的老程序(预览、部分 Office)的,少了它那些程序粘出来
/// 是空的。两份都失败才算写不进去。
///
/// 读:PNG → TIFF(转 PNG)→「复制文件」(Finder 里复制的图片文件)。最后这条要
/// 卡体积:复制一个几 GB 的文件再按 ⌘V,不该把整个文件读进内存。
enum ClipboardChannel {
  static let name = "plana/clipboard"

  /// 从剪贴板取图的体积上限,和拖入那条路的限制一致(见 ImageDropPayload)。
  private static let maxBytes = 64 * 1024 * 1024

  /// 只在启动时调一次。**通道对象故意不存下来**:方法处理器是挂在 messenger 上
  /// 的,不跟着这个对象走 —— 存成属性再在某个「清理」里置空,反而会把通道拆掉。
  /// (Windows 那边由 FlutterWindow 持有,两边的生命周期模型不一样。)
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "read":
        result(read())
      case "write":
        result(write(call.arguments))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 剪贴板里有什么。**图和文本一起交出去**:要不要贴图由 Dart 侧按焦点和文本
  /// 内容定,分两次问剪贴板会让判据和结果对不上。
  private static func read() -> [String: Any] {
    let pasteboard = NSPasteboard.general
    var payload: [String: Any] = [:]
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
      payload["text"] = text
    }
    if let image = imageData(from: pasteboard) {
      payload["image"] = FlutterStandardTypedData(bytes: image.data)
      payload["format"] = "png"
      if image.fromFile {
        // 用户按的是「复制文件」,剪贴板里那个文本是文件名 —— 标出来,Dart 侧
        // 才不会把它当成「用户想粘文字」而放弃这张图。
        payload["fromFile"] = true
      }
      if let name = image.name {
        payload["name"] = name
      }
    }
    return payload
  }

  private static func imageData(
    from pasteboard: NSPasteboard
  ) -> (data: Data, fromFile: Bool, name: String?)? {
    // 文件 URL 排在最前,而不是当兜底。访达里复制的图走的是「懒加载」:
    // 剪贴板上的公共图片类型**要到有人去取的时候才现算出来**,文件被挪走或者
    // 已经不在本地(iCloud 未下载)就会取空。按文件 URL 从盘上读是唯一稳的那条。
    if let file = fileImage(from: pasteboard) { return file }
    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      return (png, false, nil)
    }
    if let tiff = pasteboard.data(forType: .tiff), let png = png(fromTIFF: tiff) {
      return (png, false, nil)
    }
    // 截图工具、浏览器、Office 放的不一定是 .png / .tiff 那两个名字,可能是
    // public.jpeg、public.heic、org.webmproject.webp…… 问一遍系统认哪些。
    for type in NSImage.imageTypes {
      let pasteboardType = NSPasteboard.PasteboardType(type)
      guard let data = pasteboard.data(forType: pasteboardType) else { continue }
      if let converted = png(fromImageData: data) {
        return (converted, false, nil)
      }
    }
    return nil
  }

  /// 「复制文件」:剪贴板里给的是文件 URL,图得自己去盘上读。
  private static func fileImage(
    from pasteboard: NSPasteboard
  ) -> (data: Data, fromFile: Bool, name: String?)? {
    guard
      let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL],
      let url = urls.first,
      // 体积先卡在**读之前**:按 ⌘V 时不该把一个几 GB 的文件整个拉进内存。
      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maxBytes,
      let data = try? Data(contentsOf: url),
      let png = png(fromImageData: data)
    else { return nil }
    return (png, true, url.lastPathComponent)
  }

  private static func png(fromImageData data: Data) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
    return png(fromImage: image)
  }

  private static func png(fromImage image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation else { return nil }
    return png(fromTIFF: tiff)
  }

  private static func png(fromTIFF tiff: Data) -> Data? {
    NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
  }

  /// 把一张图写进剪贴板。参数里 `image` 是 Dart 侧备好的 PNG 字节
  /// (`dib` 那份是 Windows 才需要的)。
  private static func write(_ arguments: Any?) -> Bool {
    guard
      let args = arguments as? [String: Any],
      let typed = args["image"] as? FlutterStandardTypedData,
      let image = NSImage(data: typed.data)
    else { return false }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    var written = false
    if let png = png(fromImage: image) {
      written = pasteboard.setData(png, forType: .png)
    }
    if let tiff = image.tiffRepresentation {
      // 第二份只是兼容老程序:它失败不该把已经写好的 PNG 一起否掉。
      pasteboard.setData(tiff, forType: .tiff)
    }
    return written
  }
}
