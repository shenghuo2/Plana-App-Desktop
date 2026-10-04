import Cocoa
import FlutterMacOS

// The enclosing view receives Finder drops while normal pointer events continue
// to the Flutter child. Coordinates sent to Dart are physical pixels, matching
// the existing Windows channel contract (including Retina scaling).
class PlanaDropView: NSView {
  let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: .zero)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func paths(_ sender: NSDraggingInfo) -> [String] {
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    return Array(urls.prefix(65)).map { $0.path }
  }

  private func send(_ method: String, _ sender: NSDraggingInfo, paths: [String] = []) {
    let point = convert(sender.draggingLocation, from: nil)
    let scale = window?.backingScaleFactor ?? 1
    channel.invokeMethod(method, arguments: [
      "x": point.x * scale,
      "y": (bounds.height - point.y) * scale,
      "paths": paths,
    ])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return draggingUpdated(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !paths(sender).isEmpty else { return [] }
    send("over", sender)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("leave", arguments: nil)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return !paths(sender).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let files = paths(sender)
    guard !files.isEmpty else { return false }
    send("drop", sender, paths: files)
    return true
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let channel = FlutterMethodChannel(
      name: "plana/image_drop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let container = NSViewController()
    let dropView = PlanaDropView(channel: channel)
    container.view = dropView
    container.addChild(flutterViewController)
    let flutterView = flutterViewController.view
    flutterView.frame = dropView.bounds
    flutterView.autoresizingMask = [.width, .height]
    dropView.addSubview(flutterView)
    let windowFrame = self.frame
    self.contentViewController = container
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1440, height: 900))
    self.minSize = NSSize(width: 1000, height: 680)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
  }
}
