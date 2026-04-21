#!/usr/bin/env python3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
OBJ = ROOT / "objc" / "injector.m"
SERVER = ROOT / "scripts" / "report_server.py"
URL = "http://127.0.0.1:8123/index.html"


def run(command, check=True):
    return subprocess.run(command, check=check, text=True, capture_output=True)


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


def osa(script: str):
    run(["osascript", "-e", script])


def open_safari(url: str):
    osa(f'''
    tell application "Safari"
      activate
      open location "{url}"
    end tell
    ''')
    time.sleep(2.5)


def main():
    binary = compile_injector()
    server = start_server()
    try:
        open_safari(URL)
        print("Safari 验证页已打开，2 秒后开始慢速轨迹演示。")
        time.sleep(2.0)
        run([
            str(binary),
            "--bundle",
            "com.apple.Safari",
            "--scenarios",
            "mouse_move_click_active,mouse_drag_active",
            "--results-dir",
            str(ROOT / "results"),
            "--sleep-scale",
            "5",
        ])
        print("慢速轨迹演示完成。")
    finally:
        server.terminate()


if __name__ == "__main__":
    main()
