#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="TrueClose"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
VOL_NAME="${APP_NAME}"
STAGING_DIR="dmg_staging"

if [ ! -d "${APP_BUNDLE}" ]; then
  echo "Error: ${APP_BUNDLE} not found. Run ./build.sh first."
  exit 1
fi

echo "==> 1/3: Preparing staging folder..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
# Symlink to /Applications so the user can drag the app icon onto it.
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> 2/3: Building ${DMG_NAME}..."
rm -f "${DMG_NAME}"
hdiutil create -volname "${VOL_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov -format UDZO \
  "${DMG_NAME}"

echo "==> 3/3: Cleaning up..."
rm -rf "${STAGING_DIR}"

echo ""
echo "DMG created at: $(pwd)/${DMG_NAME}"
echo "Users just need to: open ${DMG_NAME}, then drag ${APP_NAME} onto the Applications icon."
