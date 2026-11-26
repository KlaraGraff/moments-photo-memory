#!/usr/bin/env bash
set -euo pipefail

# Type-checks one Swift module's sources and fails if any of them compares two
# Dates with `>=` or `<=` (see scripts/check_date_operators.py for why the
# binary check alone misses this on CI's older SDK).
#
# Usage: scripts/check_date_operators.sh <module-name> <sources-dir> [swiftc args...]
#   Linux:  scripts/check_date_operators.sh MomentsCore macos/MomentsCore/Sources/MomentsCore
#   macOS:  scripts/check_date_operators.sh Moments macos/Sources/Moments \
#             -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macos14.0 \
#             -I macos/.derivedData/Build/Products/Debug

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <module-name> <sources-dir> [swiftc args...]" >&2
  exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
module="$1"
sources="$2"
shift 2

python3 "$here/check_date_operators.py" --self-test

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(find "$sources" -name '*.swift' -print | sort)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "date operator check: no Swift files in $sources" >&2
  exit 2
fi

dump="$(mktemp)"
trap 'rm -f "$dump"' EXIT
# Swift writes the dump to stdout or stderr depending on the version.
if ! swiftc -dump-ast -parse-as-library -module-name "$module" "$@" "${files[@]}" >"$dump" 2>&1; then
  grep -E 'error:' "$dump" | head -40 >&2 || true
  echo "date operator check: swiftc -dump-ast failed for $module" >&2
  exit 1
fi
python3 "$here/check_date_operators.py" "$dump"
