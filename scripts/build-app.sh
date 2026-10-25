#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="dist/Anyseek.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift scripts/make-icon.swift "$APP/Contents/Resources"
iconutil -c icns "$APP/Contents/Resources/Anyseek.iconset" -o "$APP/Contents/Resources/Anyseek.icns"
rm -r "$APP/Contents/Resources/Anyseek.iconset"
cp "$BIN_DIR/Anyseek" "$APP/Contents/MacOS/Anyseek"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Anyseek</string>
<key>CFBundleIdentifier</key><string>com.namak1.anyseek</string>
<key>CFBundleName</key><string>Anyseek</string>
<key>CFBundleIconFile</key><string>Anyseek</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
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
# A normal Finder installation: mount, drag the app to Applications, eject.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Anyseek.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install Anyseek.txt" <<'INSTALL'
INSTALL ANYSEEK

1. Drag Anyseek.app onto the Applications folder beside it.
2. Eject the Anyseek disk image.
3. Open Applications and double-click Anyseek.
4. Click Add Folders and select the folders or drives you want to search.

No Terminal, coding tools, or additional software is needed.
Requires macOS 13 or later. Supports Apple Silicon and Intel Macs.

If macOS blocks the first launch:
Open System Settings > Privacy & Security and choose Open Anyway for Anyseek.
This app is ad-hoc signed and has not been notarized by Apple.

Use Control-Option-Space to show Anyseek from any application.
INSTALL
hdiutil create -volname Anyseek -srcfolder "$STAGING" -ov -format UDZO dist/Anyseek.dmg
hdiutil verify dist/Anyseek.dmg
shasum -a 256 dist/Anyseek-macos.zip dist/Anyseek.dmg > dist/SHA256SUMS.txt
