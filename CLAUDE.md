# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A couch/TV-friendly application launcher for a Linux media-center box ("sofa-collapse" = Linux media center stuff). The launcher runs as a fullscreen Chromium kiosk that talks to a tiny local Python HTTP server, which actually spawns desktop apps. The host is set up with Openbox + LightDM auto-login (see `src/initial-setup.md`).

## Architecture

Two cooperating systemd **user** services (not system-wide):

- **Bridge server** (`src/launcher/server.py`) — a stdlib-only `http.server` bound to `127.0.0.1:9234` (never network-exposed). It is the only component that can run commands. Endpoints:
  - `GET /` and `/index.html` → serves the launcher UI
  - `GET /apps` → serves `apps.json` to the frontend
  - `POST /launch` `{cmd}` → runs `cmd` via `subprocess.Popen(shell=True, start_new_session=True)` so launched apps outlive a server restart
  - `POST /update-recents` `{recents}` → persists the recents list (capped at 8) back into `apps.json`
- **Kiosk** (`tv-launcher-kiosk.service`) — `chromium-browser --kiosk --app=http://127.0.0.1:9234`. Depends on (`Requires=`) the bridge service.

The frontend (`src/launcher/index.html`) is a single self-contained file: all HTML, CSS, and vanilla JS inline, no build step and no dependencies (only a Google Fonts `@import`). `BRIDGE = 'http://127.0.0.1:9234'` is hardcoded. It renders tiles + recents from `/apps`, supports keyboard arrows, gamepad (D-pad/stick + A/B buttons mapped to Enter/Escape via synthetic `KeyboardEvent`s), and type-to-search.

Key design point: the server uses CORS `Access-Control-Allow-Origin: null` because Chromium `--app=` pages have a `null` origin.

### Config: `src/launcher/apps.json`

Single source of truth for the launcher. `settings` (username, columns, accent_color), `apps[]` (each: `name`, `icon` emoji, `cmd` shell string, `accent` color, optional `badge` of `hot`/`new`/`update`), and `recents[]` (app names). The `recents` array is rewritten by the server at runtime — edits there will be overwritten.

## Install & run

There is no build, test, or lint tooling — it's static HTML + a stdlib Python script.

```bash
# Install to ~/launcher and register systemd user units (run as your user, NOT root)
src/launcher/install.sh

# Start
systemctl --user start tv-launcher-bridge
systemctl --user start tv-launcher-kiosk

# Logs
journalctl --user -u tv-launcher-bridge -f

# Run the bridge server directly for local dev (then open http://127.0.0.1:9234)
python3 src/launcher/server.py
```

`install.sh` copies `index.html`, `apps.json`, `server.py` into `~/launcher/` and `sed`-substitutes `%h` → `$HOME` in the `.service` files before installing them to `~/.config/systemd/user/`. Note that `apps.json` is **copied** at install time, so editing the repo copy does not affect a running install — edit `~/launcher/apps.json` (or re-run `install.sh`).

## Conventions / gotchas

- The repo copy under `src/launcher/` is the source; the deployed copy lives in `~/launcher/`. They diverge after install.
- The `.service` unit files in the repo are templates using `%h`; `install.sh` expands them.
- Adding an app = a new object in `apps.json`. No code change needed.
- `cmd` is run through a shell on a trusted, loopback-only server — that's intentional for this single-user appliance, not an injection bug to "fix".
