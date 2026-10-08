#!/usr/bin/env bash
# Architecture exclusion, thinning and signing follow Aaalice_NAI_Launcher's
# scripts/build_macos_arch.sh. Plana currently distributes arm64 only.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$#" -ne 0 ]]; then
  echo 'Usage: bash tool/build_macos_arm64.sh (arm64 only)' >&2
  exit 64
fi

release_config="macos/Flutter/Flutter-Release.xcconfig"
app_path="build/macos/Build/Products/Release/Plana App Desktop.app"
config_backup="$(mktemp "${TMPDIR:-/tmp}/plana-macos-config.XXXXXX")"
cp "$release_config" "$config_backup"
restore_config() {
  cp "$config_backup" "$release_config"
  rm -f "$config_backup"
}
trap restore_config EXIT

# Flutter 3.44 forwards EXCLUDED_ARCHS to Xcode and Swift Package Manager.
# Its prebuilt frameworks can still contain both slices, so thin them below.
printf '\n// Set by tool/build_macos_arm64.sh for this build only.\nEXCLUDED_ARCHS = x86_64\n' \
  >> "$release_config"
flutter build macos --release --no-pub

if [[ ! -d "$app_path" ]]; then
  echo "macOS application bundle was not produced: $app_path" >&2
  exit 1
fi

macho_count=0
thinned_count=0
while IFS= read -r -d '' candidate; do
  if ! file -b "$candidate" | grep -q '^Mach-O'; then
    continue
  fi
  macho_count=$((macho_count + 1))
  actual_archs="$(lipo -archs "$candidate")"
  if [[ " $actual_archs " != *" arm64 "* ]]; then
    echo "Missing arm64 slice in $candidate: $actual_archs" >&2
    exit 1
  fi
  if [[ "$actual_archs" != arm64 ]]; then
    temporary_binary="$(mktemp "${candidate}.thin.XXXXXX")"
    lipo "$candidate" -thin arm64 -output "$temporary_binary"
    chmod "$(stat -f '%Lp' "$candidate")" "$temporary_binary"
    mv -f "$temporary_binary" "$candidate"
    thinned_count=$((thinned_count + 1))
  fi
done < <(find "$app_path" -type f -print0)

if [[ "$macho_count" -eq 0 ]]; then
  echo "No Mach-O binaries were found in $app_path" >&2
  exit 1
fi

# Thinning invalidates signatures; preserve bundle identity and entitlements.
codesign --force --deep --sign - \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
  "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
bash tool/verify_macos_arm64.sh "$app_path"
printf 'Prepared %s Mach-O files for arm64 (%s thinned).\n' "$macho_count" "$thinned_count"
