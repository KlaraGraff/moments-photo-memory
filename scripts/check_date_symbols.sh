#!/usr/bin/env bash
set -euo pipefail

# Fails when a binary in the app bundle imports Foundation's Date.>=
# ($s10Foundation4DateV2geoiySbAC_ACtFZ) or Date.<= ($s10Foundation4DateV2leoiySbAC_ACtFZ).
# Some macOS 27.2 seed builds ship without those two symbols: an app built with
# the 27.2 SDK weak-imports them, its "OS >= 27.2" availability check passes on
# such a seed, and the first comparison jumps to address 0. App code compares
# with `<` only (see macos/Sources/Moments/Design/DateOrder.swift).
#
# Usage: scripts/check_date_symbols.sh <path-to-.app>

readonly symbol_after='$s10Foundation4DateV2geoiySbAC_ACtFZ'
readonly symbol_before='$s10Foundation4DateV2leoiySbAC_ACtFZ'

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-.app>" >&2
  exit 2
fi

app="${1%/}"
if [[ ! -d "$app" ]]; then
  echo "date symbol check: no app bundle at $app" >&2
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
  # `set -e` does not abort inside an `if` condition, so a grep that finds
  # nothing (exit 1) simply means the binary is clean.
  for symbol in "$symbol_after" "$symbol_before"; do
    if imports="$(xcrun nm -u "$binary" 2>/dev/null | grep -F -- "$symbol")"; then
      echo "date symbol check: FAILED" >&2
      echo "  $binary imports $symbol" >&2
      echo "  $imports" >&2
      failed=1
    fi
  done
done

if [[ "$failed" -ne 0 ]]; then
  echo "date symbol check: use Date.isOnOrAfter / Date.isOnOrBefore instead." >&2
  exit 1
fi

echo "date symbol check: OK ($checked binaries)"
