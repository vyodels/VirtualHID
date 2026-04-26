#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ENV=(env)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")
fi
BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-hud-spm-build}"
"${DEVELOPER_ENV[@]}" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-hud-clang-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-hud-swiftpm-cache}" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" >/tmp/virtualhid-hud-build.log

DAEMON="$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon"
DISABLED_JSON="$("$DAEMON" --smoke-hud-contract --no-hud)"
ENABLED_JSON="$("$DAEMON" --smoke-hud-contract --visualize-hid)"
CLI_NO_HUD_JSON="$(VIRTUALHID_VISUALIZE_HID=1 "$DAEMON" --smoke-hud-contract --no-hud)"
ENV_NO_HUD_JSON="$(VIRTUALHID_NO_HUD=1 "$DAEMON" --smoke-hud-contract --visualize-hid)"
SETTINGS_JSON="$(VIRTUALHID_HUD_CLEAR_DELAY_SECONDS=7.5 VIRTUALHID_HUD_HIDE=trail,expected,keyboard,persistent "$DAEMON" --smoke-hud-contract --visualize-hid --hud-control --hud-hide status --hud-show actual)"

DISABLED_JSON="$DISABLED_JSON" \
ENABLED_JSON="$ENABLED_JSON" \
CLI_NO_HUD_JSON="$CLI_NO_HUD_JSON" \
ENV_NO_HUD_JSON="$ENV_NO_HUD_JSON" \
SETTINGS_JSON="$SETTINGS_JSON" \
python3 - <<'PY'
import json
import os

disabled = json.loads(os.environ["DISABLED_JSON"])
enabled = json.loads(os.environ["ENABLED_JSON"])
cli_no_hud = json.loads(os.environ["CLI_NO_HUD_JSON"])
env_no_hud = json.loads(os.environ["ENV_NO_HUD_JSON"])
settings_payload = json.loads(os.environ["SETTINGS_JSON"])


def assert_base(payload):
    assert payload["actionOk"] is True, payload
    assert payload["source"] == "virtualhid-action-events", payload
    assert payload["response"]["eventCount"] > 0, payload
    assert payload["response"]["expectedPointer"] == {"x": 160, "y": 160}, payload
    assert payload["response"]["finalPointer"] == {"x": 160, "y": 160}, payload


assert_base(disabled)
assert disabled["hudEnabled"] is False, disabled
assert disabled["callback"]["started"] is None, disabled
assert disabled["callback"]["recordedEvents"] == 0, disabled
assert disabled["callback"]["finishedEvents"] == 0, disabled

assert_base(enabled)
assert enabled["hudEnabled"] is True, enabled
assert enabled["callback"]["started"] == "hud-smoke", enabled
assert enabled["callback"]["startedSource"] == "hid", enabled
assert enabled["callback"]["actionTypes"] == ["click", "scroll"], enabled
assert enabled["callback"]["recordedEvents"] == enabled["response"]["eventCount"], enabled
assert enabled["callback"]["finishedEvents"] == enabled["response"]["eventCount"], enabled
assert enabled["callback"]["expectedPointer"] == enabled["response"]["expectedPointer"], enabled
assert enabled["callback"]["finalPointer"] == enabled["response"]["finalPointer"], enabled
assert enabled["hudSettings"]["persistent"] is True, enabled

assert cli_no_hud["hudEnabled"] is False, cli_no_hud
assert env_no_hud["hudEnabled"] is False, env_no_hud

assert_base(settings_payload)
assert settings_payload["hudEnabled"] is True, settings_payload
assert settings_payload["hudControlEnabled"] is True, settings_payload
assert settings_payload["hudLockedOff"] is False, settings_payload
hud_settings = settings_payload["hudSettings"]
assert abs(hud_settings["clearDelaySeconds"] - 7.5) < 0.001, settings_payload
assert hud_settings["trail"] is False, settings_payload
assert hud_settings["expectedPoint"] is False, settings_payload
assert hud_settings["keyboardEffects"] is False, settings_payload
assert hud_settings["status"] is False, settings_payload
assert hud_settings["actualPoint"] is True, settings_payload
assert hud_settings["persistent"] is False, settings_payload
assert settings_payload["callback"]["recordedEvents"] == settings_payload["response"]["eventCount"], settings_payload

print("hud-smoke OK")
PY
