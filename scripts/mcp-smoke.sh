#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
env DEVELOPER_DIR="$DEVELOPER_DIR" swift build >/tmp/virtualhid-mcp-build.log

node "$ROOT/mcp/server.mjs" --smoke-tools | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["tools"]) == 10; assert all(t.startswith("hid_") for t in d["tools"]); print("mcp-tools OK")'

SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-mcp.XXXXXX.sock")"
DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-mcp.XXXXXX").sqlite"
rm -f "$DB"
LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-mcp-daemon.XXXXXX.log")"

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

VIRTUALHID_SOCKET="$SOCKET" VIRTUALHID_MCP_FORCE_FALLBACK=1 python3 - "$ROOT/mcp/server.mjs" <<'PY'
import json
import os
import subprocess
import sys

server = sys.argv[1]
proc = subprocess.Popen(
    ["node", server],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)

def rpc(method, params=None, id=1):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())

listed = rpc("tools/list", id=1)
tools = listed["result"]["tools"]
assert len(tools) == 10, tools
assert all(tool["name"].startswith("hid_") for tool in tools), tools

state = rpc("tools/call", {"name": "hid_state", "arguments": {}}, id=2)
text = state["result"]["content"][0]["text"]
payload = json.loads(text)
assert payload["post"]["default"] == "global", payload

proc.terminate()
proc.wait(timeout=5)
print("mcp-smoke OK")
PY

rg -n "ActionContext|element\\.sig|profileStore" mcp/ >/tmp/virtualhid-mcp-redline.txt && {
  cat /tmp/virtualhid-mcp-redline.txt
  exit 1
} || true
