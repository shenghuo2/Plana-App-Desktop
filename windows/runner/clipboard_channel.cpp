#include "clipboard_channel.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

// 一次最多搬多少字节:与拖入那条路的上限一致(见 Dart 侧 ImageDropPayload)。
// 剪贴板里什么都可能有 —— 资源管理器里复制一个几 GB 的文件再按 Ctrl+V,
// 不该把整个文件读进内存。
constexpr size_t kMaxBytes = 64 * 1024 * 1024;

// PNG 那个自定义剪贴板格式(浏览器、截图工具、Office 都会放这一份)。
UINT PngClipboardFormat() {
  static const UINT format = RegisterClipboardFormat(L"PNG");
  return format;
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return std::string();
  const int count = WideCharToMultiByte(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string out(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
      out.data(), count, nullptr, nullptr);
  return out;
}

// 别的程序正在写剪贴板时,OpenClipboard 会直接失败。等一小会儿再试几次:
// 按一次 Ctrl+V 不该因为后台刚有个程序复制完东西就什么都不发生。
bool OpenClipboardWithRetry(HWND owner) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (OpenClipboard(owner)) return true;
    Sleep(5);
  }
  return false;
}

// 读一份 HGLOBAL 里的全部字节。**复制一份再返回**:剪贴板随时会被换掉,锁着
// 不放会挡住别的程序。
std::vector<uint8_t> ReadGlobal(HANDLE handle) {
  if (!handle) return {};
  const SIZE_T size = GlobalSize(handle);
  if (size == 0 || size > kMaxBytes) return {};
  const auto* data = static_cast<const uint8_t*>(GlobalLock(handle));
  if (!data) return {};
  std::vector<uint8_t> bytes(data, data + size);
  GlobalUnlock(handle);
  return bytes;
}

// 交给剪贴板一份内存。SetClipboardData 成功之后这块内存归系统管,不能再动;
// 失败则还在自己手里,得自己释放。
HGLOBAL CopyToGlobal(const std::vector<uint8_t>& bytes) {
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (!handle) return nullptr;
  void* data = GlobalLock(handle);
  if (!data) {
    GlobalFree(handle);
    return nullptr;
  }
  memcpy(data, bytes.data(), bytes.size());
  GlobalUnlock(handle);
  return handle;
}

// 资源管理器里「复制」一个文件时,剪贴板里给的是路径(CF_HDROP),图得自己去
// 盘上拿 —— 与 macOS 那边 NSImage(contentsOf:) 同一条路数。
std::wstring DroppedFilePath() {
  HANDLE drop = GetClipboardData(CF_HDROP);
  if (!drop) return std::wstring();
  const auto handle = static_cast<HDROP>(drop);
  if (DragQueryFileW(handle, 0xFFFFFFFF, nullptr, 0) != 1) {
    return std::wstring();  // 一次只认一个文件,多了不知道用户要哪张
  }
  const UINT length = DragQueryFileW(handle, 0, nullptr, 0);
  if (length == 0) return std::wstring();
  std::wstring path(length + 1, L'\0');
  const UINT written = DragQueryFileW(handle, 0, path.data(), length + 1);
  if (written == 0) return std::wstring();
  path.resize(written);
  return path;
}

std::vector<uint8_t> ReadFileBytes(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  std::vector<uint8_t> bytes;
  LARGE_INTEGER size = {};
  if (GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
      static_cast<uint64_t>(size.QuadPart) <= kMaxBytes) {
    bytes.resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    if (!ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read,
                  nullptr) ||
        read != bytes.size()) {
      bytes.clear();
    }
  }
  CloseHandle(file);
  return bytes;
}

// 剪贴板里有什么。**图和文本一起交出去**:要不要贴图由 Dart 侧按焦点和文本
// 内容定,分两次问剪贴板会让判据和结果对不上。
flutter::EncodableMap ReadClipboard(HWND owner) {
  flutter::EncodableMap payload;
  if (!OpenClipboardWithRetry(owner)) return payload;

  if (HANDLE text = GetClipboardData(CF_UNICODETEXT)) {
    if (const auto* data = static_cast<const wchar_t*>(GlobalLock(text))) {
      const std::wstring value(data);
      GlobalUnlock(text);
      if (!value.empty()) {
        payload[flutter::EncodableValue("text")] =
            flutter::EncodableValue(Utf8(value));
      }
    }
  }

  std::vector<uint8_t> image;
  std::string format;
  const UINT png_format = PngClipboardFormat();
  if (png_format != 0) {
    image = ReadGlobal(GetClipboardData(png_format));
    if (!image.empty()) format = "png";
  }
  if (image.empty()) {
    // CF_DIB 才是老程序的通用档;CF_DIBV5 只是优先取,它带 alpha 通道。
    image = ReadGlobal(GetClipboardData(CF_DIBV5));
    if (image.empty()) image = ReadGlobal(GetClipboardData(CF_DIB));
    if (!image.empty()) format = "dib";
  }

  bool from_file = false;
  std::wstring name;
  if (image.empty()) {
    const std::wstring path = DroppedFilePath();
    if (!path.empty()) {
      image = ReadFileBytes(path);
      if (!image.empty()) {
        // 格式交给 Dart 侧按字节认(它要解码,认得出是不是图)。
        format = "file";
        from_file = true;
        name = path.substr(path.find_last_of(L"\\/") + 1);
      }
    }
  }
  CloseClipboard();

  if (!image.empty()) {
    payload[flutter::EncodableValue("image")] = flutter::EncodableValue(image);
    payload[flutter::EncodableValue("format")] = flutter::EncodableValue(format);
  }
  if (from_file) {
    // 资源管理器复制文件时剪贴板里那个文本是文件名 —— 标出来,Dart 侧才不会
    // 把它当成「用户想粘文字」而放弃这张图。
    payload[flutter::EncodableValue("fromFile")] = flutter::EncodableValue(true);
  }
  if (!name.empty()) {
    payload[flutter::EncodableValue("name")] = flutter::EncodableValue(Utf8(name));
  }
  return payload;
}

std::vector<uint8_t> BytesOf(const flutter::EncodableMap& args,
                             const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return {};
  const auto* bytes = std::get_if<std::vector<uint8_t>>(&it->second);
  return bytes ? *bytes : std::vector<uint8_t>();
}

bool WriteClipboard(HWND owner, const flutter::EncodableValue* arguments) {
  const auto* args = std::get_if<flutter::EncodableMap>(arguments);
  if (!args) return false;
  const std::vector<uint8_t> image = BytesOf(*args, "image");
  const std::vector<uint8_t> dib = BytesOf(*args, "dib");
  if (image.empty() && dib.empty()) return false;

  if (!OpenClipboardWithRetry(owner)) return false;
  EmptyClipboard();
  bool written = false;
  if (!dib.empty()) {
    // CF_DIB 是给老程序(画图、Word)的:它们不认 PNG 那个自定义格式。
    if (HGLOBAL handle = CopyToGlobal(dib)) {
      if (SetClipboardData(CF_DIB, handle)) {
        written = true;
      } else {
        GlobalFree(handle);
      }
    }
  }
  const UINT png_format = PngClipboardFormat();
  if (!image.empty() && png_format != 0) {
    if (HGLOBAL handle = CopyToGlobal(image)) {
      if (SetClipboardData(png_format, handle)) {
        written = true;
      } else {
        GlobalFree(handle);
      }
    }
  }
  CloseClipboard();
  return written;
}

}  // namespace

ClipboardChannel::ClipboardChannel(HWND owner, flutter::BinaryMessenger* messenger)
    : owner_(owner),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "plana/clipboard",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

void ClipboardChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "read") {
    result->Success(flutter::EncodableValue(ReadClipboard(owner_)));
    return;
  }
  if (call.method_name() == "write") {
    result->Success(
        flutter::EncodableValue(WriteClipboard(owner_, call.arguments())));
    return;
  }
  result->NotImplemented();
}
