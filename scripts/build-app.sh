#!/bin/sh
# Builds "Prime Cue Recorder.app" and dist/PrimeCueRecorder.dmg, the drag-to-Applications
# installer (needs `uv` for dmgbuild).
#
# VERSION=0.3.0 sets the version (default: the latest git tag, else 0.0.0).
# Set SIGN_ID to a "Developer ID Application" identity to sign for other Macs; without it the
# app is ad-hoc signed and only opens cleanly on this one.
# To notarize the app and the disk image, also set either NOTARY_PROFILE (from
# `xcrun notarytool store-credentials`) or an App Store Connect API key: APPLE_API_KEY_PATH,
# APPLE_API_KEY_ID, APPLE_API_ISSUER.
# RELEASE=1 makes a build that updates itself (Sparkle) and writes dist/appcast.xml, signed with
# ~/.config/prime-cue-recorder/sparkle-ed25519.key (SPARKLE_KEY to override). scripts/release.sh
# sets all of this.
set -eu
cd "$(dirname "$0")/.."

REPO=crosschurch/prime-cue-recorder
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
# Sparkle orders updates by this, so a newer build always wins.
BUILD=$(date +%Y%m%d.%H%M%S)
SPARKLE_KEY="${SPARKLE_KEY:-$HOME/.config/prime-cue-recorder/sparkle-ed25519.key}"
if [ -n "${RELEASE:-}" ] && [ ! -f "$SPARKLE_KEY" ]; then
    echo "no update-signing key at $SPARKLE_KEY (see README › Releasing)"; exit 1
fi

swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

APP="dist/Prime Cue Recorder.app"
rm -rf "$APP" dist/PrimeCueRecorder.zip dist/PrimeCueRecorder.dmg dist/appcast.xml
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/PrimeCueRecorder" "$APP/Contents/MacOS/PrimeCueRecorder"
cp art/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Prime Cue Recorder</string>
    <key>CFBundleDisplayName</key><string>Prime Cue Recorder</string>
    <key>CFBundleIdentifier</key><string>church.cross.PrimeCueRecorder</string>
    <key>CFBundleExecutable</key><string>PrimeCueRecorder</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Prime Cue Recorder talks to ProPresenter on your network to see which slide is showing.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
    <key>SUFeedURL</key><string>https://github.com/$REPO/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>GSzCJrjmcUC/QZ/FntjNquQedCJaJe5sv4Z5kyCS7og=</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST
# Only releases update themselves; UPDATE_FEED points any build at a feed, to test updating.
if [ -n "${UPDATE_FEED:-}" ]; then
    plutil -replace SUFeedURL -string "$UPDATE_FEED" "$APP/Contents/Info.plist"
elif [ -z "${RELEASE:-}" ]; then
    plutil -remove SUFeedURL "$APP/Contents/Info.plist"
fi

# Signed inside out: Sparkle's helpers, Sparkle, then the app (Sparkle's docs for Developer ID apps).
if [ -n "${SIGN_ID:-}" ]; then
    set -- --force --options runtime --timestamp --sign "$SIGN_ID"
else
    set -- --force --sign -
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    [ -e "$SPARKLE/$part" ] || continue
    if [ "$part" = XPCServices/Downloader.xpc ]; then
        codesign "$@" --preserve-metadata=entitlements "$SPARKLE/$part"
    else
        codesign "$@" "$SPARKLE/$part"
    fi
done
codesign "$@" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "$@" "$APP"
echo "Built $APP $VERSION ($BUILD)"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
elif [ -n "${APPLE_API_KEY_PATH:-}" ]; then
    set -- --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
else
    set --
fi
if [ $# -gt 0 ]; then
    ZIP=dist/PrimeCueRecorder.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" "$@" --wait
    xcrun stapler staple "$APP"
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
fi

DMG=dist/PrimeCueRecorder.dmg
uv tool run --from dmgbuild dmgbuild -s scripts/dmg-settings.py -D app="$APP" "Prime Cue Recorder" "$DMG"
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi
if [ $# -gt 0 ]; then
    xcrun notarytool submit "$DMG" "$@" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    echo "Notarized $DMG"
fi
echo "Built $DMG"

# The update feed: this version, signed, downloading from its GitHub release.
if [ -n "${RELEASE:-}" ]; then
    # release-notes/<version>.md is what the update window shows under "What's new". The feed carries
    # the last few versions under "Version x.y.z" headings, newest first, and the app hides the ones
    # already installed (ReleaseNotes.swift), so skipping a version doesn't skip its notes.
    NOTES="release-notes/$VERSION.md"
    [ -f "$NOTES" ] || { echo "write $NOTES first: it's shown in the update window"; exit 1; }
    FEED=$(mktemp -d)
    cp "$DMG" "$FEED/"
    for v in $(ls release-notes | sed 's/\.md$//' | sort -t. -k1,1nr -k2,2nr -k3,3nr); do
        [ "$(printf '%s\n%s\n' "$v" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$VERSION" ] || continue
        printf '### Version %s\n\n' "$v"
        sed "/^## What's new/d" "release-notes/$v.md"
        printf '\n'
    done | awk '/^### Version / { n++ } n <= 8' > "$FEED/PrimeCueRecorder.md"
    .build/artifacts/sparkle/Sparkle/bin/generate_appcast "$FEED" --ed-key-file "$SPARKLE_KEY" \
        --embed-release-notes \
        --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
        --link "https://github.com/$REPO/releases" -o dist/appcast.xml
    rm -rf "$FEED"
    echo "Wrote dist/appcast.xml"
fi
