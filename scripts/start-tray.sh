#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET_PATH="${VIRTUALHID_SOCKET:-/tmp/virtualhid.sock}"

cd "$ROOT_DIR"
export VIRTUALHID_SOCKET="$SOCKET_PATH"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-swiftpm-cache}" \
    xcrun swift build --disable-sandbox

exec "$ROOT_DIR/.build/debug/vhid-tray"
