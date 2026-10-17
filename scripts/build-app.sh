#!/bin/sh
# Builds "Prime Cue Recorder.app" into ./dist.
# Set SIGN_ID to a "Developer ID Application" identity to sign for other Macs;
# without it the app is ad-hoc signed and only opens cleanly on this one.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PrimeCueRecorder

APP="dist/Prime Cue Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PrimeCueRecorder"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Prime Cue Recorder</string>
    <key>CFBundleDisplayName</key><string>Prime Cue Recorder</string>
    <key>CFBundleIdentifier</key><string>church.cross.PrimeCueRecorder</string>
    <key>CFBundleExecutable</key><string>PrimeCueRecorder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Prime Cue Recorder talks to ProPresenter on your network to see which slide is showing.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
