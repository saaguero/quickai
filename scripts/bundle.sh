#!/bin/bash
# Build QuickAI.app from the SPM executable (release) into build/.
#
#   ./scripts/bundle.sh              arm64 only, fastest, for local testing
#   ./scripts/bundle.sh --universal  arm64 + x86_64 lipo'd together, for releases
#   VERSION=1.2.3 ./scripts/bundle.sh --universal
#
# --universal cross-compiles each slice with -target and lipo's them, so it
# needs only the Command Line Tools (SwiftPM's own --arch needs full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
DEPLOYMENT_TARGET=13.0
UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

# Build one architecture into its own scratch path and echo the binary.
# SwiftPM names the scratch subdirectory after the host, not the target, so
# find the product instead of guessing the path.
build_slice() {
  local arch=$1
  swift build -c release --scratch-path ".build/$arch" \
    -Xswiftc -target -Xswiftc "$arch-apple-macosx$DEPLOYMENT_TARGET" \
    -Xcc -target -Xcc "$arch-apple-macosx$DEPLOYMENT_TARGET" >&2
  find ".build/$arch" -type f -name QuickAI -path '*/release/*' ! -path '*.dSYM*' | head -1
}

APP=build/QuickAI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ $UNIVERSAL -eq 1 ]]; then
  ARM=$(build_slice arm64)
  X86=$(build_slice x86_64)
  lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/QuickAI"
else
  swift build -c release
  cp .build/release/QuickAI "$APP/Contents/MacOS/QuickAI"
fi

# Icon: build .icns from the 512px PNG
ICONSET=build/icon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/QuickAI.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.santiagoaguero.quickai</string>
    <key>CFBundleName</key>
    <string>QuickAI</string>
    <key>CFBundleDisplayName</key>
    <string>QuickAI</string>
    <key>CFBundleExecutable</key>
    <string>QuickAI</string>
    <key>CFBundleIconFile</key>
    <string>QuickAI</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_STAMP}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- plain-http only for local-network LLM servers; note ATS never
             applies to numeric-IP URLs, so LAN IPs work regardless -->
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# stamp the build so the running app can say which bundle it came from
BUILD_STAMP=$(date +%Y%m%d.%H%M%S)
/usr/bin/sed -i '' -e "s/\${BUILD_STAMP}/$BUILD_STAMP/" -e "s/\${VERSION}/$VERSION/" "$APP/Contents/Info.plist"

# CODESIGN_IDENTITY="Developer ID Application: ..." signs for distribution;
# unset means ad-hoc, which is fine locally but triggers Gatekeeper on download
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force -s - "$APP"
else
  codesign --force --deep --options runtime --timestamp -s "$IDENTITY" "$APP"
fi

echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/QuickAI"))"
