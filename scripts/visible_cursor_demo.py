#!/usr/bin/env python3
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "scripts" / "report_server.py"
URL = "http://127.0.0.1:8123/index.html"
RESULTS = ROOT / "results"
CURSOR = RESULTS / "cursor-command.json"


def run(command, check=True):
    return subprocess.run(command, check=check, text=True, capture_output=True)


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


def build_points():
    points = []

    def add_line(start, end, steps, delay):
        for index in range(steps):
            progress = index / max(steps - 1, 1)
            x = round(start[0] + (end[0] - start[0]) * progress)
            y = round(start[1] + (end[1] - start[1]) * progress)
            points.append({"x": x, "y": y, "delayMs": delay})

    add_line((180, 160), (760, 240), 18, 220)
    points.append({"x": 760, "y": 240, "delayMs": 1500})
    add_line((760, 240), (990, 430), 12, 180)
    points.append({"x": 990, "y": 430, "delayMs": 1400})
    add_line((990, 430), (320, 470), 16, 160)
    points.append({"x": 320, "y": 470, "delayMs": 1800})
    return points


def main():
    RESULTS.mkdir(exist_ok=True)
    server = start_server()
    try:
        open_safari(URL)
        print("Safari 验证页已打开，2 秒后开始纯可见虚拟鼠标演示。")
        time.sleep(2.0)
        payload = {
            "version": int(time.time() * 1000),
            "type": "virtual-cursor-demo",
            "holdMs": 1800,
            "points": build_points(),
        }
        CURSOR.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print("纯可见虚拟鼠标演示已触发。")
        time.sleep(12)
    finally:
        server.terminate()


if __name__ == "__main__":
    main()
