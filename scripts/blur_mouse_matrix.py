#!/usr/bin/env python3
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


def open_safari(url: str):
    script = f'''
    tell application "Safari"
      activate
      if (count of documents) = 0 then
        make new document
      end if
      set URL of front document to "{url}"
    end tell
    '''
    osa(script)
    time.sleep(2.5)


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


def run_injector(binary: Path, scenarios: str):
    result = run([
        str(binary),
        "--bundle",
        "com.apple.Safari",
        "--scenarios",
        scenarios,
        "--results-dir",
        str(RESULTS),
    ])
    return result.stdout


def write_json(path: Path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    RESULTS.mkdir(exist_ok=True)
    if REPORT.exists():
        REPORT.unlink()
    binary = compile_injector()
    server = start_server()
    artifacts = {}
    try:
        open_safari(URL)
        artifacts["initial_report"] = read_report(wait_seconds=5.0)
        activate_textedit_and_clear()
        artifacts["blur_frontmost_before"] = frontmost_app()
        artifacts["blur_focus_before"] = wait_for_focus_report(False)
        artifacts["blur_mouse_stdout"] = run_injector(binary, "mouse_move_click_blur,mouse_drag_blur,scroll_blur")
        time.sleep(1.5)
        artifacts["blur_frontmost_after_injection"] = frontmost_app()
        osa('tell application "Safari" to activate')
        time.sleep(1.2)
        artifacts["blur_report_after"] = read_report(wait_seconds=3.0)
        write_json(RESULTS / "blur-mouse-matrix.json", artifacts)
        print(json.dumps({"status": "ok", "results": str(RESULTS / "blur-mouse-matrix.json")}, ensure_ascii=False))
    finally:
        server.terminate()


if __name__ == "__main__":
    main()
