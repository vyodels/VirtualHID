#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ENV=(env)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
fi
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-mcp-spm-build}"
"${DEVELOPER_ENV[@]}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-mcp-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-mcp-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-mcp-build.log

node "$ROOT/mcp/server.mjs" --smoke-tools | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["tools"]) == 10; assert all(t.startswith("hid_") for t in d["tools"]); print("mcp-tools OK")'

SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-mcp.XXXXXX").sock"
DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-mcp.XXXXXX").sqlite"
rm -f "$DB"
LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-mcp-daemon.XXXXXX.log")"

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
  echo "mcp-smoke daemon did not create socket: $SOCKET" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

VIRTUALHID_SOCKET="$SOCKET" VIRTUALHID_MCP_FORCE_FALLBACK=1 python3 - "$ROOT/mcp/server.mjs" "$LOG" <<'PY'
import json
import os
import subprocess
import sys

server = sys.argv[1]
daemon_log = sys.argv[2]
proc = subprocess.Popen(
    ["node", server],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)

def fail(message):
    print(message, file=sys.stderr)
    stderr = proc.stderr.read() if proc.poll() is not None else ""
    if stderr:
        print("--- virtualhid MCP stderr ---", file=sys.stderr)
        print(stderr, file=sys.stderr)
    if os.path.exists(daemon_log):
        print("--- vhid-daemon log ---", file=sys.stderr)
        print(open(daemon_log, encoding="utf-8", errors="replace").read(), file=sys.stderr)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    raise SystemExit(1)

def rpc(method, params=None, id=1):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        fail(f"MCP server closed stdout before replying to {method}")
    return json.loads(line)

listed = rpc("tools/list", id=1)
tools = listed["result"]["tools"]
assert len(tools) == 10, tools
assert all(tool["name"].startswith("hid_") for tool in tools), tools

state = rpc("tools/call", {"name": "hid_state", "arguments": {}}, id=2)
if state["result"].get("isError"):
    fail(state["result"]["content"][0]["text"])
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
