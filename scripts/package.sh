#!/bin/zsh
# Builds the app and packages it as dist/KeyDimmer-<version>.zip and .dmg, with SHA-256 sums.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${VERSION:-1.0.0}"
NAME="KeyDimmer-$VERSION"
APP="build/KeyDimmer.app"

VERSION="$VERSION" ./scripts/build-app.sh

rm -rf dist
mkdir -p dist

ditto -c -k --keepParent "$APP" "dist/$NAME.zip"

# DMG: the app next to an /Applications link, so installing is a drag.
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/KeyDimmer.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "KeyDimmer" -srcfolder "$STAGE" -fs HFS+ -format UDZO "dist/$NAME.dmg"
rm -rf "$STAGE"

(cd dist && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS)
cat dist/SHA256SUMS
