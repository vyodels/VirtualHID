#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
BIN = ROOT / "bin"
OBJ = ROOT / "objc" / "injector.m"
SERVER = ROOT / "scripts" / "report_server.py"
URL = "http://127.0.0.1:8123/index.html"
REPORT = RESULTS / "browser-report.json"

BROWSERS = {
    "safari": {
        "bundle": "com.apple.Safari",
        "app_name": "Safari",
        "open_script": '''
        tell application "Safari"
          activate
          if (count of documents) = 0 then
            make new document
          end if
          set URL of front document to "{url}"
        end tell
        ''',
        "activate_script": 'tell application "Safari" to activate',
    },
    "chrome": {
        "bundle": "com.google.Chrome",
        "app_name": "Google Chrome",
        "open_script": '''
        tell application "Google Chrome"
          activate
          open location "{url}"
        end tell
        ''',
        "activate_script": 'tell application "Google Chrome" to activate',
    },
}

ACTIVE_SCENARIOS = "mouse_move_click_active,mouse_drag_active,scroll_active,keyboard_type_active"
BLUR_MOUSE_SCENARIOS = "mouse_move_click_blur,mouse_drag_blur,scroll_blur"
BLUR_KEYBOARD_SCENARIOS = "keyboard_type_blur"


def run(command, check=True, capture_output=True):
    return subprocess.run(command, check=check, text=True, capture_output=capture_output)


def compile_injector():
    BIN.mkdir(exist_ok=True)
    output = BIN / "injector"
    command = [
        "clang",
        "-fobjc-arc",
        "-framework",
        "Cocoa",
        "-framework",
        "ApplicationServices",
        str(OBJ),
        "-o",
        str(output),
    ]
    run(command)
    return output


def start_server():
    process = subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(40):
        try:
            with urllib.request.urlopen(URL, timeout=1) as response:
                if response.status == 200:
                    return process
        except Exception:
            time.sleep(0.2)
    process.terminate()
    raise RuntimeError("本地报告服务启动失败")


def osa(script: str) -> str:
    return run(["osascript", "-e", script]).stdout.strip()


def open_browser(browser: str, url: str):
    script = BROWSERS[browser]["open_script"].format(url=url)
    osa(script)
    time.sleep(2.5)


def activate_browser(browser: str):
    osa(BROWSERS[browser]["activate_script"])
    time.sleep(1.2)


def activate_textedit_and_clear():
    script = '''
    tell application "TextEdit"
      activate
      if (count of documents) = 0 then
        make new document
      end if
      set text of front document to ""
    end tell
    '''
    osa(script)
    time.sleep(0.8)


def get_textedit_text():
    script = '''
    tell application "TextEdit"
      if (count of documents) = 0 then
        return ""
      end if
      return text of front document
    end tell
    '''
    return osa(script)


def frontmost_app():
    script = 'tell application "System Events" to get name of first application process whose frontmost is true'
    return osa(script)


def read_report(wait_seconds=3.0):
    deadline = time.time() + wait_seconds
    last = None
    while time.time() < deadline:
        if REPORT.exists():
            try:
                last = json.loads(REPORT.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                last = None
            if last:
                return last
        time.sleep(0.2)
    if last:
        return last
    raise RuntimeError("未收到浏览器报告")


def wait_for_focus_report(expected_focus, wait_seconds=5.0):
    deadline = time.time() + wait_seconds
    candidate = None
    while time.time() < deadline:
        candidate = read_report(wait_seconds=0.4)
        focus = candidate.get("summary", {}).get("focus", {}).get("hasFocus")
        if focus == expected_focus:
            return candidate
        time.sleep(0.2)
    return candidate


def run_injector(binary: Path, bundle: str, scenarios: str, key_input: str = "abc123"):
    result = run([
        str(binary),
        "--bundle",
        bundle,
        "--scenarios",
        scenarios,
        "--results-dir",
        str(RESULTS),
        "--key-input",
        key_input,
    ])
    return result.stdout


def write_json(path: Path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", choices=sorted(BROWSERS.keys()), required=True)
    args = parser.parse_args()

    browser = args.browser
    bundle = BROWSERS[browser]["bundle"]

    RESULTS.mkdir(exist_ok=True)
    if REPORT.exists():
        REPORT.unlink()

    binary = compile_injector()
    server = start_server()
    artifacts = {"browser": browser, "bundle": bundle}

    try:
        open_browser(browser, URL)
        artifacts["initial_report"] = read_report(wait_seconds=5.0)

        artifacts["active_focus_before"] = wait_for_focus_report(True)
        artifacts["active_stdout"] = run_injector(binary, bundle, ACTIVE_SCENARIOS)
        time.sleep(1.5)
        artifacts["active_report_after"] = read_report(wait_seconds=3.0)

        activate_textedit_and_clear()
        artifacts["blur_frontmost_before_mouse"] = frontmost_app()
        artifacts["blur_focus_before_mouse"] = wait_for_focus_report(False)
        artifacts["blur_mouse_stdout"] = run_injector(binary, bundle, BLUR_MOUSE_SCENARIOS)
        time.sleep(1.5)
        artifacts["blur_frontmost_after_mouse"] = frontmost_app()
        activate_browser(browser)
        artifacts["blur_mouse_report_after"] = read_report(wait_seconds=3.0)

        activate_textedit_and_clear()
        artifacts["blur_frontmost_before_keyboard"] = frontmost_app()
        artifacts["blur_focus_before_keyboard"] = wait_for_focus_report(False)
        artifacts["blur_keyboard_stdout"] = run_injector(binary, bundle, BLUR_KEYBOARD_SCENARIOS)
        time.sleep(1.2)
        artifacts["blur_frontmost_after_keyboard"] = frontmost_app()
        artifacts["textedit_text_after_blur_keyboard"] = get_textedit_text()
        activate_browser(browser)
        artifacts["blur_keyboard_report_after"] = read_report(wait_seconds=3.0)

        output = RESULTS / f"{browser}-matrix.json"
        write_json(output, artifacts)
        print(json.dumps({"status": "ok", "results": str(output)}, ensure_ascii=False))
    finally:
        server.terminate()


if __name__ == "__main__":
    main()
