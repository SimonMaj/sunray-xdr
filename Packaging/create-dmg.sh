#!/bin/sh
set -eu

APP_BUNDLE="${1:-.build/Sunray XDR.app}"
VERSION="${2:-1.0.0}"
VOLNAME="Sunray XDR"
DMG_NAME="Sunray-XDR-${VERSION}.dmg"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sunray-dmg.XXXXXX")"
RW_DMG="${WORK_DIR}/Sunray-XDR-rw.dmg"
MOUNT_DIR="${WORK_DIR}/mount"
STAGING_DIR="${WORK_DIR}/staging"

cleanup() {
    hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

cd "${ROOT_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}" "${STAGING_DIR}/.background" "${MOUNT_DIR}"

./Packaging/make-dmg-background.swift "${STAGING_DIR}/.background/background.png"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
    -volname "${VOLNAME}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${RW_DMG}" >/dev/null

hdiutil attach "${RW_DMG}" -readwrite -noverify -noautoopen -mountpoint "${MOUNT_DIR}" >/dev/null

osascript <<APPLESCRIPT
tell application "Finder"
    set bgPic to POSIX file "${MOUNT_DIR}/.background/background.png" as alias
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 680, 480}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to bgPic
        set position of item "Sunray XDR.app" of container window to {150, 190}
        set position of item "Applications" of container window to {410, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "${MOUNT_DIR}" -quiet

hdiutil convert "${RW_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DIST_DIR}/${DMG_NAME}" >/dev/null

hdiutil verify "${DIST_DIR}/${DMG_NAME}" >/dev/null
echo "Built ${DIST_DIR}/${DMG_NAME}"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Submitting ${DMG_NAME} for notarization..."
    xcrun notarytool submit "${DIST_DIR}/${DMG_NAME}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"
    xcrun stapler validate "${DIST_DIR}/${DMG_NAME}"
    echo "Notarized ${DIST_DIR}/${DMG_NAME}"
fi
