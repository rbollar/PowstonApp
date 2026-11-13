#!/usr/bin/env bash
#
# tf_ship_ios.sh — archive the Powston iPhone app and upload it to TestFlight.
#
# Runs ON THE BUILD BOX against a copy of this repo in ~/powston (see
# docs/testflight.md). Adapted from TrueOffset's Scripts/tf_ship_ios.sh: same box,
# keychain, API key and build lock. Four profiles: the app, its widget, the watch app
# (embedded in the iPhone app) and the watch widgets.
#
# USAGE:
#   Scripts/tf_ship_ios.sh                    # archive, export, upload
#   Scripts/tf_ship_ios.sh --archive-only     # stop after the .xcarchive
#   Scripts/tf_ship_ios.sh --archive <path>   # export and upload an archive built elsewhere
#                                             # (e.g. on the dev Mac with a newer Xcode)
#
# ENVIRONMENT:
#   DEVELOPER_DIR                              a released Xcode (never a beta)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH    App Store Connect API key
#   KEYCHAIN_PW                                password of the build keychain
#   KEYCHAIN                                   default ~/build.keychain-db
#
set -euo pipefail

SCHEME="Powston"
TEAM_ID="J56G3UQQLN"
BUNDLE_ID="com.bollar.Powston"
PROFILE_NAME="Powston iOS AppStore 1.4"   # 1.4 adds the Private Cloud Compute entitlement
WIDGET_ID="com.bollar.Powston.PowstonWidget"
WIDGET_PROFILE="Powston Widget iOS AppStore"
WATCH_ID="com.bollar.Powston.watch"
WATCH_PROFILE="Powston Watch 1.2 iOS AppStore"
WATCH_WIDGET_ID="com.bollar.Powston.watch.PowstonWatchWidget"
WATCH_WIDGET_PROFILE="Powston Watch Widget 1.2 iOS AppStore"
KEYCHAIN="${KEYCHAIN:-$HOME/build.keychain-db}"

DO_UPLOAD=1
PREBUILT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive-only) DO_UPLOAD=0 ;;
    --archive)      PREBUILT="${2:?--archive needs a path}"; shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n== %s\n' "$*"; }
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]] \
  || die "set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH"
[[ -f "$ASC_KEY_PATH" ]] || die "ASC_KEY_PATH not found: $ASC_KEY_PATH"
[[ -n "${KEYCHAIN_PW:-}" ]] || die "set KEYCHAIN_PW"

# The box builds one archive at a time; this is the same lock DeepSix takes
LOCKDIR=/tmp/deepsix_buildbox.lock.d
waited=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  holder_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
    echo "reclaiming stale build-box lock (pid $holder_pid dead)"
    rm -rf "$LOCKDIR"
    continue
  fi
  [[ "$waited" == 0 ]] && echo "BUILD BOX BUSY: $(cat "$LOCKDIR/holder" 2>/dev/null) -- waiting up to 45m"
  sleep 10
  waited=$((waited + 10))
  [[ "$waited" -ge 2700 ]] && die "timed out waiting for the build-box lock"
done
echo $$ > "$LOCKDIR/pid"
echo "Powston iOS | pid $$ | $(date -u '+%Y-%m-%d %H:%M:%SZ')" > "$LOCKDIR/holder"

# Signing needs the build keychain as the default; put the real default back afterward
ORIGINAL_KEYCHAIN="$(security default-keychain 2>/dev/null | sed 's/[" ]//g')"
trap 'rm -rf "$LOCKDIR"; [[ -n "$ORIGINAL_KEYCHAIN" ]] && security default-keychain -s "$ORIGINAL_KEYCHAIN" 2>/dev/null' EXIT

log "Toolchain"
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
case "$DEV_DIR" in
  *CommandLineTools*|"") die "no Xcode selected; set DEVELOPER_DIR to a released Xcode" ;;
  *beta*|*Beta*)         die "beta Xcode ($DEV_DIR); App Store Connect rejects its builds" ;;
esac
xcodebuild -version | tr '\n' ' '
echo "at $DEV_DIR"

security default-keychain -s "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"

WORK="$(mktemp -d /tmp/powston-tf.XXXXXX)"

if [[ -n "$PREBUILT" ]]; then
  ARCHIVE="$PREBUILT"
  [[ -d "$ARCHIVE/Products/Applications/Powston.app" ]] || die "not a Powston archive: $ARCHIVE"
  log "Using archive built elsewhere: $ARCHIVE"
else
  ARCHIVE="$WORK/Powston.xcarchive"
  # The push server's app secret isn't in git. It lives in a root-only file on harriet,
  # copied to ~/powston-secrets/push_secret on the box (mode 600). Write it into this
  # throwaway copy's Info.plist; never print it.
  PUSH_SECRET_FILE="$HOME/powston-secrets/push_secret"
  [[ -s "$PUSH_SECRET_FILE" ]] || die "missing $PUSH_SECRET_FILE (see docs/testflight.md)"
  /usr/libexec/PlistBuddy -c "Delete :PowstonPushSecret" Powston/Info.plist 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :PowstonPushSecret string $(cat "$PUSH_SECRET_FILE")" Powston/Info.plist
  log "Archiving -> $ARCHIVE"
  xcodebuild archive \
    -project Powston.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$WORK/DerivedData" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    >"$WORK/archive.log" 2>&1 || { tail -40 "$WORK/archive.log"; die "archive failed (see $WORK/archive.log)"; }
fi

APP_PLIST="$ARCHIVE/Products/Applications/Powston.app/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
echo "Powston $VERSION ($BUILD), built with Xcode $(/usr/libexec/PlistBuddy -c 'Print :DTXcodeBuild' "$APP_PLIST"), SDK $(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$APP_PLIST")"

# App Store Connect offers no dSYM download, so keep ours for symbolicating crashes
DSYMS="$HOME/dsyms/powston/$VERSION-b$BUILD"
rm -rf "$DSYMS"
mkdir -p "$DSYMS"
cp -R "$ARCHIVE/dSYMs/." "$DSYMS/"
echo "dSYMs kept in $DSYMS"

[[ -d "$ARCHIVE/Products/Applications/Powston.app/Watch/PowstonWatch Watch App.app" ]] || die "the archive has no watch app"

if [[ "$DO_UPLOAD" == 0 ]]; then
  echo "--archive-only: $ARCHIVE"
  exit 0
fi

log "Provisioning profile"
python3 Scripts/asc_profile.py "$BUNDLE_ID" "$PROFILE_NAME" IOS_APP_STORE
python3 Scripts/asc_profile.py "$WIDGET_ID" "$WIDGET_PROFILE" IOS_APP_STORE
python3 Scripts/asc_profile.py "$WATCH_ID" "$WATCH_PROFILE" IOS_APP_STORE
python3 Scripts/asc_profile.py "$WATCH_WIDGET_ID" "$WATCH_WIDGET_PROFILE" IOS_APP_STORE

# Manual signing: the API key can't cloud-sign, so automatic export fails headlessly
cat >"$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string><key>$WIDGET_ID</key><string>$WIDGET_PROFILE</string><key>$WATCH_ID</key><string>$WATCH_PROFILE</string><key>$WATCH_WIDGET_ID</key><string>$WATCH_WIDGET_PROFILE</string></dict>
</dict>
</plist>
PLIST

log "Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$WORK/export" \
  >"$WORK/export.log" 2>&1 || { tail -40 "$WORK/export.log"; die "export failed (see $WORK/export.log)"; }

IPA="$(find "$WORK/export" -maxdepth 1 -type f -name '*.ipa' | head -1)"
[[ -f "$IPA" ]] || die "export produced no .ipa (see $WORK/export.log)"

# xcodebuild -exportArchive copies the watch app as plain files and leaves it signed for
# development (it isn't in DistributionSummary.plist), which App Store Connect refuses
# (90161). Re-sign the watch widgets, the watch app and then the iPhone app, inner first.
profile_path() {
  local f
  for f in "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
    [[ "$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)" == "$1" ]] && { echo "$f"; return; }
  done
  die "profile not installed: $1"
}
setkey() {  # plist, key (may contain dots), type, value
  /usr/libexec/PlistBuddy -c "Delete :$2" "$1" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$2 $3 $4" "$1" >/dev/null
}
resign() {  # bundle, profile name
  local ent="$WORK/ent.plist" prof="$WORK/prof.plist"
  codesign -d --entitlements - --xml "$1" >"$ent" 2>/dev/null
  [[ -s "$ent" ]] || plutil -create xml1 "$ent"   # the watch widgets have no entitlements file
  setkey "$ent" get-task-allow bool false
  setkey "$ent" beta-reports-active bool true
  if [[ -n "${2:-}" ]]; then
    cp "$(profile_path "$2")" "$1/embedded.mobileprovision"
    security cms -D -i "$1/embedded.mobileprovision" >"$prof"
    setkey "$ent" application-identifier string "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$prof")"
    setkey "$ent" com.apple.developer.team-identifier string "$TEAM_ID"
  fi
  codesign -f -s "Apple Distribution" --keychain "$KEYCHAIN" --entitlements "$ent" --generate-entitlement-der "$1" >/dev/null
}
UNZ="$WORK/ipa"
rm -rf "$UNZ"; mkdir -p "$UNZ"
(cd "$UNZ" && unzip -q "$IPA")
WATCH_APP="$UNZ/Payload/Powston.app/Watch/PowstonWatch Watch App.app"
[[ -f "$WATCH_APP/PowstonWatch Watch App" ]] || die "the watch app has no executable"
if [[ "$(security cms -D -i "$WATCH_APP/embedded.mobileprovision" | plutil -extract Name raw -)" != "$WATCH_PROFILE" ]]; then
  log "Re-signing the watch app"
  resign "$WATCH_APP/PlugIns/PowstonWatchWidgetsExtension.appex" "$WATCH_WIDGET_PROFILE"
  resign "$WATCH_APP" "$WATCH_PROFILE"
  resign "$UNZ/Payload/Powston.app"
  codesign --verify --deep --strict "$UNZ/Payload/Powston.app" || die "signature check failed after re-signing"
  rm -f "$IPA"
  (cd "$UNZ" && zip -qry "$IPA" .)
fi

# altool, not xcodebuild's uploader: the latter mints a token Apple answers with 401
log "Uploading $IPA"
mkdir -p "$HOME/.appstoreconnect/private_keys"
cp -f "$ASC_KEY_PATH" "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
  >"$WORK/upload.log" 2>&1 || { tail -30 "$WORK/upload.log"; die "upload failed (see $WORK/upload.log)"; }
tail -3 "$WORK/upload.log"

log "Uploaded Powston $VERSION ($BUILD). It appears in TestFlight once Apple finishes processing."
