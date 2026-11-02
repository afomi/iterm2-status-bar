#!/bin/bash
set -euo pipefail

# Usage:
#   bash build-app.sh           # dev build, Apple Development sign (or DEV_IDENTITY), launch
#   bash build-app.sh release   # release build, codesign + notarize
#   LAUNCH=0 bash build-app.sh  # build without launching
#   ARCH=x86_64 bash build-app.sh  # build for another architecture (default: this Mac's)
#   swift test                  # run unit tests
#
# For release, set these env vars (or edit below):
#   TEAM_ID        — your Apple Developer Team ID (10-char string)
#   RELEASE_IDENTITY — signing identity (default: the keychain's Developer ID for TEAM_ID)
#   APPLE_ID       — your Apple ID email
#   APP_PASSWORD   — app-specific password from appleid.apple.com
#
# Find your Team ID: developer.apple.com → Membership details

APP="iTermSidebar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BINARY="$MACOS/iTermSidebar"
ENTITLEMENTS="iTermSidebar.entitlements"
ARCH="${ARCH:-$(uname -m)}"

TEAM_ID="${TEAM_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

MODE="${1:-dev}"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

echo "Compiling ($MODE)..."
# Deployment target (macOS 13) and Swift 6 language mode live in Package.swift.
CONFIG=$([ "$MODE" = "release" ] && echo release || echo debug)
swift build -c "$CONFIG" --arch "$ARCH" --product iTermSidebar
cp "$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/iTermSidebar" "$BINARY"

cp Info.plist "$CONTENTS/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

if [ "$MODE" = "release" ]; then
    if [ -z "$TEAM_ID" ]; then
        echo "ERROR: Set TEAM_ID env var for release builds"
        exit 1
    fi
    IDENTITY="${RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"/\1/p" | head -1 || true)}"
    if [ -z "$IDENTITY" ]; then
        echo "ERROR: No Developer ID identity for team $TEAM_ID. Set RELEASE_IDENTITY."
        exit 1
    fi
    echo "Signing with Hardened Runtime..."
    codesign --sign "$IDENTITY" \
             --entitlements "$ENTITLEMENTS" \
             --options runtime \
             --timestamp \
             --deep \
             --force \
             "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Sign verified."

    if [ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ]; then
        echo "Notarizing (submitting — does not wait)..."
        ZIP="iTermSidebar-notarize.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        SUBMISSION=$(xcrun notarytool submit "$ZIP" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --output-format json)
        SUBMISSION_ID=$(echo "$SUBMISSION" | grep -oE '"id" *: *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        echo "Submitted. ID: $SUBMISSION_ID"
        echo ""
        echo "Apple typically finishes in 2–15 minutes. When ready, run:"
        echo ""
        echo "  xcrun notarytool wait $SUBMISSION_ID --apple-id $APPLE_ID --password <app-password> --team-id $TEAM_ID"
        echo "  xcrun stapler staple $APP"
        echo "  xcrun stapler validate $APP"
        echo ""
        echo "Or check status anytime:"
        echo "  xcrun notarytool info $SUBMISSION_ID --apple-id $APPLE_ID --password <app-password> --team-id $TEAM_ID"
        rm "$ZIP"
    else
        echo "Skipping notarization (APPLE_ID / APP_PASSWORD not set)."
        echo "To notarize: APPLE_ID=you@example.com APP_PASSWORD=xxxx bash build-app.sh release"
    fi
else
    # Ad-hoc signatures pin TCC grants to the cdhash, so every rebuild silently loses
    # Accessibility while System Settings still shows it on. A real identity keeps the grant.
    IDENTITY="${DEV_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1 || true)}"
    codesign --sign "${IDENTITY:--}" --force "$APP"
    codesign --verify --strict "$APP"
    if codesign -d -r- "$APP" 2>&1 | grep -q "cdhash"; then
        echo "WARNING: ad-hoc signed. Each rebuild drops Accessibility; re-grant it after every build."
    else
        echo "Signed (dev build): $IDENTITY"
    fi
fi

echo "Built: $APP"

if [ "${LAUNCH:-1}" = "1" ]; then
    echo "Launching..."
    open "$APP"
fi
