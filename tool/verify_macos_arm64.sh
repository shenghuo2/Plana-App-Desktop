#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || ! -d "$1" ]]; then
  echo 'Usage: bash tool/verify_macos_arm64.sh <application bundle>' >&2
  exit 64
fi

verified_count=0
while IFS= read -r -d '' candidate; do
  if ! file -b "$candidate" | grep -q '^Mach-O'; then
    continue
  fi
  verified_count=$((verified_count + 1))
  actual_archs="$(lipo -archs "$candidate")"
  if [[ "$actual_archs" != arm64 ]]; then
    echo "Expected only arm64 in $candidate: $actual_archs" >&2
    exit 1
  fi
done < <(find "$1" -type f -print0)

if [[ "$verified_count" -eq 0 ]]; then
  echo "No Mach-O binaries were found in $1" >&2
  exit 1
fi
printf 'Verified %s Mach-O files as arm64 only.\n' "$verified_count"
