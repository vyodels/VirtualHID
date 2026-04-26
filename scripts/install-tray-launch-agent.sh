#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.vyodels.VirtualHIDTray"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOCKET_PATH="${VIRTUALHID_SOCKET:-/tmp/virtualhid.sock}"
LOG_DIR="$HOME/Library/Logs/VirtualHID"
UID_VALUE="$(id -u)"

cd "$ROOT_DIR"
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-swiftpm-cache}" \
    xcrun swift build --disable-sandbox

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOT_DIR/.build/debug/vhid-tray</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VIRTUALHID_SOCKET</key>
    <string>$SOCKET_PATH</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/tray.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/tray.err.log</string>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
launchctl enable "gui/$UID_VALUE/$LABEL"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

echo "VirtualHID 托盘已安装并启动：$PLIST"
echo "Socket: $SOCKET_PATH"
