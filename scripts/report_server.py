#!/usr/bin/env python3
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
RESULTS = ROOT / "results"
REPORT_PATH = RESULTS / "browser-report.json"
CURSOR_PATH = RESULTS / "cursor-command.json"
HID_TIMEOUT_SECONDS = 5.0


def hid_socket_path():
    return os.environ.get("VIRTUALHID_SOCKET") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "virtualhid.sock")


def call_hid_daemon(method, params):
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


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ("/", "/index.html"):
            self.serve_file(WEB / "index.html", "text/html; charset=utf-8")
            return
        if path == "/app.js":
            self.serve_file(WEB / "app.js", "application/javascript; charset=utf-8")
            return
        if path == "/styles.css":
            self.serve_file(WEB / "styles.css", "text/css; charset=utf-8")
            return
        if path == "/cursor-command":
            self.serve_cursor_command()
            return
        if path == "/hid/state":
            self.serve_hid_state()
            return
        self.send_error(404)

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/hid/action":
            self.serve_hid_action()
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
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json_error(400, "E_BAD_REQUEST", "invalid Content-Length")
            return
        body = self.rfile.read(length) if length else b"{}"
        try:
            params = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            self.send_json_error(400, "E_BAD_REQUEST", str(error))
            return
        self.forward_hid_request("action", params)

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

    def serve_cursor_command(self):
        RESULTS.mkdir(exist_ok=True)
        if not CURSOR_PATH.exists():
            payload = {"version": 0}
        else:
            try:
                payload = json.loads(CURSOR_PATH.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                payload = {"version": 0}
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    port = int(os.environ.get("PORT", "8123"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
