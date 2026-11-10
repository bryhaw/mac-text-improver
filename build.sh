#!/bin/bash
# Builds, signs, and installs "Copilot Proofreader.app" into ~/Applications.
#   ./build.sh            build + install + launch
#   ./build.sh --no-open  build + install only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Copilot Proofreader"
BUNDLE_ID="com.bryhaw.copilot-proofreader"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
VERSION="1.0.0"

# Signing identity: override with SIGN_IDENTITY=... ; "-" means ad-hoc.
# A stable identity keeps the Accessibility permission across rebuilds.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" ]]; then
  echo "error: node not found. Install Node 22+ or set NODE_BIN." >&2
  exit 1
fi
NODE_BIN="$(cd "$(dirname "$NODE_BIN")" && pwd -P)/$(basename "$NODE_BIN")"
NODE_BIN="$(readlink -f "$NODE_BIN" 2>/dev/null || echo "$NODE_BIN")"
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 20 )); then
  echo "error: Node $NODE_MAJOR found at $NODE_BIN; the Copilot SDK needs Node 20+." >&2
  exit 1
fi

echo "› Installing helper dependencies"
(cd "$ROOT/helper" && npm install --omit=dev --no-audit --no-fund --silent)

echo "› Compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  "$ROOT"/app/Sources/*.swift \
  -o "$APP/Contents/MacOS/CopilotProofreader"

echo "› Bundling"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>CopilotProofreader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>ProofreaderNodePath</key><string>$NODE_BIN</string>
</dict>
</plist>
PLIST

# Launch agent registered by the app (Open at Login): starts at login and relaunches after a crash.
# A normal Quit exits with status 0, which KeepAlive/SuccessfulExit=false leaves stopped.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/$BUNDLE_ID.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/CopilotProofreader</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
  <key>EnvironmentVariables</key><dict><key>PROOFREADER_AGENT</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/app/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

mkdir -p "$APP/Contents/Resources/helper"
cp "$ROOT/helper/package.json" "$ROOT"/helper/*.mjs "$APP/Contents/Resources/helper/"
cp -R "$ROOT/helper/node_modules" "$APP/Contents/Resources/helper/"

echo "› Signing ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/MacOS/CopilotProofreader"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo "› Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "✓ Installed $INSTALL_DIR/$APP_NAME.app"
if [[ "${1:-}" != "--no-open" ]]; then
  open "$INSTALL_DIR/$APP_NAME.app"
fi
