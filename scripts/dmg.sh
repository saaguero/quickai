#!/bin/bash
# Package build/QuickAI.app into a distributable dist/QuickAI-<version>.dmg.
#
#   VERSION=1.2.3 ./scripts/dmg.sh
#
# Builds a universal (arm64 + x86_64) app first, then a compressed disk image
# with the usual "drag me to Applications" layout, plus a SHA-256 checksum.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
DMG="dist/QuickAI-$VERSION.dmg"
STAGE=build/dmg

VERSION="$VERSION" ./scripts/bundle.sh --universal

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" dist
ditto build/QuickAI.app "$STAGE/QuickAI.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "QuickAI $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"

# sign the image too when a real identity is available (notarization needs it)
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp -s "$CODESIGN_IDENTITY" "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG"
