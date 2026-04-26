#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${VIRTUALHID_HUD_BUILD_PATH:-/tmp/virtualhid-hud-spm-build}"
RESPONSE="${VIRTUALHID_HUD_RESPONSE:-/tmp/virtualhid-hud-response.json}"
LOG="${VIRTUALHID_HUD_LOG:-/tmp/virtualhid-hud-manual.log}"
SCREENSHOT="${VIRTUALHID_HUD_SCREENSHOT:-/tmp/virtualhid-hud-manual.png}"

rm -f "$RESPONSE" "$LOG" "$SCREENSHOT"

display_state() {
  pmset -g powerstate IODisplayWrangler 2>/dev/null || true
}

DISPLAY_STATE_BEFORE="$(display_state)"
DISPLAY_CURRENT_STATE="$(printf '%s\n' "$DISPLAY_STATE_BEFORE" | awk '/IODisplayWrangler/ { print $2; exit }')"
if [[ "$DISPLAY_CURRENT_STATE" == "0" ]]; then
  echo "hud-manual-ui requires an awake/unlocked macOS display; IODisplayWrangler is Current State 0" >&2
  exit 1
fi

env DEVELOPER_DIR="${DEVELOPER_DIR:-/tmp/OldXcode.app}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-hud-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-hud-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/dev/null

"$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" \
  --smoke-hud-ui >"$RESPONSE" 2>"$LOG" &
HUD_PID=$!
cleanup() {
  kill "$HUD_PID" 2>/dev/null || true
  wait "$HUD_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep "${VIRTUALHID_HUD_CAPTURE_DELAY:-0.9}"
CAPTURE_ERR="$(mktemp /tmp/virtualhid-hud-screencapture.XXXXXX)"
if screencapture -x "$SCREENSHOT" 2>"$CAPTURE_ERR"; then
  rm -f "$CAPTURE_ERR"
else
  CAPTURE_STATUS=$?
  echo "hud-manual-ui failed to capture screenshot" >&2
  echo "screencapture exit code: $CAPTURE_STATUS" >&2
  echo "screencapture stderr:" >&2
  cat "$CAPTURE_ERR" >&2 || true
  echo "display state before capture:" >&2
  printf '%s\n' "$DISPLAY_STATE_BEFORE" >&2
  echo "display state after capture:" >&2
  display_state >&2
  echo "diagnosis: the HUD action path may have run, but screenshot evidence is blocked by the active macOS GUI session, display state, or Screen Recording permission." >&2
  tail -50 "$LOG" >&2 || true
  rm -f "$CAPTURE_ERR"
  exit 1
fi
wait "$HUD_PID"
trap - EXIT

python3 - "$RESPONSE" "$SCREENSHOT" "$LOG" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as f:
    lines = [line.strip() for line in f if line.strip()]
if not lines:
    raise SystemExit("hud-manual-ui daemon produced no response")
response = json.loads(lines[-1])
result = response.get("result", {})
verification = result.get("verification", {})
summary = {
    "ok": response.get("ok"),
    "eventCount": len(result.get("events", [])),
    "expectedPointer": verification.get("expectedPointer"),
    "finalPointer": verification.get("finalPointer"),
    "pointerWithinTolerance": verification.get("pointerWithinTolerance"),
    "screenshot": sys.argv[2],
    "screenshotBytes": os.path.getsize(sys.argv[2]) if os.path.exists(sys.argv[2]) else 0,
    "logTail": open(sys.argv[3]).read().strip().splitlines()[-3:],
}
print(json.dumps(summary, ensure_ascii=False, indent=2))

assert summary["ok"] is True
assert summary["eventCount"] >= 10
assert summary["expectedPointer"] == summary["finalPointer"]
assert summary["pointerWithinTolerance"] is True
assert summary["screenshotBytes"] > 0
PY

echo "hud-manual-ui OK"
