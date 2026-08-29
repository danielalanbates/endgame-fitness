#!/bin/bash
#
# Ship Endgame Fitness to TestFlight from THIS Mac (Xcode 26 installed 2026-08-28).
#
# GitHub Actions billing is broken (every job dies in 3s with "payments have
# failed"), so this replaces .github/workflows/testflight.yml until that is
# fixed. It does what the workflow did, locally:
#
#   1. xcodegen generate          -> App/EndgameFitness.xcodeproj
#   2. xcodebuild archive         (manual signing, Apple Distribution cert)
#   3. xcodebuild -exportArchive  -> .ipa (iOS) / signed .pkg (macOS)
#   4. upload via the ASC Build Upload API (scripts/upload_asc.py) — the
#      same path that shipped Descend Watch. Needs the app record to exist.
#
# Usage:
#   scripts/ship.sh ios|macos|both [version] [build]
#
# Env (defaults are the real values for this account):
#   ASC_KEY_ID      32R84GFV2F
#   ASC_ISSUER_ID   67d2d531-0ef2-43f5-8319-7505313c9fd1
#   ASC_KEY_PATH    ~/Library/Application Support/BatesAI/keys/AuthKey_32R84GFV2F.p8
#   ASC_APP_ID      numeric app id (resolved from the bundle id if unset)
#   DEVELOPMENT_TEAM MG4YW8XX2Z
#   SKIP_UPLOAD=1   archive + export only
#
set -euo pipefail

PLATFORM="${1:-ios}"
VERSION="${2:-1.0.0}"
BUILD="${3:-$(date +%Y%m%d%H%M)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/App"
OUT="${SHIP_OUT:-$HOME/Downloads/endgame-fitness-ship}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-MG4YW8XX2Z}"
export ASC_KEY_ID="${ASC_KEY_ID:-32R84GFV2F}"
export ASC_ISSUER_ID="${ASC_ISSUER_ID:-67d2d531-0ef2-43f5-8319-7505313c9fd1}"
export ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/Library/Application Support/BatesAI/keys/AuthKey_32R84GFV2F.p8}"
BUNDLE_ID="org.batesai.endgamefitness"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild not usable. Is /Applications/Xcode.app installed and selected?" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app   (or DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer)" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "==> Generating Xcode project"
(cd "$APP" && xcodegen generate --spec project.yml --quiet)

ship_one() {
  local platform="$1" scheme dest export_plist artifact asc_platform
  if [ "$platform" = "ios" ]; then
    scheme="EndgameFitness-iOS"; dest="generic/platform=iOS"
    export_plist="$APP/ExportOptions-iOS.plist"; asc_platform=IOS
  else
    scheme="EndgameFitness-macOS"; dest="generic/platform=macOS"
    export_plist="$APP/ExportOptions-macOS.plist"; asc_platform=MAC_OS
  fi
  local archive="$OUT/EndgameFitness-$platform.xcarchive"
  local exportdir="$OUT/export-$platform"
  rm -rf "$archive" "$exportdir"

  echo "==> Archiving $scheme ($VERSION / $BUILD)"
  xcodebuild -project "$APP/EndgameFitness.xcodeproj" -scheme "$scheme" \
    -destination "$dest" -configuration Release \
    -archivePath "$archive" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    archive 2>&1 | tee "$OUT/archive-$platform.log" | grep -E "error:|warning: .*deprecated|ARCHIVE|\*\* " || true
  grep -q "ARCHIVE SUCCEEDED" "$OUT/archive-$platform.log"

  echo "==> Exporting $platform"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$export_plist" -exportPath "$exportdir" \
    2>&1 | tee "$OUT/export-$platform.log" | grep -E "error:|EXPORT|\*\* " || true
  grep -q "EXPORT SUCCEEDED" "$OUT/export-$platform.log"

  if [ "$platform" = "ios" ]; then
    artifact="$(ls "$exportdir"/*.ipa | head -1)"
  else
    artifact="$(ls "$exportdir"/*.pkg | head -1)"
  fi
  echo "    artifact: $artifact ($(du -h "$artifact" | cut -f1))"

  if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
    echo "==> SKIP_UPLOAD=1, not uploading"
    return
  fi

  echo "==> Uploading $platform to App Store Connect"
  if [ -z "${ASC_APP_ID:-}" ]; then
    ASC_APP_ID="$(python3 "$ROOT/scripts/asc_app_id.py" "$BUNDLE_ID")" || {
      echo "No App Store Connect app record for $BUNDLE_ID — create it (My Apps -> + -> New App) and retry." >&2
      exit 2
    }
  fi
  APP_ID="$ASC_APP_ID" IPA_PATH="$artifact" PLATFORM="$asc_platform" VER="$VERSION" BUILD="$BUILD" \
    python3 "$ROOT/scripts/upload_asc.py"
}

case "$PLATFORM" in
  ios)   ship_one ios ;;
  macos) ship_one macos ;;
  both)  ship_one ios; ship_one macos ;;
  *) echo "usage: $0 ios|macos|both [version] [build]" >&2; exit 2 ;;
esac
echo "==> Done"
