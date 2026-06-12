#!/bin/bash
set -e

APP="iTermSidebar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

echo "Compiling..."
swiftc main.swift \
  -o "$MACOS/iTermSidebar" \
  -framework Cocoa \
  -framework SwiftUI \
  -O

cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.rw.iterm-sidebar</string>
    <key>CFBundleName</key>
    <string>iTermSidebar</string>
    <key>CFBundleExecutable</key>
    <string>iTermSidebar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>iTermSidebar needs to read iTerm2 window titles.</string>
</dict>
</plist>
EOF

echo "Built: $APP"
echo "Launching..."
open "$APP"
