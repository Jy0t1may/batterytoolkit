#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$DIR/build"
APP_DIR="$BUILD_DIR/BatteryToolkit.app"
SWIFT_TARGET="arm64-apple-macos14.0"
CACHE_PATH="/tmp/ModuleCache"

mkdir -p "$BUILD_DIR"
mkdir -p "$CACHE_PATH"

echo "=========================================================="
echo " Building BatteryToolkit for macOS Sequoia & macOS 27"
echo "=========================================================="

# 1. Compile CLI Tool
echo "--> Compiling batterytoolkit-cli..."
swiftc -target "$SWIFT_TARGET" \
    -module-cache-path "$CACHE_PATH" \
    -framework Foundation -framework IOKit -framework ServiceManagement \
    "$DIR/src/Common/BatteryState.swift" \
    "$DIR/src/Common/PowerUIClient.swift" \
    "$DIR/src/Common/SMCProtocols.swift" \
    "$DIR/src/Helper/HelperManager.swift" \
    "$DIR/src/SMC/SMCKeys.swift" \
    "$DIR/src/SMC/SMCKit.swift" \
    "$DIR/src/Core/SleepManager.swift" \
    "$DIR/src/Core/PowerMonitor.swift" \
    "$DIR/src/Core/SailingManager.swift" \
    "$DIR/src/CLI/main_cli.swift" \
    -o "$BUILD_DIR/batterytoolkit-cli"

# 2. Compile Privileged Helper Daemon
echo "--> Compiling batterytoolkit-helper..."
swiftc -target "$SWIFT_TARGET" \
    -module-cache-path "$CACHE_PATH" \
    -framework Foundation -framework IOKit -framework ServiceManagement \
    "$DIR/src/Common/BatteryState.swift" \
    "$DIR/src/Common/PowerUIClient.swift" \
    "$DIR/src/Common/SMCProtocols.swift" \
    "$DIR/src/Helper/HelperManager.swift" \
    "$DIR/src/SMC/SMCKeys.swift" \
    "$DIR/src/SMC/SMCKit.swift" \
    "$DIR/src/Helper/BatteryHelper.swift" \
    "$DIR/src/Helper/main_helper.swift" \
    -o "$BUILD_DIR/batterytoolkit-helper"

# 3. Compile GUI App
echo "--> Compiling BatteryToolkit Menu Bar App..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Library/LaunchServices"

swiftc -target "$SWIFT_TARGET" \
    -module-cache-path "$CACHE_PATH" \
    -framework AppKit -framework SwiftUI -framework Foundation -framework IOKit -framework ServiceManagement \
    "$DIR/src/Common/BatteryState.swift" \
    "$DIR/src/Common/PowerUIClient.swift" \
    "$DIR/src/Common/SMCProtocols.swift" \
    "$DIR/src/Helper/HelperManager.swift" \
    "$DIR/src/SMC/SMCKeys.swift" \
    "$DIR/src/SMC/SMCKit.swift" \
    "$DIR/src/Core/SleepManager.swift" \
    "$DIR/src/Core/PowerMonitor.swift" \
    "$DIR/src/Core/SailingManager.swift" \
    "$DIR/src/UI/DashboardView.swift" \
    "$DIR/src/UI/StatusItemController.swift" \
    "$DIR/src/UI/AppDelegate.swift" \
    -o "$APP_DIR/Contents/MacOS/BatteryToolkit"

# Copy helper into app bundle
cp "$BUILD_DIR/batterytoolkit-helper" "$APP_DIR/Contents/Library/LaunchServices/me.batterytoolkit.helper"

# Generate Info.plist
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BatteryToolkit</string>
    <key>CFBundleIdentifier</key>
    <string>me.batterytoolkit.app</string>
    <key>CFBundleName</key>
    <string>BatteryToolkit</string>
    <key>CFBundleDisplayName</key>
    <string>BatteryToolkit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "=========================================================="
echo " BUILD SUCCESSFUL!"
echo " App Bundle   : $APP_DIR"
echo " CLI Utility  : $BUILD_DIR/batterytoolkit-cli"
echo " Helper Daemon: $BUILD_DIR/batterytoolkit-helper"
echo "=========================================================="
