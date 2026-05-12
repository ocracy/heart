#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Heart"
APP="${APP_NAME}.app"
BIN_PATH=".build/release/${APP_NAME}"

echo "→ Generating app icon…"
swift scripts/make-icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "→ Building ${APP_NAME} (release)…"
swift build -c release

if [ ! -f "${BIN_PATH}" ]; then
  echo "✗ Build failed: ${BIN_PATH} not found"
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

echo "✓ Built $(pwd)/${APP}"
