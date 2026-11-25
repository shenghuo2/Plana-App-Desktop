#ifndef RUNNER_MANUAL_VIEW_H_
#define RUNNER_MANUAL_VIEW_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <memory>

class ManualSession;

// The manual fills the client area while its Flutter route is open.
class ManualView {
 public:
  ManualView(HWND window, HWND flutter_view, flutter::BinaryMessenger* messenger);
  ~ManualView();
  void Resize();
  bool Focus();

 private:
  HWND window_;
  HWND flutter_view_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<ManualSession> session_;
};
#endif
