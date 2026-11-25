#ifndef RUNNER_RUNTIME_DIAGNOSTICS_H_
#define RUNNER_RUNTIME_DIAGNOSTICS_H_

#include <windows.h>

#include <string>

// Read the profile preference before the Flutter engine starts.
bool InitializeRuntimeDiagnostics(
    const char* version, const std::wstring& profile_override = {});
std::wstring RuntimeLogDirectory();
bool RuntimeDiagnosticsEnabled();
bool SetRuntimeDiagnosticsEnabled(bool enabled);
void RecordRuntimeEvent(const char* event, DWORD error = 0);

#endif  // RUNNER_RUNTIME_DIAGNOSTICS_H_
