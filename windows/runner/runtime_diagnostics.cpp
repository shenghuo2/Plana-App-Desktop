#include "runtime_diagnostics.h"

#include <dbghelp.h>
#include <shlobj.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <iterator>
#include <vector>

namespace {
std::filesystem::path profile;
std::string app_version;
volatile LONG recording = 0;
HANDLE log_file = INVALID_HANDLE_VALUE;
wchar_t dump_path[32768] = {};
LONG handling_crash = 0;
HMODULE dbghelp_module = nullptr;
using DumpWriter = decltype(&MiniDumpWriteDump);
DumpWriter dump_writer = nullptr;
LPTOP_LEVEL_EXCEPTION_FILTER previous_filter = nullptr;

void WriteLog(const char* message) {
  if (!RuntimeDiagnosticsEnabled()) return;
  DWORD written = 0;
  WriteFile(log_file, message, static_cast<DWORD>(std::strlen(message)),
            &written, nullptr);
  FlushFileBuffers(log_file);
}

LONG WINAPI RecordCrash(EXCEPTION_POINTERS* exception) {
  if (RuntimeDiagnosticsEnabled() &&
      InterlockedCompareExchange(&handling_crash, 1, 0) == 0) {
    const auto* record = exception ? exception->ExceptionRecord : nullptr;
    char line[1024];
    HMODULE fault_module = nullptr;
    wchar_t module_path[MAX_PATH] = {};
    const void* address = record ? record->ExceptionAddress : nullptr;
    if (address && GetModuleHandleExW(
                       GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(address), &fault_module)) {
      GetModuleFileNameW(fault_module, module_path, MAX_PATH);
    }
    const wchar_t* module_name = std::wcsrchr(module_path, L'\\');
    module_name = module_name ? module_name + 1 : module_path;
    std::snprintf(line, sizeof(line),
                  "native-crash code=0x%08lX address=%p module=%ls offset=0x%llX\r\n",
                  record ? record->ExceptionCode : DWORD{0}, address, module_name,
                  static_cast<unsigned long long>(
                      reinterpret_cast<ULONG_PTR>(address) -
                      reinterpret_cast<ULONG_PTR>(fault_module)));
    WriteLog(line);
    if (dump_writer && dump_path[0]) {
      HANDLE dump = CreateFileW(dump_path, GENERIC_WRITE, 0, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (dump != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION info = {};
        info.ThreadId = GetCurrentThreadId();
        info.ExceptionPointers = exception;
        const BOOL saved = dump_writer(
            GetCurrentProcess(), GetCurrentProcessId(), dump, MiniDumpNormal,
            exception ? &info : nullptr, nullptr, nullptr);
        const DWORD error = saved ? 0 : GetLastError();
        FlushFileBuffers(dump);
        CloseHandle(dump);
        std::snprintf(line, sizeof(line), "minidump saved=%d error=%lu\r\n",
                      saved ? 1 : 0, error);
        WriteLog(line);
        if (!saved) DeleteFileW(dump_path);
      }
    }
  }
  // Preserve Windows reporting and the previous handler, if one exists.
  return previous_filter ? previous_filter(exception) : EXCEPTION_CONTINUE_SEARCH;
}

void TrimReports(const std::filesystem::path& directory, const wchar_t* extension,
                 size_t keep) {
  std::vector<std::filesystem::path> reports;
  std::error_code error;
  for (const auto& entry : std::filesystem::directory_iterator(directory, error)) {
    if (entry.path().filename().wstring().rfind(L"native-", 0) == 0 &&
        entry.path().extension() == extension && entry.is_regular_file(error)) {
      reports.push_back(entry.path());
    }
  }
  std::sort(reports.begin(), reports.end());
  for (size_t i = 0; i + keep < reports.size(); ++i) {
    std::filesystem::remove(reports[i], error);
  }
}

std::filesystem::path PreferencePath() {
  return profile / L"write-diagnostic-logs.enabled";
}

// Keep the handle valid until process exit. A fault can arrive on another
// thread while the UI toggles recording; the exception filter never takes a lock.
bool PrepareLog() {
  if (log_file == INVALID_HANDLE_VALUE) {
    const std::filesystem::path directory(RuntimeLogDirectory());
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error) return false;
    TrimReports(directory, L".log", 9);
    SYSTEMTIME now = {};
    GetSystemTime(&now);
    wchar_t name[100];
    std::swprintf(name, 100, L"native-%04u%02u%02u-%02u%02u%02u-%03u-%lu",
                   now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                   now.wSecond, now.wMilliseconds, GetCurrentProcessId());
    const auto stem = directory / name;
    const auto log_path = stem.wstring() + L".log";
    log_file = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                          CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log_file == INVALID_HANDLE_VALUE) return false;
    // A memory dump is private. Only text files belong in the shareable folder.
    const auto dumps = profile / L"diagnostics";
    std::filesystem::create_directories(dumps, error);
    const auto dump = (dumps / name).wstring() + L".dmp";
    if (!error && dump.size() < std::size(dump_path)) {
      TrimReports(dumps, L".dmp", 9);
      std::copy(dump.begin(), dump.end(), dump_path);
      dump_path[dump.size()] = L'\0';
    }
    // Resolve before crashing; loading DLLs in a fault handler is unsafe.
    dbghelp_module = LoadLibraryExW(L"dbghelp.dll", nullptr,
                                    LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (dbghelp_module) {
      const auto address = GetProcAddress(dbghelp_module, "MiniDumpWriteDump");
      static_assert(sizeof(address) == sizeof(dump_writer));
      std::memcpy(&dump_writer, &address, sizeof(dump_writer));
    }
    previous_filter = SetUnhandledExceptionFilter(RecordCrash);
  }
  return true;
}

void StartRecording() {
  InterlockedExchange(&recording, 1);
  char line[256];
  std::snprintf(line, sizeof(line), "session-start version=%s pid=%lu\r\n",
                app_version.c_str(), GetCurrentProcessId());
  WriteLog(line);
}
}  // namespace

std::wstring RuntimeLogDirectory() {
  return profile.empty() ? std::wstring() : (profile / L"logs").wstring();
}

bool RuntimeDiagnosticsEnabled() {
  return InterlockedCompareExchange(&recording, 0, 0) != 0;
}

bool InitializeRuntimeDiagnostics(const char* version, const std::wstring& profile_override) {
  try {
    app_version = version;
    profile = profile_override;
    if (profile.empty()) {
      PWSTR local = nullptr;
      const HRESULT status = SHGetKnownFolderPath(
          FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &local);
      if (SUCCEEDED(status) && local) profile = std::filesystem::path(local) / L"Plana App Desktop";
      CoTaskMemFree(local);
      if (profile.empty()) return false;
    }
    if (std::filesystem::is_regular_file(PreferencePath())) {
      if (!PrepareLog()) return false;
      StartRecording();
    }
    return true;
  } catch (...) {
    // Diagnostics must not make application startup fail.
    return false;
  }
}

bool SetRuntimeDiagnosticsEnabled(bool enabled) {
  try {
    if (profile.empty()) return false;
    if (enabled) {
      if (!PrepareLog()) return false;
      HANDLE marker = CreateFileW(PreferencePath().c_str(), GENERIC_WRITE,
                                  FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
      if (marker == INVALID_HANDLE_VALUE) return false;
      CloseHandle(marker);
      if (!RuntimeDiagnosticsEnabled()) StartRecording();
    } else {
      if (!DeleteFileW(PreferencePath().c_str())) {
        const DWORD error = GetLastError();
        if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) return false;
      }
      if (RuntimeDiagnosticsEnabled()) RecordRuntimeEvent("recording-stopped");
      InterlockedExchange(&recording, 0);
    }
    return true;
  } catch (...) {
    return false;
  }
}

void RecordRuntimeEvent(const char* event, DWORD error) {
  if (!RuntimeDiagnosticsEnabled()) return;
  SYSTEMTIME now = {};
  GetSystemTime(&now);
  char line[512];
  std::snprintf(line, sizeof(line), "%02u:%02u:%02u.%03uZ %s error=%lu\r\n",
                now.wHour, now.wMinute, now.wSecond, now.wMilliseconds, event,
                error);
  WriteLog(line);
}
