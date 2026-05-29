#!/usr/bin/env python3
"""
TV Launcher - local bridge server
Receives app launch requests from Chromium and executes them as subprocesses.
Listens on 127.0.0.1:9234 only — not exposed to network.
"""

import http.server
import json
import subprocess
import os
import sys
import urllib.parse
from pathlib import Path

PORT = 9234
LAUNCHER_DIR = Path(__file__).parent.resolve()
# Apps file defaults to apps.json next to this script. Override with the
# LAUNCHER_APPS env var (e.g. apps.dev.json) for local/VM testing.
APPS_JSON = Path(os.environ.get("LAUNCHER_APPS", LAUNCHER_DIR / "apps.json"))

class LauncherHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[launcher] {fmt % args}", file=sys.stderr)

    def send_cors(self):
        self.send_header("Access-Control-Allow-Origin", "null")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        # Serve apps.json to the frontend
        if parsed.path == "/apps":
            try:
                data = APPS_JSON.read_text()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_cors()
                self.end_headers()
                self.wfile.write(data.encode())
            except Exception as e:
                self._error(str(e))
            return

        # Serve the launcher HTML (for chromium --app=http://... mode)
        if parsed.path == "/" or parsed.path == "/index.html":
            index = (LAUNCHER_DIR / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_cors()
            self.end_headers()
            self.wfile.write(index)
            return

        self._error("not found", 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/launch":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
                cmd = req.get("cmd", "").strip()
                match = req.get("match", "").strip()
                if not cmd:
                    self._error("missing cmd")
                    return
                # Focus-or-launch: many apps (Spotify, browsers) are
                # single-instance, so a second launch just hands off to the
                # running process and exits without mapping a new window — which
                # means Sway's "fullscreen on map" rule never fires and the
                # window stays buried behind the kiosk. If a Sway match criteria
                # is given and an existing window matches, raise+fullscreen it
                # instead of spawning a duplicate.
                if match and self._focus_window(match):
                    self._ok({"status": "focused", "match": match})
                    return
                # Launch detached so it outlives the server restart
                subprocess.Popen(
                    cmd, shell=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True
                )
                self._ok({"status": "launched", "cmd": cmd})
            except Exception as e:
                self._error(str(e))
            return

        if parsed.path == "/update-recents":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
                recents = req.get("recents", [])
                data = json.loads(APPS_JSON.read_text())
                data["recents"] = recents[:8]
                APPS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False))
                self._ok({"status": "saved"})
            except Exception as e:
                self._error(str(e))
            return

        self._error("not found", 404)

    def _focus_window(self, match):
        """Try to focus + fullscreen an existing Sway window matching the given
        criteria (e.g. 'app_id="spotify"'). Returns True only if swaymsg reports
        the command succeeded against at least one node (i.e. a window existed)."""
        try:
            out = subprocess.run(
                ["swaymsg", f'[{match}] focus, fullscreen enable'],
                capture_output=True, text=True, timeout=2,
            )
            results = json.loads(out.stdout or "[]")
            return bool(results) and all(r.get("success") for r in results)
        except Exception:
            return False

    def _ok(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_cors()
        self.end_headers()
        self.wfile.write(body)

    def _error(self, msg, code=500):
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_cors()
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), LauncherHandler)
    print(f"[launcher] bridge server listening on http://127.0.0.1:{PORT}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[launcher] shutting down", file=sys.stderr)
