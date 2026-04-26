#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}"
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-browser-live-spm-build}"
WEBROOT="$(mktemp -d "${TMPDIR:-/tmp}/virtualhid-browser-live-web.XXXXXX")"
PORT="$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
URL="http://127.0.0.1:${PORT}/index.html"
SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-browser-live.XXXXXX").sock"
DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-browser-live.XXXXXX").sqlite"
DAEMON_LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-browser-live-daemon.XXXXXX.log")"
HTTP_LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-browser-live-http.XXXXXX.log")"
PREFLIGHT_LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-browser-live-chrome-preflight.XXXXXX.log")"
CHROME_WINDOW_ID=""

cleanup() {
  if [[ -n "$CHROME_WINDOW_ID" ]]; then
    osascript <<OSA >/dev/null 2>&1 || true
tell application id "com.google.Chrome"
  repeat with w in windows
    if (id of w as text) is "$CHROME_WINDOW_ID" then
      close w
      exit repeat
    end if
  end repeat
end tell
OSA
  fi
  if [[ -n "${DAEMON_PID:-}" ]]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [[ -n "${HTTP_PID:-}" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$WEBROOT"
  rm -f "$SOCKET" "$DB" "$DAEMON_LOG" "$HTTP_LOG" "$PREFLIGHT_LOG"
}
trap cleanup EXIT

cat >"$WEBROOT/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>VirtualHID browser target live smoke</title>
<style>
  body { margin: 0; font: 16px sans-serif; }
  main { padding: 32px; min-height: 200vh; }
  button { margin-top: 24px; padding: 12px 18px; }
</style>
<main>
  <h1>VirtualHID browser target live smoke</h1>
  <p>This page is a target identity fixture only. VirtualHID must not read DOM.</p>
  <button>stable target</button>
</main>
HTML

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WEBROOT" >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!
HTTP_READY=0
for _ in $(seq 1 50); do
  if python3 - "$URL" <<'PY' >/dev/null 2>&1; then
import sys
import urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=0.2) as response:
    raise SystemExit(0 if response.status == 200 else 1)
PY
    HTTP_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$HTTP_READY" != "1" ]]; then
  echo "browser-target-live-smoke local HTTP fixture did not start" >&2
  cat "$HTTP_LOG" >&2 || true
  exit 1
fi

env DEVELOPER_DIR="$DEVELOPER_DIR" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-browser-live-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-browser-live-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-browser-live-build.log

BROWSER_INFO="$(osascript <<OSA
tell application id "com.google.Chrome"
  activate
  set targetWindow to make new window
  set URL of active tab of targetWindow to "$URL"
  delay 1.2
  return (id of targetWindow as text) & "|" & (id of active tab of targetWindow as text) & "|" & (URL of active tab of targetWindow as text)
end tell
OSA
)"
IFS='|' read -r CHROME_WINDOW_ID CHROME_TAB_ID CHROME_URL <<<"$BROWSER_INFO"
if [[ -z "$CHROME_WINDOW_ID" || -z "$CHROME_TAB_ID" ]]; then
  echo "browser-target-live-smoke failed to create Chrome target window" >&2
  exit 1
fi
sleep 2

osascript <<'OSA' >"$PREFLIGHT_LOG" 2>&1 || true
tell application id "com.google.Chrome"
  return "windows=" & (count of windows as text)
end tell
OSA
lsappinfo find bundleID=com.google.Chrome >>"$PREFLIGHT_LOG" 2>&1 || true

"$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" \
  --no-event-tap \
  --bundle com.google.Chrome \
  --socket-path "$SOCKET" \
  --db-path "$DB" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 50); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done
if [[ ! -S "$SOCKET" ]]; then
  echo "browser-target-live-smoke daemon did not create socket" >&2
  cat "$DAEMON_LOG" >&2 || true
  exit 1
fi

python3 - "$SOCKET" "$CHROME_WINDOW_ID" "$CHROME_TAB_ID" "$CHROME_URL" "$DAEMON_LOG" "$PREFLIGHT_LOG" <<'PY'
import json
import os
import socket
import sys

socket_path, window_id, tab_id, url, log_path, preflight_path = sys.argv[1:7]

def fail(message):
    print(message, file=sys.stderr)
    if os.path.exists(preflight_path):
        print("--- chrome preflight ---", file=sys.stderr)
        print(open(preflight_path, encoding="utf-8", errors="replace").read(), file=sys.stderr)
    if os.path.exists(log_path):
        print("--- vhid-daemon log ---", file=sys.stderr)
        print(open(log_path, encoding="utf-8", errors="replace").read(), file=sys.stderr)
    raise SystemExit(1)

def rpc(method, params=None, id="smoke"):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(8)
        try:
            client.connect(socket_path)
            client.sendall((json.dumps({"id": id, "method": method, "params": params or {}}) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = client.recv(65536)
                if not chunk:
                    fail(f"daemon closed before replying to {method}")
                data += chunk
        except OSError as error:
            fail(f"rpc {method} failed: {error}")
    return json.loads(data)

target = {
    "bundleId": "com.google.Chrome",
    "windowId": int(window_id),
    "tabId": int(tab_id),
    "host": "127.0.0.1",
}
context = {"host": "127.0.0.1", "taskId": "browser-live-smoke", "element": {"sig": "stable-target", "role": "button"}}

state = rpc("state", id="state")
if not state["ok"]:
    fail(f"state failed: {state}")

action = rpc("action", {
    "id": "browser-live-click-dry-run",
    "target": target,
    "geometry": {"coordSpace": "viewport", "pageScale": 1, "scrollOffset": {"x": 0, "y": 0}},
    "context": context,
    "options": {"dryRun": True, "postMode": "global"},
    "primitives": [{"type": "click", "at": {"x": 32, "y": 32}, "button": "left"}],
}, id="action")
if not action["ok"]:
    fail(f"action failed: {action}; state={state}")
result = action["result"]
target_app = result["targetApp"]
assert target_app["bundleId"] == "com.google.Chrome", target_app
assert target_app["browserWindowId"] == int(window_id), target_app
assert target_app["tabId"] == int(tab_id), target_app
assert target_app["host"] == "127.0.0.1", target_app
assert isinstance(target_app["frontmost"], bool), target_app
assert target_app["viewportFrame"], target_app
assert result["mapping"]["viewportSource"] != "caller-screen-origin", result["mapping"]
assert result["mapping"]["ignoredCallerViewportInScreen"] is False, result["mapping"]
assert result["verification"]["pointerWithinTolerance"] is True, result["verification"]

resample = rpc("action", {
    "id": "browser-live-resample-required",
    "target": target,
    "geometry": {
        "coordSpace": "viewport",
        "pageScale": 1,
        "scrollOffset": {"x": 0, "y": 0},
        "viewportSize": {"x": 0, "y": 0, "width": 80, "height": 80},
    },
    "context": context,
    "options": {"dryRun": True, "postMode": "global"},
    "primitives": [{"type": "click", "at": {"x": 32, "y": 240}, "button": "left"}],
}, id="resample")
assert not resample["ok"], resample
assert resample["error"]["code"] == "E_VIEWPORT_RESAMPLE_REQUIRED", resample

print(json.dumps({
    "status": "ok",
    "url": url,
    "windowId": int(window_id),
    "tabId": int(tab_id),
    "frontmost": target_app["frontmost"],
    "viewportSource": result["mapping"]["viewportSource"],
    "resampleGuard": resample["error"]["code"],
}, ensure_ascii=False, sort_keys=True))
PY

echo "browser-target-live-smoke OK"
