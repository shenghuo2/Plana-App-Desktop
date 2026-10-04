#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"
#include "clipboard_channel.h"
#include "image_drop_target.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  ImageDropTarget* image_drop_target_ = nullptr;
  HWND image_drop_window_ = nullptr;
  // 剪贴板图片读写(Flutter 自带的 Clipboard 只有文本),见 clipboard_channel.h。
  std::unique_ptr<ClipboardChannel> clipboard_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
