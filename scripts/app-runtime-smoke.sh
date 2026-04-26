#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/VirtualHID.app"
SOCKET_PATH="${VIRTUALHID_SOCKET:-"$HOME/Library/Application Support/VirtualHID/virtualhid.sock"}"

"$ROOT_DIR/scripts/build-app-bundle.sh" >/dev/null

pkill -f "$APP_PATH/Contents/MacOS/VirtualHID" 2>/dev/null || true
open "$APP_PATH"

python3 - "$SOCKET_PATH" <<'PY'
import json
import socket
import sys
import time

socket_path = sys.argv[1]
deadline = time.time() + 10
last_error = None
while time.time() < deadline:
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2)
        client.connect(socket_path)
        client.sendall(json.dumps({"id": "state", "method": "state", "params": {}}).encode() + b"\n")
        response = json.loads(client.recv(65536).decode())
        client.close()
        if response.get("ok") is True and response.get("result", {}).get("version"):
            sys.exit(0)
        last_error = response
    except Exception as error:
        last_error = error
        time.sleep(0.2)

print(f"app-runtime-smoke failed: {last_error}", file=sys.stderr)
sys.exit(1)
PY

VIRTUALHID_MCP_FORCE_FALLBACK=1 node "$ROOT_DIR/mcp/server.mjs" --smoke-state >/dev/null
echo "app-runtime-smoke OK"
