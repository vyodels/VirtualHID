#!/usr/bin/env bash
set -euo pipefail

LABEL="com.vyodels.VirtualHIDTray"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "VirtualHID 托盘 LaunchAgent 已移除：$PLIST"
