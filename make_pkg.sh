#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="TrueClose"
BUNDLE_ID="com.trueclose.app"
APP_BUNDLE="${APP_NAME}.app"
PKG_NAME="${APP_NAME}.pkg"
ROOT_DIR="pkg_root"
SCRIPTS_DIR="pkg_scripts"

if [ ! -d "${APP_BUNDLE}" ]; then
  echo "Error: ${APP_BUNDLE} not found. Run ./build.sh first."
  exit 1
fi

# Version is read straight from the built app's own Info.plist, so it always matches
# whatever was just built — no separate version number to keep in sync by hand here.
VERSION=$(defaults read "$(pwd)/${APP_BUNDLE}/Contents/Info" CFBundleShortVersionString)

echo "==> 1/4: Preparing package root..."
rm -rf "${ROOT_DIR}"
mkdir -p "${ROOT_DIR}"
cp -R "${APP_BUNDLE}" "${ROOT_DIR}/"

echo "==> 2/4: Writing postinstall script..."
rm -rf "${SCRIPTS_DIR}"
mkdir -p "${SCRIPTS_DIR}"
cat > "${SCRIPTS_DIR}/postinstall" << EOF
#!/bin/bash
# Removes the quarantine flag the installer package (and its contents) get from
# being downloaded off the internet, so the app opens without a Gatekeeper warning
# right after install — the user only has to click through the installer once.
xattr -cr "/Applications/${APP_BUNDLE}"
exit 0
EOF
chmod +x "${SCRIPTS_DIR}/postinstall"

echo "==> 3/4: Building ${PKG_NAME} (version ${VERSION})..."
rm -f "${PKG_NAME}"
pkgbuild \
  --root "${ROOT_DIR}" \
  --install-location /Applications \
  --scripts "${SCRIPTS_DIR}" \
  --identifier "${BUNDLE_ID}.installer" \
  --version "${VERSION}" \
  "${PKG_NAME}"

echo "==> 4/4: Cleaning up..."
rm -rf "${ROOT_DIR}" "${SCRIPTS_DIR}"

echo ""
echo "PKG created at: $(pwd)/${PKG_NAME}"
echo "Users just need to: open ${PKG_NAME} and click through the installer."
echo "(They may need to click 'Open Anyway' once, in System Settings > Privacy & Security,"
echo " the first time they open the .pkg itself — after that, install is fully automatic.)"