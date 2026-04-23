#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
env DEVELOPER_DIR="$DEVELOPER_DIR" swift build >/tmp/virtualhid-profile-build.log

DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-profile.XXXXXX").sqlite"
rm -f "$DB"
OUTPUT="$("$ROOT/.build/x86_64-apple-macosx/debug/vhid-daemon" --db-path "$DB" --smoke-profile-learn)"

python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["report"]["scannedTraces"] == 10, data
assert data["report"]["generatedTemplates"] >= 1, data
assert data["template"]["sampleSize"] == 10, data
assert data["templatesBeforeForget"] >= 1, data
assert data["templatesAfterForget"] == 0, data
print("profile-learn-smoke OK")
PY
