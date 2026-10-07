import Cocoa
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

enum ClipboardChannel {
  static let name = "plana/clipboard"
  private static let maxBytes = 64 * 1024 * 1024
  private static let maxBatchBytes = 256 * 1024 * 1024
  private static let maxPixels = 32 * 1024 * 1024

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "read": read(result)
      case "write": write(call.arguments, result)
      case "smokeCopyFiles":
        guard ProcessInfo.processInfo.environment["PLANA_MACOS_CLIPBOARD_SMOKE_TEST"] == "1",
              let paths = call.arguments as? [String], !paths.isEmpty, paths.count <= 64 else {
          result(FlutterMethodNotImplemented)
          return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        result(pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }))
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func read(_ result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount
    var payload: [String: Any] = [:]
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
      payload["text"] = text
    }

    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    if !urls.isEmpty && urls.allSatisfy({
      UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
    }) {
      payload["fromFile"] = true
      if urls.count > 64 {
        payload["error"] = "too_many_images"
        result(payload)
        return
      }
      let basePayload = payload
      DispatchQueue.global(qos: .userInitiated).async {
        var images: [[String: Any]] = []
        var inputBytes = 0
        var outputBytes = 0
        var error: String?
        for url in urls {
          guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size > 0 else {
            error = "invalid_image"
            break
          }
          if size > maxBytes || inputBytes > maxBatchBytes - size {
            error = "too_large"
            break
          }
          inputBytes += size
          guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                !data.isEmpty, data.count <= maxBytes,
                let converted = png(from: data), converted.count <= maxBytes else {
            error = "invalid_image"
            break
          }
          outputBytes += converted.count
          if outputBytes > maxBatchBytes {
            error = "too_large"
            break
          }
          images.append([
            "image": FlutterStandardTypedData(bytes: converted),
            "name": url.lastPathComponent,
          ])
        }
        DispatchQueue.main.async {
          guard NSPasteboard.general.changeCount == changeCount else {
            result([String: Any]())
            return
          }
          var response = basePayload
          if let error {
            response["error"] = error
          } else {
            response["images"] = images
            if images.count == 1 {
              response["image"] = images[0]["image"]
              response["format"] = "png"
              response["name"] = images[0]["name"]
            }
          }
          result(response)
        }
      }
      return
    }

    var data: Data?
    var isPng = false
    if let png = pasteboard.data(forType: .png) {
      data = png
      isPng = true
    } else if let tiff = pasteboard.data(forType: .tiff) {
      data = tiff
    } else {
      for type in NSImage.imageTypes {
        if let found = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) {
          data = found
          break
        }
      }
    }
    guard let data else {
      result(payload)
      return
    }
    guard !data.isEmpty, data.count <= maxBytes else {
      payload["error"] = "too_large"
      result(payload)
      return
    }

    let basePayload = payload
    let originalPng = isPng
    DispatchQueue.global(qos: .userInitiated).async {
      let converted = originalPng && validImage(data) ? data : png(from: data)
      DispatchQueue.main.async {
        guard NSPasteboard.general.changeCount == changeCount else {
          result([String: Any]())
          return
        }
        var response = basePayload
        if let converted, !converted.isEmpty, converted.count <= maxBytes {
          response["image"] = FlutterStandardTypedData(bytes: converted)
          response["format"] = "png"
        } else {
          response["error"] = "invalid_image"
        }
        result(response)
      }
    }
  }

  private static func source(for data: Data) -> CGImageSource? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 32768, height <= 32768,
          width * height <= maxPixels else { return nil }
    return source
  }

  private static func validImage(_ data: Data) -> Bool {
    source(for: data) != nil
  }

  private static func encode(_ data: Data, as type: UTType) -> Data? {
    guard let source = source(for: data),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output, type.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }

  private static func png(from data: Data) -> Data? {
    // Finder supplies file URLs. Keep validated PNG bytes so generation text
    // chunks survive; only other formats need conversion through CGImage.
    if let source = source(for: data),
       (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
       CGImageSourceCreateImageAtIndex(source, 0, nil) != nil {
      return data
    }
    return encode(data, as: .png)
  }

  private static func write(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let typed = args["image"] as? FlutterStandardTypedData,
          !typed.data.isEmpty, typed.data.count <= maxBytes else {
      result(false)
      return
    }
    let png = typed.data
    DispatchQueue.global(qos: .userInitiated).async {
      guard validImage(png) else {
        DispatchQueue.main.async { result(false) }
        return
      }
      let tiff = encode(png, as: .tiff)
      DispatchQueue.main.async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var written = pasteboard.setData(png, forType: .png)
        if let tiff, tiff.count <= maxBatchBytes {
          written = pasteboard.setData(tiff, forType: .tiff) || written
        }
        result(written)
      }
    }
  }
}
