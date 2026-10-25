#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "usage: $0 <folder>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
screenshots_dir="${MOMENTS_UI_IMPORT_SCREENSHOTS:-$HOME/Developer/moments-ui-screenshots/import-$timestamp}"
result_root="${TMPDIR:-/tmp}/moments-ui-import"
mkdir -p "$result_root" "$screenshots_dir"
result_bundle="$result_root/MomentsUITests-import-$timestamp.xcresult"

set +e
TEST_RUNNER_MOMENTS_UI_IMPORT_FOLDER="$1" xcodebuild \
  -project "$repo_root/macos/Moments.xcodeproj" \
  -scheme MomentsUITests \
  -destination 'platform=macOS' \
  -only-testing:MomentsUITests/MomentsImportUITests \
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

echo "UI import screenshots: $screenshots_dir"
exit "$test_status"
