#!/bin/bash
# 构建 QuickScreenControl.app（菜单栏应用，LSUIElement，无 Dock 图标、无窗口）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=".build/release/QuickScreenControl"
APP="build/QuickScreenControl.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuickScreenControl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>QuickScreenControl</string>
    <key>CFBundleDisplayName</key><string>屏幕控制</string>
    <key>CFBundleIdentifier</key><string>com.example.QuickScreenControl</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>QuickScreenControl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.example.QuickScreenControl</string>
            <key>CFBundleURLSchemes</key><array><string>quickscreen</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
