#!/usr/bin/env python3
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
RESULTS = ROOT / "results"
REPORT_PATH = RESULTS / "browser-report.json"
CURSOR_PATH = RESULTS / "cursor-command.json"


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
        self.send_error(404)

    def do_POST(self):
        path = urlsplit(self.path).path
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
    server = ThreadingHTTPServer(("127.0.0.1", 8123), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
