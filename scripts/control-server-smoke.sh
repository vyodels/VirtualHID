#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ENV=(env)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
fi
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-control-spm-build}"
"${DEVELOPER_ENV[@]}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-control-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-control-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-control-build.log

GUARD_LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-self-target-guard.XXXXXX.log")"
if "$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" --no-event-tap --self-target >"$GUARD_LOG" 2>&1; then
  echo "control-server-smoke expected --self-target daemon launch to fail without explicit override" >&2
  cat "$GUARD_LOG" >&2 || true
  rm -f "$GUARD_LOG"
  exit 1
fi
grep -q -- "--self-target is only for VirtualHID smoke/self-test" "$GUARD_LOG" || {
  echo "control-server-smoke missing self-target guard error" >&2
  cat "$GUARD_LOG" >&2 || true
  rm -f "$GUARD_LOG"
  exit 1
}
rm -f "$GUARD_LOG"

SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-smoke.XXXXXX").sock"
DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-smoke.XXXXXX").sqlite"
rm -f "$DB"
LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-daemon.XXXXXX.log")"

"$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" \
  --no-event-tap \
  --self-target \
  --allow-self-target-daemon \
  --socket-path "$SOCKET" \
  --db-path "$DB" >"$LOG" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -f "$SOCKET" "$DB" "$LOG"' EXIT

for _ in $(seq 1 50); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done
if [[ ! -S "$SOCKET" ]]; then
  echo "control-server-smoke daemon did not create socket: $SOCKET" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

python3 - "$SOCKET" "$LOG" <<'PY'
import json
import os
import socket
import sys

socket_path = sys.argv[1]
log_path = sys.argv[2]

def fail(message):
    print(message, file=sys.stderr)
    if os.path.exists(log_path):
        print("--- vhid-daemon log ---", file=sys.stderr)
        print(open(log_path, encoding="utf-8", errors="replace").read(), file=sys.stderr)
    raise SystemExit(1)

def call(method, params=None, id="1"):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        try:
            client.connect(socket_path)
        except OSError as error:
            fail(f"failed to connect to {socket_path}: {error}")
        client.sendall((json.dumps({"id": id, "method": method, "params": params or {}}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                fail(f"daemon closed connection before replying to {method}")
            data += chunk
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
