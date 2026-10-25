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
# One build folder per checkout, so worktrees never share a runner bundle.
derived_data="${MOMENTS_UI_DERIVED_DATA:-$result_root/DerivedData-$(printf %s "$repo_root" | shasum | cut -c1-8)}"

# UI tests launch a signed runner; Config/Local.xcconfig (gitignored) holds
# the signing team. See Config/Local.xcconfig.example.
if [[ ! -f "$repo_root/macos/Config/Local.xcconfig" ]]; then
  echo "Missing macos/Config/Local.xcconfig: copy Config/Local.xcconfig.example and set your team, or copy it from your main checkout." >&2
  exit 2
fi

set +e
TEST_RUNNER_MOMENTS_UI_IMPORT_FOLDER="$1" xcodebuild \
  -project "$repo_root/macos/Moments.xcodeproj" \
  -scheme MomentsUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
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
