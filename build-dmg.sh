#!/bin/zsh
# Builds a signed, notarized LithosAI Bar.dmg for distribution.
#
# Chain: build-app.sh assembles + Developer-ID signs the .app, this script
# wraps it in a DMG, signs the DMG, submits it to Apple's notary service, and
# staples the ticket so the download opens without a Gatekeeper warning.
#
# Notarization needs an App Store Connect API key. Point at one with:
#   NOTARY_KEY=path/to/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid> ./build-dmg.sh
# or store a profile once and reference it:
#   xcrun notarytool store-credentials lithosai-notary --key ... --key-id ... --issuer ...
#   NOTARY_PROFILE=lithosai-notary ./build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LithosAI Bar"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_DIR=".build/release"
STAGE_DIR="build"
APP_DIR="${STAGE_DIR}/${APP_NAME}.app"
DMG_PATH="${STAGE_DIR}/${APP_NAME} ${APP_VERSION}.dmg"

# Signing identity: same discovery as build-app.sh so a release build is always
# Developer-ID signed rather than ad-hoc.
DEFAULT_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" \
    | sed -E 's/.*"(.*)"/\1/')
SIGN_IDENTITY="${SIGN_IDENTITY-$DEFAULT_IDENTITY}"

if [ -z "$SIGN_IDENTITY" ]; then
    echo "error: no Developer ID identity found; a notarized DMG must be signed." >&2
    exit 1
fi

# Notary credentials: an explicit profile beats an API key triple, matching
# notarytool's own preference.
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    echo "error: set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER." >&2
    exit 1
fi

echo "==> Building app ${APP_VERSION} (Developer ID: ${SIGN_IDENTITY})"
NO_LAUNCH=1 APP_VERSION="$APP_VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" ./build-app.sh

echo "==> Staging DMG contents"
STAGE_DMG="${STAGE_DIR}/dmg-root"
rm -rf "$STAGE_DMG"
mkdir -p "$STAGE_DMG"
# ditto copies the signed bundle without disturbing its signature or xattrs.
ditto "$APP_DIR" "$STAGE_DMG/${APP_NAME}.app"
# The usual drag-to-install affordance.
ln -s /Applications "$STAGE_DMG/Applications"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create -volname "${APP_NAME}" -srcfolder "$STAGE_DMG" \
    -ov -format UDZO "$DMG_PATH" >/dev/null

echo "==> Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

echo
echo "Done: $DMG_PATH"