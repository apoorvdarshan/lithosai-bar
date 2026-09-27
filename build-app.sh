#!/bin/zsh
# Builds LithosAIBar.app from the Swift package and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LithosAI Bar"
BUNDLE_ID="cloud.lithosai.bar"
BUILD_DIR=".build/release"
# Assemble in a scratch dir under the repo. This lives outside iCloud now, but a
# dedicated stage keeps the source tree clean and makes the xattr strip reliable.
STAGE_DIR="build"
APP_DIR="${STAGE_DIR}/${APP_NAME}.app"

# Sign with a stable Developer ID so the Full Disk Access grant persists across
# rebuilds. Ad-hoc signing changes the CDHash every build, which silently
# invalidates a user-granted permission.
#
# Override with SIGN_IDENTITY="..." or set SIGN_IDENTITY= to skip signing and
# fall back to ad-hoc. The default is discovered from your keychain, so a clone
# on another machine still builds.
DEFAULT_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" \
    | sed -E 's/.*"(.*)"/\1/')
SIGN_IDENTITY="${SIGN_IDENTITY-$DEFAULT_IDENTITY}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${APP_NAME}.app"
mkdir -p "$STAGE_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/LithosAIBar" "$APP_DIR/Contents/MacOS/LithosAIBar"

# Menu bar artwork and generated app icon.
if [ -d "Resources" ]; then
    cp Resources/*.png "$APP_DIR/Contents/Resources/" 2>/dev/null || true
fi

# Build an .icns from the mark so the app looks intentional in Finder and in the
# Full Disk Access list.
if [ -f "Resources/AppIcon-master.png" ]; then
    ICONSET="${STAGE_DIR}/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -z "$size" "$size" "Resources/AppIcon-master.png" \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        double=$((size * 2))
        sips -z "$double" "$double" "Resources/AppIcon-master.png" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICONSET"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>LithosAIBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Reads your LithosAI console session from the local browser.</string>
</dict>
</plist>
PLIST

echo "==> Signing as: ${SIGN_IDENTITY}"
# Strip extended attributes; Finder info left in the build tree makes codesign
# refuse to verify the bundle.
xattr -cr "$APP_DIR"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # No certificate available: ad-hoc sign. Note that this binds any Full Disk
    # Access grant to the binary hash, so it must be re-granted after rebuilds.
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign --force --deep --options runtime --timestamp \
        --sign "${SIGN_IDENTITY}" "$APP_DIR"
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign -dvv "$APP_DIR" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -4 || true

echo "==> Installing to /Applications"
DEST="/Applications/${APP_NAME}.app"
# Stop the running copy first: replacing the bundle under a live process leaves a
# stale menu bar item behind.
pkill -f "${APP_NAME}.app/Contents/MacOS/LithosAIBar" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
# ditto preserves the signature and avoids re-adding xattrs.
ditto "$APP_DIR" "$DEST"

echo "==> Installed: $DEST"

# Relaunch so the menu bar item is present as soon as the build finishes.
# Skipped when NO_LAUNCH=1, which is useful for scripted builds.
if [ "${NO_LAUNCH:-0}" != "1" ]; then
    echo "==> Launching"
    open "$DEST"
fi

echo
echo "Run it with:  open \"$DEST\""