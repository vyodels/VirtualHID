#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ENV=(env)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
fi
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-analysis-apply-spm-build}"
HISTORY="$(mktemp "${TMPDIR:-/tmp}/virtualhid-analysis-history.XXXXXX.jsonl")"
REPORT="$(mktemp "${TMPDIR:-/tmp}/virtualhid-analysis-report.XXXXXX.json")"
SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-analysis.XXXXXX").sock"
DB="$(mktemp -u "${TMPDIR:-/tmp}/virtualhid-analysis.XXXXXX").sqlite"
LOG="$(mktemp "${TMPDIR:-/tmp}/virtualhid-analysis-daemon.XXXXXX.log")"

cleanup() {
  if [[ -n "${PID:-}" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$HISTORY" "$REPORT" "$SOCKET" "$DB" "$LOG"
}
trap cleanup EXIT

python3 - "$HISTORY" <<'PY'
import json
import sys

path = sys.argv[1]
records = []
for index in range(10):
    records.append({
        "ts": f"2026-04-26T00:00:{index:02d}Z",
        "host": "example.com",
        "elementSig": "sig-apply",
        "taskId": "task",
        "stage": "stage",
        "actionType": "click",
        "instructionKey": "task:stage:sig-apply:click",
        "comparison": {
            "user": {
                "avgSpeedPxS": 280 + index * 3,
                "straightness": 0.82,
                "turnJitter": 0.18,
                "pauses": 1,
                "pointCount": 14,
            },
            "virtual": {
                "avgSpeedPxS": 520,
                "straightness": 0.96,
                "turnJitter": 0.05,
                "pauses": 0,
                "pointCount": 6,
            },
        },
        "replayFingerprint": {
            "quality": 0.82,
            "pathSkeleton": [{"x": 0, "y": 0}, {"x": 40, "y": 16}, {"x": 80, "y": 35}, {"x": 120, "y": 50}],
            "segmentMs": [80, 96, 112],
            "clickHoldMs": [58],
            "hesitationMs": [72],
        },
    })

with open(path, "w", encoding="utf-8") as f:
    for record in records:
        f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
PY

python3 scripts/humanization_analysis.py \
  --history "$HISTORY" \
  --instruction-key "task:stage:sig-apply:click" >"$REPORT"

"${DEVELOPER_ENV[@]}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-analysis-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-analysis-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-analysis-build.log

"$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" \
  --no-event-tap \
  --self-target \
  --allow-self-target-daemon \
  --socket-path "$SOCKET" \
  --db-path "$DB" >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 50); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done
if [[ ! -S "$SOCKET" ]]; then
  echo "analysis-apply-smoke daemon did not create socket" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

python3 - "$SOCKET" "$REPORT" "$LOG" <<'PY'
import json
import os
import socket
import sys

socket_path, report_path, log_path = sys.argv[1:4]

def fail(message):
    print(message, file=sys.stderr)
    if os.path.exists(log_path):
        print(open(log_path, encoding="utf-8", errors="replace").read(), file=sys.stderr)
    raise SystemExit(1)

def rpc(method, params=None, id="smoke"):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(8)
        client.connect(socket_path)
        client.sendall((json.dumps({"id": id, "method": method, "params": params or {}}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                fail(f"daemon closed before replying to {method}")
            data += chunk
    return json.loads(data)

report = json.load(open(report_path, encoding="utf-8"))
proposal = report["groups"][0]["profilePatchProposal"]
assert proposal["applicable"], proposal

applied = rpc("profiles.apply", proposal["params"], id="apply")
assert applied["ok"], applied
assert applied["result"]["template"]["confidence"] >= 0.6, applied

action = rpc("action", {
    "id": "apply-check",
    "context": {"host": "example.com", "taskId": "task", "stage": "stage", "element": {"sig": "sig-apply", "role": "button"}},
    "options": {"dryRun": True},
    "primitives": [{"type": "click", "at": {"x": 120, "y": 88}, "button": "left"}],
}, id="action")
assert action["ok"], action
assert action["result"]["profiles"]["applied"] is True, action
assert action["result"]["profiles"]["templateIds"], action
print("analysis-apply-smoke OK")
PY
