#include "runtime_diagnostics.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;

namespace {
void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

std::string Read(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input), {});
}

LONG WINAPI PreviousFilter(EXCEPTION_POINTERS*) {
  RecordRuntimeEvent("previous-filter");
  return EXCEPTION_EXECUTE_HANDLER;
}

DWORD RunChild(const fs::path& executable, const fs::path& directory,
               const wchar_t* mode) {
  std::wstring command = L"\"" + executable.wstring() + L"\" " + mode +
                         L" \"" + directory.wstring() + L"\"";
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  Require(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                         nullptr, nullptr, &startup, &process) != FALSE,
          "start isolated diagnostics fixture");
  const DWORD wait = WaitForSingleObject(process.hProcess, 15000);
  if (wait != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 1);
  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  Require(wait == WAIT_OBJECT_0, "diagnostics fixture exits without a dialog");
  return exit_code;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  if (argc == 3) {
    SetUnhandledExceptionFilter(PreviousFilter);
    const bool opened = InitializeRuntimeDiagnostics("fixture", argv[2]);
    const std::wstring mode = argv[1];
    if (mode == L"blocked") return opened && SetRuntimeDiagnosticsEnabled(true) ? 1 : 0;
    if (!opened) return 1;
    if (mode == L"off") {
      RecordRuntimeEvent("before-opt-in");
      return RuntimeDiagnosticsEnabled() ? 1 : 0;
    }
    if (mode == L"toggle") {
      if (RuntimeDiagnosticsEnabled() || !SetRuntimeDiagnosticsEnabled(true)) return 1;
      RecordRuntimeEvent("while-enabled");
      if (!SetRuntimeDiagnosticsEnabled(false)) return 1;
      RecordRuntimeEvent("while-disabled");
      return 0;
    }
    if (mode == L"enable" && !SetRuntimeDiagnosticsEnabled(true)) return 1;
    if (!RuntimeDiagnosticsEnabled()) return 1;
    RecordRuntimeEvent("fixture-event");
    if (mode == L"crash") {
      RaiseException(0xE000504C, EXCEPTION_NONCONTINUABLE, 0, nullptr);
      return 1;
    }
    RecordRuntimeEvent("runner-exit");
    return 0;
  }
  fs::path directory;
  try {
    wchar_t temp[MAX_PATH] = {};
    Require(GetTempPathW(MAX_PATH, temp) > 0, "temporary directory");
    directory = fs::path(temp) /
        (L"plana-diagnostics-test-" + std::to_wstring(GetCurrentProcessId()) +
         L"-" + std::to_wstring(GetTickCount64()));
    Require(fs::create_directory(directory), "fresh temporary profile");
    const auto unrelated = directory / L"user-file.txt";
    std::ofstream(unrelated) << "keep";
    wchar_t executable[32768] = {};
    Require(GetModuleFileNameW(nullptr, executable, 32768) > 0, "fixture executable");
    Require(RunChild(executable, directory, L"off") == 0, "untouched profile defaults off");
    Require(!fs::exists(directory / L"logs"), "off writes no log files");
    Require(RunChild(executable, directory, L"toggle") == 0, "toggle during a session");
    const auto first = Read(fs::directory_iterator(directory / L"logs")->path());
    Require(first.find("while-enabled") != std::string::npos &&
            first.find("while-disabled") == std::string::npos, "writes stop immediately");
    Require(RunChild(executable, directory, L"off") == 0, "disabled preference persists");
    Require(RunChild(executable, directory, L"enable") == 0, "enable for next launch");
    for (int i = 0; i < 12; ++i) {
      Require(RunChild(executable, directory, L"write") == 0, "normal log session");
    }
    Require(RunChild(executable, unrelated, L"blocked") == 0,
            "unwritable diagnostics never prevents startup");
    Require(RunChild(executable, directory, L"crash") == 0xE000504C,
            "crash retains its exception exit code");
    size_t logs = 0, dumps = 0;
    bool found_exit = false, found_crash = false;
    for (const auto& entry : fs::directory_iterator(directory / L"logs")) {
      Require(entry.path().extension() == L".log", "shareable folder contains text only");
      ++logs;
      const auto text = Read(entry.path());
      found_exit |= text.find("runner-exit") != std::string::npos;
      found_crash |= text.find("native-crash code=0xE000504C") != std::string::npos;
      Require(text.find("fixture-event") != std::string::npos, "session events persist");
      if (text.find("native-crash") != std::string::npos) {
        Require(text.find("previous-filter") != std::string::npos,
                "previous exception filter is preserved");
      }
    }
    for (const auto& entry : fs::directory_iterator(directory / L"diagnostics")) {
      if (entry.path().extension() == L".dmp") {
        ++dumps;
        Require(Read(entry.path()).substr(0, 4) == "MDMP", "valid Windows minidump signature");
      }
    }
    Require(logs == 10, "bounded retention of ten native sessions");
    Require(dumps == 1 && found_crash, "crash log and minidump survive child exit");
    Require(found_exit, "normal exits are distinguishable from crashes");
    Require(Read(unrelated) == "keep", "unrelated files are preserved");
    fs::remove_all(directory);
    std::cout << "Native diagnostics persistence, retention and crash tests passed.\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    if (!directory.empty()) {
      std::wcerr << L"Evidence kept at " << directory.wstring() << L'\n';
    }
    return 1;
  }
}
