#!/bin/zsh
# Build, sign, and upload the iPhone app (with its Watch app) to TestFlight.
#
#   scripts/testflight.sh            bump the build number, archive, export, upload
#   scripts/testflight.sh --no-bump  reuse the build number in project.yml
#   scripts/testflight.sh --dry-run  archive and export only, no upload
#
# Needs: xcodegen, the asc CLI (asccli.sh) logged in with `asc auth login`,
# and a signing keychain that holds the distribution identity.
# Override paths with SIGNING_KEYCHAIN, SIGNING_KEYCHAIN_PASSWORD_FILE,
# DEVELOPER_DIR, ASC_PROFILE, and OUT_DIR.
set -euo pipefail

BUMP=1
UPLOAD=1
for arg in "$@"; do
  case "$arg" in
    --no-bump) BUMP=0 ;;
    --dry-run) UPLOAD=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_BUNDLE_ID="com.prateekranka.footballperformance"
TEAM_ID="4JRB53LG5C"
IOS_PROFILE="FootballPerformance b28 iOS Distribution"
WATCH_PROFILE="FootballPerformance b28 Watch Distribution"
KEYCHAIN="${SIGNING_KEYCHAIN:-$HOME/.appstoreconnect/private_keys/FootballPerformance-TestFlight-signing.keychain-db}"
KEYCHAIN_PASSWORD_FILE="${SIGNING_KEYCHAIN_PASSWORD_FILE:-${KEYCHAIN%-db}.password}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

for tool in xcodegen asc xcodebuild security; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[[ -f "$KEYCHAIN" ]] || { echo "signing keychain not found: $KEYCHAIN" >&2; exit 1; }
[[ -f "$KEYCHAIN_PASSWORD_FILE" ]] || { echo "keychain password file not found" >&2; exit 1; }

# Fail early, before a long archive, if asc cannot see the app.
APP_ID="$(asc apps list --bundle-id "$APP_BUNDLE_ID" --output json \
  | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "")')"
[[ -n "$APP_ID" ]] || { echo "asc cannot find $APP_BUNDLE_ID; run: asc auth status" >&2; exit 1; }

current_build() { sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9][0-9]*\).*/\1/p' project.yml | head -1; }

if (( BUMP )); then
  # App Store Connect rejects a reused build number, so go past both sources.
  latest_remote="$(asc builds list --app "$APP_ID" --sort -uploadedDate --limit 1 --output json \
    | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["attributes"]["version"] if d else 0)')"
  local_build="$(current_build)"
  next=$(( (latest_remote > local_build ? latest_remote : local_build) + 1 ))
  sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\) *[0-9][0-9]*/\1 $next/" project.yml
  echo "build number: $next"
fi
BUILD="$(current_build)"

OUT_DIR="${OUT_DIR:-$ROOT/build/testflight/$BUILD}"
ARCHIVE="$OUT_DIR/FootballPerformance-$BUILD.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
mkdir -p "$OUT_DIR"

xcodegen generate --quiet

# The identity lives only in the signing keychain. Add it to the search list
# for this run, and always put the list back and lock it again.
ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/" *$//')}")
restore_keychains() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true
  security lock-keychain "$KEYCHAIN" || true
}
trap restore_keychains EXIT INT TERM
security unlock-keychain -p "$(<"$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"

# Pin the exact identity by hash: a bare "iPhone Distribution" lets export pick
# another distribution certificate from the login keychain.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | awk '/Distribution/ { print $2; exit }')}"
[[ -n "$SIGNING_IDENTITY" ]] || { echo "no distribution identity in $KEYCHAIN" >&2; exit 1; }

echo "archiving build $BUILD"
xcodebuild archive \
  -project FootballPerformance.xcodeproj \
  -scheme FootballPerformance \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  > "$OUT_DIR/archive.log" 2>&1 || { tail -30 "$OUT_DIR/archive.log" >&2; exit 1; }

# Export to a local IPA. Upload is a separate asc step, so xcodebuild needs no
# App Store Connect login.
cat > "$OUT_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$SIGNING_IDENTITY</string>
<key>provisioningProfiles</key><dict>
<key>$APP_BUNDLE_ID</key><string>$IOS_PROFILE</string>
<key>$APP_BUNDLE_ID.watchapp</key><string>$WATCH_PROFILE</string>
</dict>
<key>uploadSymbols</key><true/>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo "exporting IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  > "$OUT_DIR/export.log" 2>&1 || { tail -30 "$OUT_DIR/export.log" >&2; exit 1; }

restore_keychains
trap - EXIT INT TERM

IPA="$(ls "$EXPORT_DIR"/*.ipa | head -1)"
echo "IPA: $IPA"

if (( UPLOAD )); then
  echo "uploading build $BUILD to TestFlight"
  asc builds upload --app "$APP_ID" --ipa "$IPA" --wait --output table
else
  echo "dry run: upload skipped"
fi
