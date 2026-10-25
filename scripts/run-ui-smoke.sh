#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
screenshots_dir="${MOMENTS_UI_SCREENSHOTS:-$HOME/Developer/moments-ui-screenshots/$timestamp}"
result_root="${TMPDIR:-/tmp}/moments-ui-smoke"
mkdir -p "$result_root" "$screenshots_dir"
result_bundle="$result_root/MomentsUITests-$timestamp.xcresult"

set +e
xcodebuild \
  -project "$repo_root/macos/Moments.xcodeproj" \
  -scheme MomentsUITests \
  -destination 'platform=macOS' \
  -resultBundlePath "$result_bundle" \
  test
test_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$screenshots_dir"
else
  echo "No xcresult bundle was produced; screenshots were not exported." >&2
fi

echo "UI smoke screenshots: $screenshots_dir"
exit "$test_status"
