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
# System settings (audio output profile, ...) live in system.json next to this
# script; override with LAUNCHER_SYSTEM. Unlike apps.json this is small and only
# the launcher's System section reads/writes it.
SYSTEM_JSON = Path(os.environ.get("LAUNCHER_SYSTEM", LAUNCHER_DIR / "system.json"))

# --- Global UI state --------------------------------------------------------
# Tracks what the box is currently showing so behaviour can branch on it later.
#   view == "HOME"  -> the launcher kiosk is in front (no app, or backgrounded)
#   view == "APP"   -> a launched app is in front; STATE["app"] is its name
# Updated on every user action: /launch and /home (the remote Home button, via
# go-home.sh) both flow through here, plus a focus-or-launch counts as an APP.
STATE = {"view": "HOME", "app": None}


def set_state(view, app=None):
    """Update the global UI state and log the transition."""
    STATE["view"] = view
    STATE["app"] = app
    label = f"{view} ({app})" if app else view
    print(f"[launcher] state -> {label}", file=sys.stderr)


def find_app(name):
    """Look up an app object in apps.json by name. apps.json is the single
    source of truth for cmd/match, so the bridge resolves them server-side
    rather than trusting the POST body: a frontend page loaded before a
    redeploy keeps an outdated match, and an outdated match silently fails
    focus-or-launch and piles up duplicate windows (e.g. a stale lowercase
    app_id="kodi" vs the live window's app_id="Kodi"). Returns the app dict,
    or None if not found / unreadable."""
    if not name:
        return None
    try:
        data = json.loads(APPS_JSON.read_text())
        for app in data.get("apps", []):
            if app.get("name") == name:
                return app
    except Exception as e:
        print(f"[launcher] find_app error: {e}", file=sys.stderr)
    return None


def set_audio_sink(sink):
    """Make `sink` (a stable PipeWire/Pulse sink *name*) the default output for
    all apps, and move any already-playing streams over so the switch is
    immediate rather than only affecting new streams. Uses `pactl` (stable by
    name; `wpctl set-default` needs unstable numeric node IDs). Returns True on
    success. Requires the bridge to share the user's audio session — on a normal
    boot it inherits XDG_RUNTIME_DIR from Sway; restarting from a bare SSH shell
    may strip it (same gotcha as SWAYSOCK for focus-or-launch)."""
    try:
        r = subprocess.run(["pactl", "set-default-sink", sink],
                            capture_output=True, text=True, timeout=4)
        if r.returncode != 0:
            print(f"[launcher] set-default-sink failed: {r.stderr.strip()}",
                  file=sys.stderr)
            return False
        # Move existing playback streams to the new default (set-default-sink
        # only redirects future ones on its own).
        inputs = subprocess.run(["pactl", "list", "short", "sink-inputs"],
                                capture_output=True, text=True, timeout=4)
        for line in inputs.stdout.splitlines():
            sid = line.split("\t", 1)[0].strip()
            if sid:
                subprocess.run(["pactl", "move-sink-input", sid, sink],
                               capture_output=True, text=True, timeout=4)
        print(f"[launcher] audio default -> {sink}", file=sys.stderr)
        return True
    except Exception as e:
        print(f"[launcher] set_audio_sink error: {e}", file=sys.stderr)
        return False


def apply_saved_audio():
    """On startup, re-assert the persisted audio profile so SMSL (the stored
    default) is in front after a reboot regardless of what PipeWire last chose.
    Best-effort: never fatal if the file is missing or the session has no audio
    yet."""
    try:
        data = json.loads(SYSTEM_JSON.read_text())
        audio = data.get("audio", {})
        name = audio.get("selected")
        profile = next((p for p in audio.get("profiles", [])
                        if p.get("name") == name), None)
        if profile:
            set_audio_sink(profile["sink"])
    except Exception as e:
        print(f"[launcher] apply_saved_audio skipped: {e}", file=sys.stderr)

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

        # Serve system.json (audio profiles + current selection) to the frontend
        if parsed.path == "/system":
            try:
                data = SYSTEM_JSON.read_text()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_cors()
                self.end_headers()
                self.wfile.write(data.encode())
            except Exception as e:
                self._error(str(e))
            return

        # Report the current UI state (HOME / APP + app name)
        if parsed.path == "/state":
            self._ok(dict(STATE))
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
                name = req.get("name", "").strip()
                # apps.json is authoritative: prefer its cmd/match over the
                # (possibly stale) values the frontend posted, so an outdated
                # page can't bypass focus-or-launch and spawn duplicates. Fall
                # back to the posted values only for an app not in apps.json.
                app = find_app(name)
                if app:
                    cmd = (app.get("cmd") or "").strip() or cmd
                    match = (app.get("match") or "").strip()
                if not cmd:
                    self._error("missing cmd")
                    return
                # An app is now in front (whether focused or freshly spawned).
                set_state("APP", name or cmd)
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

        if parsed.path == "/home":
            # The Home button (go-home.sh) brought the launcher to the front.
            set_state("HOME")
            self._ok(dict(STATE))
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

        if parsed.path == "/set-audio":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
                name = req.get("name", "").strip()
                data = json.loads(SYSTEM_JSON.read_text())
                profiles = data.get("audio", {}).get("profiles", [])
                profile = next((p for p in profiles if p.get("name") == name), None)
                if profile is None:
                    self._error(f"unknown audio profile: {name!r}")
                    return
                if not set_audio_sink(profile["sink"]):
                    self._error(f"failed to switch audio to {name!r}")
                    return
                # Persist the selection so it survives a bridge restart and is
                # re-applied on next boot (see apply_saved_audio).
                data["audio"]["selected"] = name
                SYSTEM_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False))
                self._ok({"status": "switched", "selected": name})
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
    apply_saved_audio()
    server = http.server.HTTPServer(("127.0.0.1", PORT), LauncherHandler)
    print(f"[launcher] bridge server listening on http://127.0.0.1:{PORT}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[launcher] shutting down", file=sys.stderr)
