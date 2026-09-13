#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="TrueClose"
BUNDLE_ID="com.trueclose.app"
APP_BUNDLE="${APP_NAME}.app"

echo "==> 1/4: Building (release)..."
swift build -c release

echo "==> 2/4: Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

if [ -d "${APP_NAME}.iconset" ]; then
  echo "==> Building app icon (.icns)..."
  iconutil -c icns "${APP_NAME}.iconset" -o "${APP_BUNDLE}/Contents/Resources/${APP_NAME}.icns"
else
  echo "==> (Skipping icon: ${APP_NAME}.iconset folder not found)"
fi

echo "==> 3/4: Code signing (using local dev certificate)..."
codesign --force --deep --sign "TrueClose Dev Cert" --identifier "${BUNDLE_ID}" "${APP_BUNDLE}"

echo "==> 4/4: Packaging (.dmg and .pkg)..."
./make_dmg.sh
./make_pkg.sh

echo ""
echo "==> Done."
echo ""
echo "App bundle: $(pwd)/${APP_BUNDLE}"
echo "DMG:        $(pwd)/${APP_NAME}.dmg"
echo "PKG:        $(pwd)/${APP_NAME}.pkg"
echo ""
echo "To install locally right now:"
echo "  cp -R ${APP_BUNDLE} /Applications/"
echo "  open /Applications/${APP_BUNDLE}"