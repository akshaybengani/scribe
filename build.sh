#!/bin/bash
# Builds Scribe.app with plain swiftc (no Xcode project) and installs it.
#   ./build.sh              compile, bundle, sign, install to /Applications
#   NO_INSTALL=1 ./build.sh compile and bundle only (prints the .app path)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Stage outside the project so Spotlight never indexes a second copy of the app.
STAGE="$(mktemp -d)"
APP="$STAGE/Scribe.app"
BUNDLE_ID="com.akshaybengani.scribe"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
xcrun swiftc \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Security \
  -o "$APP/Contents/MacOS/Scribe" \
  "$ROOT"/Sources/*.swift

echo "==> Bundling"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Scribe</string>
    <key>CFBundleDisplayName</key>       <string>Scribe</string>
    <key>CFBundleExecutable</key>        <string>Scribe</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Scribe records your voice so it can be transcribed.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps Gatekeeper quiet for a local build.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

if [ "${NO_INSTALL:-0}" = "1" ]; then
  echo "Built: $APP"
  trap - EXIT
  exit 0
fi

echo "==> Installing"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Scribe.app"
cp -R "$APP" "$DEST/Scribe.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Scribe.app" >/dev/null 2>&1 || true
rm -rf "$STAGE"
echo "Installed $DEST/Scribe.app"
