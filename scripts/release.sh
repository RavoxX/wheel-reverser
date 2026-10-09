#!/bin/bash
# Builds Scroll Reverser, packages it as a DMG with a SHA3-256 checksum file,
# and with --publish uploads both to a GitHub release tagged v<version>.
#
# Usage: scripts/release.sh [--publish]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(xcodebuild -project ScrollReverser.xcodeproj -target ScrollReverser -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
OUT=build.noindex/release
APP="$OUT/DerivedData/Build/Products/Release/Scroll Reverser.app"
DMG="$OUT/ScrollReverser-$VERSION.dmg"

rm -rf "$OUT"
xcodebuild -project ScrollReverser.xcodeproj -scheme ScrollReverser -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$OUT/DerivedData" build -quiet
codesign --verify --deep --strict "$APP"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Scroll Reverser" -srcfolder "$STAGE" -format UDZO -ov "$DMG" -quiet

HASH=$(openssl dgst -sha3-256 -r "$DMG" | cut -d' ' -f1)
echo "$HASH  $(basename "$DMG")" > "$DMG.sha3-256"
echo "$DMG"
echo "SHA3-256: $HASH"

if [[ "${1:-}" == "--publish" ]]; then
    gh release create "v$VERSION" "$DMG" "$DMG.sha3-256" \
        --title "Scroll Reverser $VERSION" \
        --notes "SHA3-256 (\`$(basename "$DMG")\`): \`$HASH\`"
fi
