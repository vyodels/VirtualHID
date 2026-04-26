#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_PATH="${VIRTUALHID_LEARNING_PLAYBACK_BUILD_PATH:-/tmp/virtualhid-learning-playback-spm-build}"
RESPONSE="${VIRTUALHID_LEARNING_PLAYBACK_RESPONSE:-/tmp/virtualhid-learning-playback-response.jsonl}"
LOG="${VIRTUALHID_LEARNING_PLAYBACK_LOG:-/tmp/virtualhid-learning-playback.log}"

rm -f "$RESPONSE" "$LOG"

display_state() {
  pmset -g powerstate IODisplayWrangler 2>/dev/null || true
}

DISPLAY_STATE="$(display_state)"
if printf '%s\n' "$DISPLAY_STATE" | awk '/IODisplayWrangler/ { exit ($2 == 0 ? 0 : 1) }'; then
  echo "learning-playback-demo requires an awake/unlocked macOS display; IODisplayWrangler is Current State 0" >&2
  exit 1
fi

DEVELOPER_ENV=(env)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
fi

"${DEVELOPER_ENV[@]}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-learning-playback-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-learning-playback-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-learning-playback-build.log

DAEMON="$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon"
VIRTUALHID_LEARNING_PLAYBACK_ACTIONS="${VIRTUALHID_LEARNING_PLAYBACK_ACTIONS:-5}" \
VIRTUALHID_LEARNING_PLAYBACK_ACTION_DELAY_SECONDS="${VIRTUALHID_LEARNING_PLAYBACK_ACTION_DELAY_SECONDS:-0.45}" \
VIRTUALHID_LEARNING_PLAYBACK_STEP_DELAY_SECONDS="${VIRTUALHID_LEARNING_PLAYBACK_STEP_DELAY_SECONDS:-1.45}" \
VIRTUALHID_LEARNING_PLAYBACK_EXIT_DELAY_SECONDS="${VIRTUALHID_LEARNING_PLAYBACK_EXIT_DELAY_SECONDS:-4.2}" \
"$DAEMON" \
  --self-target \
  --allow-self-target-daemon \
  --smoke-learning-playback \
  --hud-show all \
  --hud-clear-delay "${VIRTUALHID_LEARNING_PLAYBACK_HUD_CLEAR_DELAY:-8}" \
  >"$RESPONSE" 2>"$LOG"

python3 - "$RESPONSE" "$LOG" <<'PY'
import json
import sys

response_path, log_path = sys.argv[1], sys.argv[2]
with open(response_path) as f:
    payloads = [json.loads(line) for line in f if line.strip()]
if not payloads:
    raise SystemExit("learning playback produced no response")

summary = next((item for item in reversed(payloads) if item.get("type") == "learning-playback-summary"), None)
if summary is None:
    raise SystemExit("learning playback did not produce summary")

assert summary["ok"] is True, summary
assert summary["source"] == "virtualhid-action-events", summary
assert summary["training"]["generatedTemplates"] >= 1, summary
assert summary["assertions"]["baselineProfileNotApplied"] is True, summary
assert summary["assertions"]["learnedProfilesApplied"] is True, summary
assert summary["assertions"]["learnedActionsHaveMouseMovement"] is True, summary

actions = summary["actions"]
assert len(actions) >= 4, summary
for action in actions[1:]:
    assert action["profileApplied"] is True, action
    assert action["mouseMoveCount"] >= 6, action
    assert action["eventCount"] > action["mouseMoveCount"], action

print(json.dumps({
    "ok": True,
    "response": response_path,
    "log": log_path,
    "training": summary["training"],
    "actionCount": len(actions),
    "mouseMoveCounts": [item["mouseMoveCount"] for item in actions],
    "templateIds": sorted({tid for item in actions for tid in item.get("templateIds", [])}),
}, ensure_ascii=False, indent=2))
PY

echo "learning-playback-demo OK"
