#include "manual_view.h"

#include <WebView2.h>
#include <wrl.h>
#include <flutter/method_result_functions.h>
#include <filesystem>
#include <string>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using flutter::EncodableValue;
using Channel = flutter::MethodChannel<EncodableValue>;
using Result = flutter::MethodResult<EncodableValue>;

namespace {
constexpr wchar_t kPage[] = L"https://manual.plana.invalid/index.html";

bool IsManualPage(const wchar_t* uri) {
  if (!uri) return false;
  const std::wstring url(uri);
  const auto end = url.find_first_of(L"?#");
  return url.substr(0, end) == kPage;
}
}  // namespace

class ManualSession : public std::enable_shared_from_this<ManualSession> {
 public:
  ManualSession(HWND window, Channel* channel, std::unique_ptr<Result> opening)
      : window_(window), channel_(channel), opening_(std::move(opening)) {}
  ~ManualSession() {
    if (controller_) controller_->Close();
    if (host_ && IsWindow(host_)) DestroyWindow(host_);
    if (opening_) opening_->Error("closed", "Manual was closed.");
  }

  void Open(const std::filesystem::path& profile,
            const std::filesystem::path& media, bool dark) {
    // WebView2 otherwise shares a parent with the Flutter surface. Windows
    // can place that surface above the renderer even after put_IsVisible.
    host_ = CreateWindowExW(0, L"STATIC", L"Plana Manual",
        WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, 0, 0,
        window_, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!host_) {
      Fail("Manual window", HRESULT_FROM_WIN32(GetLastError()));
      return;
    }
    Resize();
    const auto weak = weak_from_this();
    const auto hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, profile.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [weak, media, dark](HRESULT status, ICoreWebView2Environment* env) -> HRESULT {
              if (const auto self = weak.lock()) {
                if (FAILED(status) || !env) {
                  self->Fail("WebView2 Runtime", status);
                } else {
                  self->CreateController(env, media, dark);
                }
              }
              return S_OK;
            }).Get());
    if (FAILED(hr)) Fail("WebView2 Runtime", hr);
  }

  void Resize() {
    if (!host_) return;
    RECT bounds{};
    GetClientRect(window_, &bounds);
    SetWindowPos(host_, HWND_TOP, 0, 0, bounds.right, bounds.bottom,
        SWP_NOACTIVATE | (ready_ ? SWP_SHOWWINDOW : SWP_NOZORDER));
    if (!controller_) return;
    controller_->put_Bounds(bounds);
    controller_->NotifyParentWindowPositionChanged();
  }

  bool Focus() {
    if (!ready_ || !controller_) return false;
    return SUCCEEDED(controller_->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC));
  }

 private:
  void Fail(const char* stage, HRESULT error) {
    if (host_) ShowWindow(host_, SW_HIDE);
    if (controller_) controller_->put_IsVisible(FALSE);
    ready_ = false;
    const auto detail = std::string(stage) + " (" + std::to_string(error) + ")";
    if (opening_) {
      opening_->Error("manual_unavailable", detail);
      opening_.reset();
    } else {
      channel_->InvokeMethod("failed", std::make_unique<EncodableValue>(detail));
    }
  }

  void CreateController(ICoreWebView2Environment* env,
                        const std::filesystem::path& media, bool dark) {
    const auto weak = weak_from_this();
    const auto hr = env->CreateCoreWebView2Controller(host_,
        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [weak, media, dark](HRESULT status, ICoreWebView2Controller* controller) -> HRESULT {
              if (const auto self = weak.lock()) {
                if (FAILED(status) || !controller) {
                  self->Fail("WebView2 controller", status);
                } else {
                  self->controller_ = controller;
                  self->Resize();
                  const auto configured = self->Navigate(media, dark);
                  if (FAILED(configured)) self->Fail("Manual content", configured);
                }
              }
              return S_OK;
            }).Get());
    if (FAILED(hr)) Fail("WebView2 controller", hr);
  }

  HRESULT Navigate(const std::filesystem::path& media, bool dark) {
    HRESULT hr = controller_->get_CoreWebView2(&web_);
    if (FAILED(hr)) return hr;
    controller_->put_IsVisible(FALSE);
    ComPtr<ICoreWebView2_3> mapped;
    hr = web_.As(&mapped);
    if (FAILED(hr)) return hr;
    std::wstring exe(32768, L'\0');
    const auto length = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
    if (!length || length >= exe.size()) return E_FAIL;
    exe.resize(length);
    const auto assets = std::filesystem::path(exe).parent_path() /
        L"data" / L"flutter_assets" / L"assets" / L"user_manual";
    hr = mapped->SetVirtualHostNameToFolderMapping(L"manual.plana.invalid",
        assets.c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY);
    if (FAILED(hr)) return hr;
    // Only passive media gets its own origin. Documents and editor backups
    // are siblings of this directory and are never served by the WebView.
    hr = mapped->SetVirtualHostNameToFolderMapping(L"media.plana.invalid",
        media.c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
    if (FAILED(hr)) return hr;
    const auto weak = weak_from_this();
    EventRegistrationToken token{};
    hr = web_->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
        [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
          LPWSTR uri = nullptr;
          args->get_Uri(&uri);
          args->put_Cancel(!IsManualPage(uri));
          CoTaskMemFree(uri);
          return S_OK;
        }).Get(), &token);
    if (FAILED(hr)) return hr;
    hr = web_->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>(
        [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
          return args->put_Handled(TRUE);
        }).Get(), &token);
    if (FAILED(hr)) return hr;
    hr = web_->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
          LPWSTR origin = nullptr;
          args->get_Source(&origin);
          const bool trusted = IsManualPage(origin);
          CoTaskMemFree(origin);
          if (!trusted) return S_OK;
          if (const auto self = weak.lock()) {
            LPWSTR message = nullptr;
            if (SUCCEEDED(args->get_WebMessageAsJson(&message)) && message) {
              const int length = WideCharToMultiByte(CP_UTF8, 0, message, -1, nullptr, 0, nullptr, nullptr);
              if (length > 1) {
                std::string json(static_cast<size_t>(length), '\0');
                if (WideCharToMultiByte(CP_UTF8, 0, message, -1, json.data(), length, nullptr, nullptr)) {
                  json.pop_back();  // Converted length includes the terminator.
                  self->Request(std::move(json));
                }
              }
              CoTaskMemFree(message);
            }
          }
          return S_OK;
        }).Get(), &token);
    if (FAILED(hr)) return hr;
    hr = web_->add_NavigationCompleted(Callback<ICoreWebView2NavigationCompletedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
          if (const auto self = weak.lock()) {
            BOOL loaded = FALSE;
            args->get_IsSuccess(&loaded);
            if (!loaded) {
              self->Fail("Manual navigation", E_FAIL);
            } else {
              self->ready_ = true;
              self->Resize();
              self->controller_->put_IsVisible(TRUE);
              self->Focus();
              if (self->opening_) {
                self->opening_->Success();
                self->opening_.reset();
              }
            }
          }
          return S_OK;
        }).Get(), &token);
    if (FAILED(hr)) return hr;
    hr = web_->add_ProcessFailed(Callback<ICoreWebView2ProcessFailedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
          COREWEBVIEW2_PROCESS_FAILED_KIND kind;
          if (SUCCEEDED(args->get_ProcessFailedKind(&kind)) &&
              (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED ||
               kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED)) {
            if (const auto self = weak.lock()) self->Fail("Manual renderer", E_FAIL);
          }
          return S_OK;
        }).Get(), &token);
    if (FAILED(hr)) return hr;
    return web_->Navigate(dark ? L"https://manual.plana.invalid/index.html?theme=dark" : kPage);
  }

  void Request(std::string message) {
    const auto weak = weak_from_this();
    channel_->InvokeMethod("request", std::make_unique<EncodableValue>(std::move(message)),
        std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
            [weak](const EncodableValue* answer) {
              const auto self = weak.lock();
              if (!self || !answer) return;
              const auto json = std::get_if<std::string>(answer);
              if (!json || json->empty()) return;
              const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                  json->c_str(), -1, nullptr, 0);
              if (length <= 0) return;
              std::wstring wide(static_cast<size_t>(length), L'\0');
              if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                  json->c_str(), -1, wide.data(), length)) {
                self->web_->PostWebMessageAsJson(wide.c_str());
              }
            }, nullptr, nullptr));
  }

  HWND window_;
  HWND host_ = nullptr;
  Channel* channel_;
  std::unique_ptr<Result> opening_;
  ComPtr<ICoreWebView2Controller> controller_;
  ComPtr<ICoreWebView2> web_;
  bool ready_ = false;
};

ManualView::ManualView(HWND window, HWND flutter_view, flutter::BinaryMessenger* messenger)
    : window_(window), flutter_view_(flutter_view),
      channel_(std::make_unique<Channel>(messenger, "plana/user_manual",
                                         &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, std::unique_ptr<Result> result) {
    if (call.method_name() == "close") {
      session_.reset();
      SetFocus(flutter_view_);
      result->Success();
    } else if (call.method_name() == "open") {
      const auto args = call.arguments() ? std::get_if<flutter::EncodableList>(call.arguments()) : nullptr;
      if (!args || args->size() != 3) {
        result->Error("invalid_arguments");
        return;
      }
      const auto profile = std::get_if<std::string>(&args->at(0));
      const auto media = std::get_if<std::string>(&args->at(1));
      const auto dark = std::get_if<bool>(&args->at(2));
      if (!profile || !media || !dark) {
        result->Error("invalid_arguments");
        return;
      }
      session_ = std::make_shared<ManualSession>(window_, channel_.get(), std::move(result));
      session_->Open(std::filesystem::u8path(*profile), std::filesystem::u8path(*media), *dark);
    } else {
      result->NotImplemented();
    }
  });
}

ManualView::~ManualView() {
  session_.reset();
  channel_->SetMethodCallHandler(nullptr);
}
void ManualView::Resize() { if (session_) session_->Resize(); }
bool ManualView::Focus() { return session_ && session_->Focus(); }
