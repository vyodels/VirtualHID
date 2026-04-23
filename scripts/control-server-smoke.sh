#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
env DEVELOPER_DIR="$DEVELOPER_DIR" swift build >/tmp/virtualhid-control-build.log

SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-smoke.XXXXXX.sock")"
DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-smoke.XXXXXX").sqlite"
rm -f "$DB"
LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-daemon.XXXXXX.log")"

"$ROOT/.build/x86_64-apple-macosx/debug/vhid-daemon" \
  --no-event-tap \
  --self-target \
  --socket-path "$SOCKET" \
  --db-path "$DB" >"$LOG" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -f "$SOCKET" "$DB" "$LOG"' EXIT

for _ in $(seq 1 50); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done
[[ -S "$SOCKET" ]]

python3 - "$SOCKET" <<'PY'
import json
import socket
import sys

socket_path = sys.argv[1]

def call(method, params=None, id="1"):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall((json.dumps({"id": id, "method": method, "params": params or {}}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            data += client.recv(65536)
    return json.loads(data)

state = call("state", id="state")
assert state["ok"], state
assert state["result"]["post"]["default"] == "global", state
assert state["result"]["post"]["available"] == ["global", "pid", "auto"], state

missing = call("action", {"id": "missing", "primitives": [{"type": "move", "to": {"x": 1, "y": 1}, "via": "linear"}]}, id="missing")
assert not missing["ok"] and missing["error"]["code"] == "E_CONTEXT_REQUIRED", missing

pid_click = call("action", {
    "id": "pid-click",
    "primitives": [{"type": "click", "at": {"x": 1, "y": 1}}],
    "context": {"host": "test", "element": {"sig": "sig"}},
    "options": {"postMode": "pid", "dryRun": True}
}, id="pid-click")
assert not pid_click["ok"] and pid_click["error"]["code"] == "E_POST_MODE_UNSUPPORTED", pid_click

move = call("action", {
    "id": "move",
    "primitives": [{"type": "move", "to": {"x": 2, "y": 2}, "via": "linear"}],
    "context": {"host": "test", "element": {"sig": "sig"}},
    "options": {"postMode": "global", "dryRun": True}
}, id="move")
assert move["ok"], move
assert move["result"]["post"]["used"] == "global", move

state2 = call("state", id="state2")
assert state2["result"]["post"]["lastUsed"] == "global", state2
print("control-server-smoke OK")
PY
