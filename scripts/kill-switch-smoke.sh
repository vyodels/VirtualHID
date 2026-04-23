#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
env DEVELOPER_DIR="$DEVELOPER_DIR" swift build >/tmp/virtualhid-kill-build.log

OUTPUT="$("$ROOT/.build/x86_64-apple-macosx/debug/vhid-daemon" --smoke-kill-switch)"
python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["selfMarkedTriggered"] is False, data
assert data["activeAfterRealEsc"] is True, data
assert data["activeAfterUnlock"] is False, data
print("kill-switch-smoke OK")
PY
