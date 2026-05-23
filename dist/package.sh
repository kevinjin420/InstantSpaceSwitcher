#!/bin/bash
set -e

cd "$(dirname "$0")/.."

BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/InstantSpaceSwitcher.app"
ZIP_OUT="${BUILD_DIR}/InstantSpaceSwitcher.zip"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "No app bundle found at ${APP_BUNDLE}. Run ./dist/build.sh first."
    exit 1
fi

echo "Zipping ${APP_BUNDLE}..."
rm -f "${ZIP_OUT}"
cd "${BUILD_DIR}"
zip -r --symlinks InstantSpaceSwitcher.zip InstantSpaceSwitcher.app
cd ..

SHA=$(shasum -a 256 "${ZIP_OUT}" | awk '{print $1}')
echo ""
echo "Done: ${ZIP_OUT}"
echo "SHA256: ${SHA}"
