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
# App icon: assets/branding/AppIcon.icns (rebuild it from icon.svg, see assets/README.md).
if [ -f "$ROOT/assets/branding/AppIcon.icns" ]; then
  cp "$ROOT/assets/branding/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "   (assets/branding/AppIcon.icns missing, app will use the generic icon)"
fi
# Fonts (SIL OFL, see assets/fonts): the app registers everything in Contents/Resources/Fonts at launch.
if ls "$ROOT"/assets/fonts/*.ttf >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$ROOT"/assets/fonts/*.ttf "$ROOT"/assets/fonts/*-OFL.txt "$APP/Contents/Resources/Fonts/"
else
  echo "   (assets/fonts missing, app will use the system fonts)"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Scribe</string>
    <key>CFBundleDisplayName</key>       <string>Scribe</string>
    <key>CFBundleExecutable</key>        <string>Scribe</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
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

# Sign with the stable local certificate when it exists, so the designated requirement
# (identifier + certificate leaf hash) is identical across rebuilds and macOS keeps the
# microphone and screen recording grants. Ad-hoc signatures change on every build.
# Create the certificate once: see assets/README.md.
SIGN_IDENTITY="Scribe Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  echo "==> Signing with \"$SIGN_IDENTITY\""
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 \
    || { echo "   (signing with \"$SIGN_IDENTITY\" failed, falling back to ad-hoc)"; \
         codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"; }
else
  echo "==> Signing ad-hoc (no \"$SIGN_IDENTITY\" identity found; permissions will be re-asked after each rebuild)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
fi

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
