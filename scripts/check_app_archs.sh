#!/usr/bin/env bash
set -euo pipefail

# Fails when an app bundle holds a binary that is not arm64 only. The app
# ships for Apple silicon only; an Intel slice anywhere in the bundle would
# mean the ARCHS setting in macos/project.yml did not take effect.
#
# Every Mach-O file the bundle can load is checked: the executables in
# Contents/MacOS, any dylib, and the binary inside every framework.
#
# Usage: scripts/check_app_archs.sh <path-to-.app>

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-.app>" >&2
  exit 2
fi

app="${1%/}"
if [[ ! -d "$app" ]]; then
  echo "arch check: no app bundle at $app" >&2
  exit 2
fi

# Every Mach-O file the bundle can load: the executables in Contents/MacOS,
# any dylib, and the binary inside every framework (versioned or flat).
collect_binaries() {
  local candidate framework name
  if [[ -d "$app/Contents/MacOS" ]]; then
    find "$app/Contents/MacOS" -maxdepth 1 -type f -print
  fi
  find "$app" -type f -name '*.dylib' -print
  # A framework binary is either flat (<X.framework>/<X>) or versioned
  # (<X.framework>/Versions/<version>/<X>). Versions/Current is a symlink to
  # one of those, so it is skipped and every binary is counted once.
  while IFS= read -r framework; do
    name="$(basename "$framework" .framework)"
    for candidate in "$framework/$name" "$framework"/Versions/*/"$name"; do
      if [[ -f "$candidate" && ! -L "$candidate" ]]; then
        printf '%s\n' "$candidate"
      fi
    done
  done < <(find "$app" -type d -name '*.framework' -print)
}

binaries=()
while IFS= read -r file; do
  binaries+=("$file")
done < <(collect_binaries | sort -u)

failed=0
checked=0
# `${binaries[@]+...}` keeps `set -u` quiet on macOS's bash 3.2 when the
# bundle holds no binary at all.
for binary in ${binaries[@]+"${binaries[@]}"}; do
  kind="$(file -b "$binary" 2>/dev/null || true)"
  case "$kind" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
  # A lipo that cannot read the file leaves archs empty, which fails the
  # comparison below rather than passing silently.
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  if [[ "$archs" != "arm64" ]]; then
    echo "arch check: $binary has $archs, expected arm64 only" >&2
    failed=1
  fi
done

if [[ "$checked" -eq 0 ]]; then
  echo "arch check: no Mach-O binary in $app" >&2
  exit 1
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "arch check: $checked binaries, all arm64 only"
