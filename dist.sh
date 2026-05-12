#!/bin/bash
# Builds Heart.app and zips it for distribution.
# Output: Heart.zip — Apple Silicon (arm64). Intel users can build from source.
# (SwiftTerm pulls in a Metal renderer; cross-arch release builds need the Metal
#  toolchain, which is heavyweight to install for the small Intel audience left.)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Heart"
APP="${APP_NAME}.app"

echo "→ Generating app icon…"
swift scripts/make-icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "→ Building release binary (arm64)…"
swift build -c release --arch arm64

BIN_PATH=".build/arm64-apple-macosx/release/${APP_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
  echo "✗ Build output not found at ${BIN_PATH}"
  exit 1
fi

echo "→ Packaging ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "${BIN_PATH}" "${APP}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP}/Contents/MacOS/${APP_NAME}"
cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Heart</string>
  <key>CFBundleIdentifier</key><string>app.heart.launcher</string>
  <key>CFBundleName</key><string>Heart</string>
  <key>CFBundleDisplayName</key><string>Heart</string>
  <key>CFBundleVersion</key><string>1.5</string>
  <key>CFBundleShortVersionString</key><string>1.5</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>NSCameraUsageDescription</key>
  <string>Heart's built-in browser needs camera access so web pages running locally (e.g. video calls, WebRTC demos) can use navigator.mediaDevices.getUserMedia().</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Heart's built-in browser needs microphone access so web pages running locally (e.g. video calls, voice-input demos) can use navigator.mediaDevices.getUserMedia().</string>
</dict>
</plist>
PLIST

xattr -cr "${APP}" 2>/dev/null || true

# Ad-hoc codesign so Apple Silicon Macs don't reject the bundle as "damaged".
echo "→ Ad-hoc signing…"
codesign --force --deep --sign - "${APP}"

# Bundle a short readme inside the zip for the recipient.
cat > INSTALL.txt <<'TXT'
Heart — Local dev process launcher

INSTALL (3 STEPS):

1) Drag Heart.app into your /Applications folder.

2) Open Terminal and run (IMPORTANT — clears the quarantine flag):

      xattr -cr /Applications/Heart.app

3) Open via Spotlight (⌘+Space) → "heart" → Enter.

WHY STEP 2? Heart is ad-hoc signed (no paid Apple Developer account).
Without it, macOS shows "Heart can't be opened". The command only
clears com.apple.quarantine — completely safe, one-time only.

ALTERNATIVE (without Terminal):
- Finder → right-click /Applications/Heart.app → Open → Open in dialog
- Or: System Settings → Privacy & Security → scroll down →
  "Heart was blocked..." → click "Open Anyway"

OPTIONAL: drag tasks.example.json into Heart's sidebar to import
a sample dev-server config as a folder.

Requires macOS 13+. Apple Silicon (arm64). Intel Mac users — build from source:
  git clone https://github.com/ocracy/heart.git && cd heart && ./install.sh
TXT

echo "→ Creating Heart.zip…"
rm -f Heart.zip
ditto -c -k --keepParent "${APP}" Heart.zip
zip -j Heart.zip INSTALL.txt tasks.example.json >/dev/null
rm INSTALL.txt

ARCHS=$(lipo -archs "${APP}/Contents/MacOS/${APP_NAME}")
SIZE=$(du -h Heart.zip | awk '{print $1}')

echo ""
echo "✓ Distribution ready"
echo "  File:         $(pwd)/Heart.zip ($SIZE)"
echo "  Architecture: ${ARCHS}"
echo "  Includes:     Heart.app, INSTALL.txt, tasks.example.json"
echo ""
echo "  → Send Heart.zip — recipients install per the included INSTALL.txt."
