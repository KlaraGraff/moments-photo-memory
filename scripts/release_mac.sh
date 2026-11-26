#!/usr/bin/env bash
set -euo pipefail

# Builds Moments for installing on another Mac: a Release archive for Apple
# silicon, re-signed with Developer ID, optionally notarized and stapled, and
# zipped. Run it on the owner's Mac; CI never signs.
#
# Usage:
#   scripts/release_mac.sh [--notarize] [--out DIR.noindex] [--dry-run]
#
#   --notarize      send the app to Apple's notary service, wait, and staple
#                   the ticket, so Gatekeeper opens it on a Mac that has never
#                   seen it. Without it the app is signed but not notarized.
#   --out           output folder; must sit inside a *.noindex folder so
#                   Spotlight never indexes build products (default
#                   ~/Moments-Builds.noindex/<version>-<build>).
#   --dry-run       print the commands instead of running them.
#
# A Developer ID app always talks to the Production CloudKit environment and
# production push: Apple's Developer ID profiles allow nothing else, and
# export refuses iCloudContainerEnvironment=Development. Sharing in such a
# build works only once the CloudKit schema is deployed to Production, which
# is one-way and needs the owner's go-ahead. To try sharing against the
# Development environment, use a development-signed build instead
# (MOMENTS_ENTITLEMENTS in Local.xcconfig).
#
# One-time setup on the Mac (none of this is ever committed):
#   1. Xcode › Settings › Accounts: sign in with the Apple developer account.
#   2. In the same pane, Manage Certificates › + › Developer ID Application.
#      If it lists an Apple Development certificate marked "Not in Keychain"
#      (made on a previous install), revoke it so Xcode can make a new one.
#   3. Register this Mac on developer.apple.com › Devices (platform macOS,
#      Device ID = "Provisioning UDID" from System Information › Hardware).
#      The archive is signed with a development profile, which needs at
#      least one registered device; xcodebuild cannot register the Mac it
#      runs on. Apple refuses all of this until the latest Program License
#      Agreement is accepted on developer.apple.com.
#   4. macos/Config/Local.xcconfig (copy Local.xcconfig.example) with
#      DEVELOPMENT_TEAM set, or export MOMENTS_TEAM_ID.
#   5. For --notarize, once:
#        xcrun notarytool store-credentials moments-notary \
#          --apple-id <Apple ID> --team-id <team id>
#      It asks for an app-specific password and keeps it in the login
#      keychain. Override the profile name with MOMENTS_NOTARY_PROFILE.
#
# This script never tags, pushes or publishes anything.

usage() {
  sed -n '8,17p' "$0" | sed 's/^# \{0,1\}//'
}

notarize=0
out=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) notarize=1 ;;
    --out)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      out="$2"; shift ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Developer ID: Production only (see the header).
export_env=Production
aps_env=production

root="$(cd "$(dirname "$0")/.." && pwd)"
macos="$root/macos"
signing="$macos/Config/Signing.xcconfig"
local_config="$macos/Config/Local.xcconfig"

# Last assignment of KEY in an xcconfig, ignoring comments.
xcconfig_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\\([^/[:space:]][^/]*\\).*/\\1/p" "$file" \
    | sed 's/[[:space:]]*$//' | tail -n 1
}

team="${MOMENTS_TEAM_ID:-$(xcconfig_value DEVELOPMENT_TEAM "$local_config")}"
if [[ -z "$team" || "$team" == "YOUR_TEAM_ID" ]]; then
  echo "release: no team. Set DEVELOPMENT_TEAM in macos/Config/Local.xcconfig or export MOMENTS_TEAM_ID." >&2
  exit 1
fi

bundle_id="$(xcconfig_value MOMENTS_BUNDLE_ID "$local_config")"
[[ -n "$bundle_id" ]] || bundle_id="$(xcconfig_value MOMENTS_BUNDLE_ID "$signing")"
container="$(xcconfig_value MOMENTS_ICLOUD_CONTAINER "$local_config")"
[[ -n "$container" ]] || container="$(xcconfig_value MOMENTS_ICLOUD_CONTAINER "$signing")"
case "$bundle_id" in
  ""|org.example.*)
    echo "release: bundle identifier '$bundle_id' is a placeholder; release builds use the final one." >&2
    if [[ -n "$(xcconfig_value MOMENTS_BUNDLE_ID "$local_config")" ]]; then
      echo "release: it comes from macos/Config/Local.xcconfig; delete its MOMENTS_BUNDLE_ID line." >&2
    fi
    exit 1 ;;
esac

version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$macos/project.yml" | head -n 1)"
[[ -n "$version" ]] || { echo "release: no MARKETING_VERSION in macos/project.yml" >&2; exit 1; }
# The build number only ever goes up: it is the number of commits on HEAD,
# which a shallow clone would get wrong.
if [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "release: this clone is shallow; run 'git fetch --unshallow' first so the build number is right." >&2
  [[ $dry_run -eq 1 ]] || exit 1
fi
build="$(git -C "$root" rev-list --count HEAD)"
commit="$(git -C "$root" rev-parse --short HEAD)"

[[ -n "$out" ]] || out="$HOME/Moments-Builds.noindex/$version-$build"
case "/$out/" in
  *.noindex/*) ;;
  *) echo "release: --out must be inside a *.noindex folder (got $out)" >&2; exit 2 ;;
esac

if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
  echo "release: warning: the working tree has uncommitted changes; build $build will not match commit $commit." >&2
fi

run() {
  if [[ $dry_run -eq 1 ]]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

archive="$out/Moments.xcarchive"
export_dir="$out/export"
app="$export_dir/Moments.app"
export_options="$out/ExportOptions.plist"
profile="${MOMENTS_NOTARY_PROFILE:-moments-notary}"

echo "release: Moments $version ($build, $commit), $bundle_id, CloudKit Production, into $out"
mkdir -p "$out"

if [[ $dry_run -eq 0 ]]; then
  xcode_version="$(xcodebuild -version | tr '\n' ' ')"
  echo "release: $xcode_version"
else
  xcode_version="(dry run)"
fi

run xcodegen generate --spec "$macos/project.yml"

# Archive with the development identity; the export below re-signs the app
# with Developer ID and the matching provisioning profile.
run xcodebuild archive \
  -project "$macos/Moments.xcodeproj" \
  -scheme Moments \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$out/DerivedData" \
  -allowProvisioningUpdates \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Automatic "CODE_SIGN_IDENTITY=Apple Development" \
  "DEVELOPMENT_TEAM=$team" \
  "CURRENT_PROJECT_VERSION=$build" \
  MOMENTS_ENTITLEMENTS=Config/Moments.entitlements MOMENTS_HARDENED_RUNTIME=YES \
  "MOMENTS_APS_ENVIRONMENT=$aps_env"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
</dict>
</plist>
PLIST

run rm -rf "$export_dir"
run xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates

# Checks on the exported app: signature, Developer ID, hardened runtime,
# entitlements, Apple silicon only, and the Date symbols that crash on
# some macOS seeds.
run codesign --verify --deep --strict --verbose=2 "$app"
if [[ $dry_run -eq 0 ]]; then
  signature="$(codesign -dvv "$app" 2>&1)"
  grep -q '^Authority=Developer ID Application' <<<"$signature" \
    || { echo "release: the app is not signed with Developer ID" >&2; exit 1; }
  grep -q 'flags=.*runtime' <<<"$signature" \
    || { echo "release: the hardened runtime is off" >&2; exit 1; }
  codesign -d --entitlements - --xml "$app" > "$out/entitlements.plist"
  entitlement() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$out/entitlements.plist" 2>/dev/null || true
  }
  grep -q "<string>$container</string>" "$out/entitlements.plist" \
    || { echo "release: the signed app does not name the container $container" >&2; exit 1; }
  [[ "$(entitlement com.apple.security.personal-information.photos-library)" == "true" ]] \
    || { echo "release: the signed app has no Photos entitlement" >&2; exit 1; }
  # Export re-signs with the Developer ID profile, which may rewrite these;
  # BUILD-INFO records what the signed app actually carries.
  signed_container_env="$(entitlement com.apple.developer.icloud-container-environment)"
  signed_aps_env="$(entitlement com.apple.developer.aps-environment)"
  [[ -n "$signed_aps_env" ]] \
    || { echo "release: the signed app has no push (aps-environment) entitlement" >&2; exit 1; }
  # Without the key a distribution-signed app uses Production.
  if [[ "${signed_container_env:-Production}" != "$export_env" ]]; then
    echo "release: the signed app talks to CloudKit ${signed_container_env:-Production}, expected $export_env" >&2
    exit 1
  fi
  if [[ "$signed_aps_env" != "$aps_env" ]]; then
    echo "release: the signed app uses push environment $signed_aps_env, expected $aps_env" >&2
    exit 1
  fi
  built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [[ "$built_id" == "$bundle_id" ]] \
    || { echo "release: built bundle identifier $built_id, expected $bundle_id" >&2; exit 1; }
fi
run "$root/scripts/check_app_archs.sh" "$app"
run "$root/scripts/check_date_symbols.sh" "$app"

notarized=no
if [[ $notarize -eq 1 ]]; then
  upload="$out/Moments-notarize-upload.zip"
  run ditto -c -k --keepParent "$app" "$upload"
  # On failure, `xcrun notarytool log <submission id> --keychain-profile ...`
  # prints Apple's reasons.
  if [[ $dry_run -eq 1 ]]; then
    run xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json
  else
    # --wait can exit 0 on a rejected upload, so read the status itself.
    submission="$(xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json || true)"
    status="$(plutil -extract status raw -o - - <<<"$submission" 2>/dev/null || true)"
    submission_id="$(plutil -extract id raw -o - - <<<"$submission" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
      echo "release: notarization status '${status:-unknown}' for submission ${submission_id:-?}" >&2
      [[ -z "$submission_id" ]] || xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2 || true
      exit 1
    fi
  fi
  run xcrun stapler staple "$app"
  run xcrun stapler validate "$app"
  run spctl --assess --type execute --verbose=4 "$app"
  run rm -f "$upload"
  notarized=yes
fi

package="$out/Moments-$version-$build.zip"
run ditto -c -k --keepParent "$app" "$package"

if [[ $dry_run -eq 0 ]]; then
  {
    echo "Moments $version ($build)"
    echo "commit: $commit"
    echo "bundle identifier: $bundle_id"
    echo "iCloud container: $container (signed environment: ${signed_container_env:-Production})"
    echo "push environment: $signed_aps_env"
    echo "built with: $xcode_version"
    echo "signed: Developer ID"
    echo "notarized: $notarized"
    echo "architectures: arm64"
    echo "sha256: $(shasum -a 256 "$package" | cut -d' ' -f1)"
  } > "$out/BUILD-INFO.txt"
  cat "$out/BUILD-INFO.txt"
fi
echo "release: done: $package (notarized: $notarized)"
