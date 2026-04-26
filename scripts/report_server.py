#!/usr/bin/env python3
import errno
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from humanization_analysis import analyze_history, append_history_record, load_history

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
RESULTS = ROOT / "results"
REPORT_PATH = RESULTS / "browser-report.json"
CURSOR_PATH = RESULTS / "cursor-command.json"
ANALYSIS_HISTORY_PATH = RESULTS / "humanization-history.jsonl"
DAEMON_PID_PATH = RESULTS / "vhid-daemon.pid"
HID_TIMEOUT_SECONDS = 5.0
DAEMON_START_TIMEOUT_SECONDS = 4.0
DAEMON_START_LOCK = threading.Lock()
DEFAULT_BUNDLES = "com.apple.Safari,com.google.Chrome,org.chromium.Chromium,com.microsoft.edgemac"


def hid_socket_path():
    return os.environ.get("VIRTUALHID_SOCKET") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "virtualhid.sock")


def locate_daemon_binary():
    candidates = [
        ROOT / ".build" / "x86_64-apple-macosx" / "debug" / "vhid-daemon",
        ROOT / ".build" / "debug" / "vhid-daemon",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("未找到 vhid-daemon，可先执行 `swift build`")


def daemon_bundles():
    return os.environ.get("VIRTUALHID_BUNDLES") or DEFAULT_BUNDLES


def read_daemon_pid():
    if not DAEMON_PID_PATH.exists():
        return None
    try:
        return int(DAEMON_PID_PATH.read_text(encoding="utf-8").strip())
    except (TypeError, ValueError):
        return None


def daemon_process_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def clear_daemon_pid():
    try:
        DAEMON_PID_PATH.unlink()
    except FileNotFoundError:
        pass


def stop_managed_daemon(timeout_seconds=3.0):
    pid = read_daemon_pid()
    if not pid:
        clear_daemon_pid()
        return False
    if daemon_process_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if not daemon_process_alive(pid):
                break
            time.sleep(0.05)
        if daemon_process_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    clear_daemon_pid()
    return True


def wait_for_daemon(socket_path, timeout_seconds=DAEMON_START_TIMEOUT_SECONDS):
    last_error = RuntimeError("等待 VirtualHID daemon 启动超时")
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.4)
                client.connect(socket_path)
                return
        except OSError as error:
            last_error = error
            time.sleep(0.08)
    raise last_error


def ensure_daemon_started(force_restart=False):
    with DAEMON_START_LOCK:
        if force_restart:
            stop_managed_daemon()

        pid = read_daemon_pid()
        if pid and daemon_process_alive(pid) and not force_restart:
            return {"started": False, "pid": pid, "socketPath": hid_socket_path()}

        socket_path = hid_socket_path()
        daemon_binary = locate_daemon_binary()
        RESULTS.mkdir(exist_ok=True)
        env = os.environ.copy()
        env["VIRTUALHID_SOCKET"] = socket_path
        args = [
            str(daemon_binary),
            "--socket-path",
            socket_path,
            "--bundle",
            daemon_bundles(),
        ]
        process = subprocess.Popen(
            args,
            cwd=str(ROOT),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        DAEMON_PID_PATH.write_text(str(process.pid), encoding="utf-8")
        try:
            wait_for_daemon(socket_path)
        except Exception:
            clear_daemon_pid()
            raise
        return {"started": True, "pid": process.pid, "socketPath": socket_path}


def should_autostart_daemon(error):
    if os.environ.get("VIRTUALHID_AUTOSTART", "1") == "0":
        return False
    if isinstance(error, OSError):
        return error.errno in {errno.ENOENT, errno.ECONNREFUSED}
    if isinstance(error, RuntimeError):
        return True
    return False


def call_hid_daemon_once(method, params):
    request_id = params.get("id") if isinstance(params, dict) and isinstance(params.get("id"), str) else f"web-{method}"
    request = {"id": request_id, "method": method, "params": params}
    data = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(HID_TIMEOUT_SECONDS)
        client.connect(hid_socket_path())
        client.sendall(data)
        buffer = bytearray()
        while b"\n" not in buffer:
            chunk = client.recv(65536)
            if not chunk:
                break
            buffer.extend(chunk)

    response, _, _ = bytes(buffer).partition(b"\n")
    if not response:
        raise RuntimeError("daemon closed without a response")
    return response


def call_hid_daemon(method, params):
    try:
        return call_hid_daemon_once(method, params)
    except (OSError, RuntimeError) as error:
        if not should_autostart_daemon(error):
            raise
        ensure_daemon_started(force_restart=isinstance(error, OSError) and error.errno == errno.ECONNREFUSED)
        return call_hid_daemon_once(method, params)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        if path in ("/", "/index.html"):
            self.serve_file(WEB / "index.html", "text/html; charset=utf-8")
            return
        if path == "/app.js":
            self.serve_file(WEB / "app.js", "application/javascript; charset=utf-8")
            return
        if path == "/styles.css":
            self.serve_file(WEB / "styles.css", "text/css; charset=utf-8")
            return
        if path == "/cursor-catpaw.png":
            self.serve_file(WEB / "cursor-catpaw.png", "image/png")
            return
        if path == "/cursor-command":
            self.serve_cursor_command()
            return
        if path == "/hid/state":
            self.serve_hid_state()
            return
        if path == "/hid/daemon":
            self.serve_hid_daemon_meta()
            return
        if path == "/analysis/report":
            self.serve_analysis_report(parsed.query)
            return
        self.send_error(404)

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/hid/action":
            self.serve_hid_action()
            return
        if path == "/hid/rpc":
            self.serve_hid_rpc()
            return
        if path == "/hid/restart":
            self.serve_hid_restart()
            return
        if path == "/analysis/record":
            self.serve_analysis_record()
            return
        if path == "/analysis/apply-profile-patch":
            self.serve_analysis_apply_profile_patch()
            return
        if path != "/report":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b"{}"
        RESULTS.mkdir(exist_ok=True)
        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            payload = {"raw": body.decode("utf-8", errors="replace")}
        REPORT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        self.send_response(204)
        self.end_headers()

    def log_message(self, format, *args):
        return

    def serve_file(self, path: Path, content_type: str):
        if not path.exists():
            self.send_error(404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def serve_hid_state(self):
        self.forward_hid_request("state", {})

    def serve_hid_action(self):
        params = self.read_json_body()
        if params is None:
            return
        self.forward_hid_request("action", params)

    def serve_hid_rpc(self):
        payload = self.read_json_body()
        if payload is None:
            return
        if not isinstance(payload, dict):
            self.send_json_error(400, "E_BAD_REQUEST", "RPC payload must be a JSON object")
            return
        method = payload.get("method")
        if not isinstance(method, str) or not method:
            self.send_json_error(400, "E_BAD_REQUEST", "RPC payload requires string field method")
            return
        params = payload.get("params", {})
        if not isinstance(params, dict):
            self.send_json_error(400, "E_BAD_REQUEST", "RPC payload field params must be a JSON object")
            return
        self.forward_hid_request(method, params)

    def serve_hid_restart(self):
        try:
            meta = ensure_daemon_started(force_restart=True)
            self.send_json({"ok": True, "daemon": meta})
        except Exception as error:
            self.send_json_error(502, "E_DAEMON_RESTART_FAILED", str(error))

    def serve_analysis_record(self):
        payload = self.read_json_body()
        if payload is None:
            return
        if not isinstance(payload, dict):
            self.send_json_error(400, "E_BAD_REQUEST", "analysis record must be a JSON object")
            return
        result = append_history_record(payload, ANALYSIS_HISTORY_PATH)
        self.send_json(result)

    def serve_analysis_apply_profile_patch(self):
        payload = self.read_json_body()
        if payload is None:
            return
        if not isinstance(payload, dict):
            self.send_json_error(400, "E_BAD_REQUEST", "profile patch request must be a JSON object")
            return
        if payload.get("confirm") is not True:
            self.send_json_error(400, "E_CONFIRM_REQUIRED", "set confirm=true to apply an analysis profile patch")
            return
        proposal = payload.get("proposal")
        if not isinstance(proposal, dict):
            proposal = self.profile_patch_from_current_report(payload)
        if not isinstance(proposal, dict):
            self.send_json_error(400, "E_PATCH_REQUIRED", "request requires proposal or a matching analysis report")
            return
        if proposal.get("applicable") is False:
            self.send_json_error(400, "E_PATCH_NOT_APPLICABLE", proposal.get("reason") or "profile patch proposal is not applicable")
            return
        if proposal.get("method") != "profiles.apply" or not isinstance(proposal.get("params"), dict):
            self.send_json_error(400, "E_PATCH_INVALID", "proposal must target profiles.apply with params")
            return
        try:
            response = json.loads(call_hid_daemon("profiles.apply", proposal["params"]).decode("utf-8"))
        except Exception as error:
            self.send_json_error(502, "E_PATCH_APPLY_FAILED", str(error))
            return
        self.send_json({"ok": bool(response.get("ok")), "proposal": proposal, "daemon": response})

    def profile_patch_from_current_report(self, payload):
        report = analyze_history(
            load_history(ANALYSIS_HISTORY_PATH),
            host=payload.get("host"),
            instruction_key=payload.get("instructionKey"),
        )
        for group in report.get("groups", []):
            proposal = group.get("profilePatchProposal")
            if isinstance(proposal, dict) and proposal.get("applicable"):
                return proposal
        return None

    def serve_analysis_report(self, query):
        params = parse_qs(query or "")
        host = first_query_value(params.get("host"))
        instruction_key = first_query_value(params.get("instructionKey"))
        report = analyze_history(load_history(ANALYSIS_HISTORY_PATH), host=host, instruction_key=instruction_key)
        self.send_json(report)

    def forward_hid_request(self, method, params):
        try:
            data = call_hid_daemon(method, params)
        except (OSError, RuntimeError) as error:
            self.send_json_error(502, "E_DAEMON_UNREACHABLE", str(error))
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json_error(self, status, code, message):
        payload = {"ok": False, "error": {"code": code, "message": message}}
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json_error(400, "E_BAD_REQUEST", "invalid Content-Length")
            return None
        body = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            self.send_json_error(400, "E_BAD_REQUEST", str(error))
            return None

    def serve_cursor_command(self):
        RESULTS.mkdir(exist_ok=True)
        if not CURSOR_PATH.exists():
            payload = {"version": 0}
        else:
            try:
                payload = json.loads(CURSOR_PATH.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                payload = {"version": 0}
        if isinstance(payload, dict) and payload.get("type") == "virtual-cursor-demo" and payload.get("version") and not payload.get("sticky"):
            CURSOR_PATH.write_text(
                json.dumps({"version": payload["version"], "consumed": True}, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def serve_hid_daemon_meta(self):
        pid = read_daemon_pid()
        self.send_json(
            {
                "socketPath": hid_socket_path(),
                "managedPid": pid,
                "managedAlive": bool(pid and daemon_process_alive(pid)),
                "autostart": os.environ.get("VIRTUALHID_AUTOSTART", "1") != "0",
                "daemonBinary": str(locate_daemon_binary()) if any(candidate.exists() for candidate in [
                    ROOT / ".build" / "x86_64-apple-macosx" / "debug" / "vhid-daemon",
                    ROOT / ".build" / "debug" / "vhid-daemon",
                ]) else None,
            }
        )


def main():
    port = int(os.environ.get("PORT", "8123"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def first_query_value(values):
    if not values:
        return None
    return values[0]


if __name__ == "__main__":
    main()
