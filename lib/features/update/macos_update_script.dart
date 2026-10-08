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
    int shutdownTimeout = 120,
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
      'SHUTDOWN_TIMEOUT': shutdownTimeout.toString(),
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
ShutdownTimeout=@@SHUTDOWN_TIMEOUT@@
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

# macOS ships Bash 3.2, whose errexit/ERR handling can ignore failed [[ ]]
# checks containing command substitutions. Reject invalid inputs explicitly.
[[ "$AppPid" -gt 0 && "$TargetApp" == *.app ]] || fail 1
[[ "$TargetApp" != /Volumes/* && "$TargetApp" != *'/AppTranslocation/'* ]] || fail 1
TargetParent="$(dirname "$TargetApp")"
[[ -d "$TargetApp" && -w "$TargetParent" ]] || fail 1
[[ "$(dirname "$StagedApp")" == "$TargetParent" && ! -e "$StagedApp" ]] || fail 1
[[ "$(dirname "$BackupApp")" == "$TargetParent" && ! -e "$BackupApp" ]] || fail 1
mkdir -p -- "$MountDir"
/usr/bin/hdiutil attach "$DmgPath" -readonly -nobrowse -mountpoint "$MountDir"
Mounted=1
CandidateApp="$MountDir/Plana App Desktop.app"
if [[ ! -d "$CandidateApp" ]]; then
  CandidateApp="$MountDir/Plana App.app"
fi
[[ -d "$CandidateApp" ]] || fail 1
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
CurrentId="$(plist_value "$TargetApp" CFBundleIdentifier)" || fail 1
Executable="$(plist_value "$TargetApp" CFBundleExecutable)" || fail 1
CandidateId="$(plist_value "$CandidateApp" CFBundleIdentifier)" || fail 1
CandidateExecutable="$(plist_value "$CandidateApp" CFBundleExecutable)" || fail 1
CandidateVersion="$(plist_value "$CandidateApp" CFBundleShortVersionString)" || fail 1
CandidateBuild="$(plist_value "$CandidateApp" CFBundleVersion)" || fail 1
if [[ -z "$CurrentId" || -z "$Executable" || "$Executable" == */* || \
      "$CandidateId" != "$CurrentId" || \
      "$CandidateExecutable" != "$Executable" || \
      "$CandidateVersion" != "$ExpectedVersion" || \
      ( -n "$ExpectedBuild" && "$CandidateBuild" != "$ExpectedBuild" ) ]] || \
   [[ ! "$CandidateBuild" =~ ^[0-9]+$ ]]; then
  printf 'Update application identity or version does not match the installed app.\n'
  fail 1
fi
[[ -x "$CandidateApp/Contents/MacOS/$Executable" ]] || fail 1
/usr/bin/lipo "$CandidateApp/Contents/MacOS/$Executable" -verify_arch "$Architecture"
/usr/bin/codesign --verify --deep --strict "$CandidateApp"
/usr/bin/ditto "$CandidateApp" "$StagedApp"
/usr/bin/codesign --verify --deep --strict "$StagedApp"
rm -f -- "$StartupFile"
printf 'ready\n' > "$ReadyFile"

Deadline=$((SECONDS + ShutdownTimeout))
while kill -0 "$AppPid" 2>/dev/null && [[ "$SECONDS" -lt "$Deadline" ]]; do
  sleep 0.25
done
if kill -0 "$AppPid" 2>/dev/null; then
  printf 'Application process %s did not exit within %s seconds.\n' "$AppPid" "$ShutdownTimeout"
  fail 1
fi
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
[[ -f "$StartupFile" ]] || fail 1
read -r StartupPid < "$StartupFile"
[[ "$StartupPid" == "$UpdatedPid" ]] || fail 1
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
