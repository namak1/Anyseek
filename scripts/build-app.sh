#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="dist/Anyseek.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Anyseek" "$APP/Contents/MacOS/Anyseek"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Anyseek</string>
<key>CFBundleIdentifier</key><string>com.namak1.anyseek</string>
<key>CFBundleName</key><string>Anyseek</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
lipo "$APP/Contents/MacOS/Anyseek" -verify_arch arm64 x86_64
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Anyseek-macos.zip

codesign --verify --deep --strict "$APP"
shasum -a 256 dist/Anyseek-macos.zip > dist/SHA256SUMS.txt
