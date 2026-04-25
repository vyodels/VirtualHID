#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-kill-spm-build}"
env DEVELOPER_DIR="$DEVELOPER_DIR" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-kill-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-kill-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-kill-build.log

OUTPUT="$("$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" --smoke-kill-switch)"
python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["selfMarkedTriggered"] is False, data
assert data["activeAfterRealEsc"] is True, data
assert data["activeAfterUnlock"] is False, data
print("kill-switch-smoke OK")
PY
