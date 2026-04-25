#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-observer-spm-build}"
env DEVELOPER_DIR="$DEVELOPER_DIR" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-observer-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-observer-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-observer-build.log

DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-observer.XXXXXX").sqlite"
rm -f "$DB"
OUTPUT="$("$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" --db-path "$DB" --smoke-observer)"

python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["tail"]["ok"], data
assert len(data["tail"]["result"]["events"]) >= 1, data
assert data["commit"]["ok"] and data["commit"]["result"]["committed"], data
assert data["password"]["ok"] and data["password"]["result"]["dropped"], data
assert data["traceCount"] == 1, data
print("observer-smoke OK")
PY
