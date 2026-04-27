#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/VirtualHID.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-swiftpm-cache}" \
    xcrun swift build --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/debug/vhid-tray" "$MACOS_DIR/VirtualHID"
chmod +x "$MACOS_DIR/VirtualHID"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>VirtualHID</string>
  <key>CFBundleIdentifier</key>
  <string>com.vyodels.VirtualHID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VirtualHID</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>VirtualHID local runtime</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>VirtualHID 仅在你开启鼠标习惯学习时监听本机鼠标/键盘事件，用于生成可复用的轨迹、节奏和点击习惯模板。</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>VirtualHID 需要辅助功能权限来监听和执行本机 HID 事件，并提供 HUD 可视化与安全停止能力。</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${VIRTUALHID_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if SIGN_IDENTITY="$("$ROOT_DIR/scripts/ensure-local-codesign-identity.sh" 2>/dev/null)"; then
    :
  else
    SIGN_IDENTITY="-"
    echo "WARN: falling back to ad-hoc signing; macOS privacy permissions may need to be re-granted after rebuilds" >&2
  fi
fi

/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR" >/dev/null

echo "$APP_DIR"
