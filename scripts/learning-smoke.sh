#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ENV=(env)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
fi
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-learning-spm-build}"
"${DEVELOPER_ENV[@]}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-learning-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-learning-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-learning-build.log

DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-learning.XXXXXX").sqlite"
rm -f "$DB"
OUTPUT="$("$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" --db-path "$DB" --smoke-learning)"

python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["initial"]["ok"], data
assert data["initial"]["result"]["settings"]["enabled"] is False, data
assert data["passiveState"]["ok"], data
assert data["passiveState"]["result"]["settings"]["enabled"] is True, data
assert data["passiveState"]["result"]["settings"]["mode"] == "passive", data
assert data["traceCountGlobal"] == 5, data
assert data["traceCountTraining"] == 5, data
assert data["passiveTemplate"]["sampleSize"] == 5, data
assert data["trainingTemplate"]["sampleSize"] == 5, data
assert data["trainingStop"]["ok"], data
assert data["trainingStop"]["result"]["discardedSamples"] == 0, data
print("learning-smoke OK")
PY
