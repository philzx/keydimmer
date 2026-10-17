#!/bin/zsh
# Builds build/KeyDimmer.app (Apple Silicon, ad-hoc signed unless SIGN_IDENTITY is set).
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP="build/KeyDimmer.app"

swift build -c release --arch arm64 --product KeyDimmer
BIN="$(swift build -c release --arch arm64 --show-bin-path)/KeyDimmer"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KeyDimmer"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"
