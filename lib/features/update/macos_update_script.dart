/// DMG 更新流程参考 Aaalice_NAI_Launcher 的 macos_update_script.dart。
/// 先验证并暂存新版,再等待主程序退出;用首帧回执和实际进程 PID 判定启动。
class MacOSUpdateScript {
  static String build({
    required int appPid,
    required String version,
    required String architecture,
    required String dmgPath,
    required String targetApp,
    required String workDirectory,
    required String stagedApp,
    required String backupApp,
    required String startupFile,
    int startupTimeout = 60,
  }) {
    var nativeVersion = version
        .split('+')
        .first
        .replaceAll(RegExp(r'[^\d.]'), '');
    final segments = nativeVersion
        .split('.')
        .where((s) => s.isNotEmpty)
        .toList();
    while (segments.length < 3) {
      segments.add('0');
    }
    nativeVersion = segments.join('.');
    final build = version.contains('+') ? version.split('+').last : '';
    final values = <String, String>{
      'APP_PID': appPid.toString(),
      'VERSION': quote(version),
      'NATIVE_VERSION': quote(nativeVersion),
      'BUILD': quote(build),
      'ARCHITECTURE': quote(architecture == 'arm64' ? 'arm64' : 'x86_64'),
      'DMG': quote(dmgPath),
      'TARGET': quote(targetApp),
      'WORK': quote(workDirectory),
      'STAGED': quote(stagedApp),
      'BACKUP': quote(backupApp),
      'STARTUP': quote(startupFile),
      'TIMEOUT': startupTimeout.toString(),
    };
    var script = _template;
    for (final entry in values.entries) {
      script = script.replaceAll('@@${entry.key}@@', entry.value);
    }
    return script;
  }

  static String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

  static const _template = r'''#!/bin/bash
set -Eeuo pipefail
AppPid=@@APP_PID@@
Version=@@VERSION@@
ExpectedVersion=@@NATIVE_VERSION@@
ExpectedBuild=@@BUILD@@
Architecture=@@ARCHITECTURE@@
DmgPath=@@DMG@@
TargetApp=@@TARGET@@
WorkDir=@@WORK@@
StagedApp=@@STAGED@@
BackupApp=@@BACKUP@@
StartupFile=@@STARTUP@@
StartupTimeout=@@TIMEOUT@@
MountDir="$WorkDir/mount"
ReadyFile="$WorkDir/ready"
ResultFile="$WorkDir/result.json"
LogFile="$WorkDir/update.log"
Mounted=0
Swapped=0
UpdatedPid=''
mkdir -p -- "$WorkDir"
exec >>"$LogFile" 2>&1

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}
write_result() {
  printf '{"success":%s,"version":"%s"}\n' "$1" "$(json_escape "$Version")" > "$ResultFile.tmp"
  mv -f -- "$ResultFile.tmp" "$ResultFile"
}
cleanup() {
  set +e
  if [[ "$Mounted" -eq 1 ]]; then
    /usr/bin/hdiutil detach "$MountDir" -force
  fi
  rm -rf -- "$StagedApp" "$MountDir"
  rm -f -- "$ReadyFile" "$StartupFile" "$WorkDir/pending.json" "$0"
}
fail() {
  local status="$1"
  trap - ERR TERM INT
  set +e
  printf 'Update failed (status %s); retaining previous version.\n' "$status"
  if [[ -n "$UpdatedPid" ]]; then
    kill "$UpdatedPid" 2>/dev/null || true
    wait "$UpdatedPid" 2>/dev/null || true
  fi
  if [[ "$Swapped" -eq 1 && -d "$BackupApp" ]]; then
    rm -rf -- "$TargetApp"
    mv -- "$BackupApp" "$TargetApp"
    Swapped=0
  fi
  write_result false
  if ! kill -0 "$AppPid" 2>/dev/null && [[ -d "$TargetApp" ]]; then
    /usr/bin/open "$TargetApp" || true
  fi
  exit "$status"
}
trap 'fail $?' ERR
trap 'fail 1' TERM INT
trap cleanup EXIT

[[ "$AppPid" -gt 0 && "$TargetApp" == *.app ]]
[[ "$TargetApp" != /Volumes/* && "$TargetApp" != *'/AppTranslocation/'* ]]
TargetParent="$(dirname "$TargetApp")"
[[ -d "$TargetApp" && -w "$TargetParent" ]]
[[ "$(dirname "$StagedApp")" == "$TargetParent" && ! -e "$StagedApp" ]]
[[ "$(dirname "$BackupApp")" == "$TargetParent" && ! -e "$BackupApp" ]]
mkdir -p -- "$MountDir"
/usr/bin/hdiutil attach "$DmgPath" -readonly -nobrowse -mountpoint "$MountDir"
Mounted=1
CandidateApp="$MountDir/Plana App.app"
[[ -d "$CandidateApp" ]]
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
CurrentId="$(plist_value "$TargetApp" CFBundleIdentifier)"
Executable="$(plist_value "$TargetApp" CFBundleExecutable)"
[[ -n "$CurrentId" && -n "$Executable" && "$Executable" != */* ]]
[[ "$(plist_value "$CandidateApp" CFBundleIdentifier)" == "$CurrentId" ]]
[[ "$(plist_value "$CandidateApp" CFBundleExecutable)" == "$Executable" ]]
[[ "$(plist_value "$CandidateApp" CFBundleShortVersionString)" == "$ExpectedVersion" ]]
CandidateBuild="$(plist_value "$CandidateApp" CFBundleVersion)"
[[ "$CandidateBuild" =~ ^[0-9]+$ ]]
[[ -z "$ExpectedBuild" || "$CandidateBuild" == "$ExpectedBuild" ]]
[[ -x "$CandidateApp/Contents/MacOS/$Executable" ]]
/usr/bin/lipo -verify_arch "$Architecture" "$CandidateApp/Contents/MacOS/$Executable"
/usr/bin/codesign --verify --deep --strict "$CandidateApp"
/usr/bin/ditto "$CandidateApp" "$StagedApp"
/usr/bin/codesign --verify --deep --strict "$StagedApp"
rm -f -- "$StartupFile"
printf 'ready\n' > "$ReadyFile"

Deadline=$((SECONDS + 120))
while kill -0 "$AppPid" 2>/dev/null && [[ "$SECONDS" -lt "$Deadline" ]]; do
  sleep 0.25
done
! kill -0 "$AppPid" 2>/dev/null
mv -- "$TargetApp" "$BackupApp"
Swapped=1
mv -- "$StagedApp" "$TargetApp"
# Start the real executable so rollback can terminate the exact process we launch.
"$TargetApp/Contents/MacOS/$Executable" >>"$LogFile" 2>&1 &
UpdatedPid=$!
Deadline=$((SECONDS + StartupTimeout))
while [[ ! -f "$StartupFile" && "$SECONDS" -lt "$Deadline" ]]; do
  kill -0 "$UpdatedPid"
  sleep 0.25
done
[[ -f "$StartupFile" ]]
read -r StartupPid < "$StartupFile"
[[ "$StartupPid" == "$UpdatedPid" ]]
sleep 1
kill -0 "$UpdatedPid"
write_result true
Swapped=0
trap - ERR TERM INT
rm -rf -- "$BackupApp" || printf 'Could not remove update backup.\n'
rm -f -- "$DmgPath" || true
printf 'Update installed and startup acknowledged.\n'
''';
}
