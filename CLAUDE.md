# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A couch/TV-friendly application launcher for a Linux media-center box ("sofa-collapse" = Linux media center stuff). The launcher runs as a fullscreen Chromium kiosk that talks to a tiny local Python HTTP server, which actually spawns desktop apps. The host (Ubuntu 24.04) runs **Sway** (a Wayland compositor) that auto-starts on tty1 login and brings up the kiosk; `vm/provision.sh` provisions a clean machine end-to-end.

## Architecture

Two components — a bridge server and a Chromium kiosk — wired together by Sway:

- **Bridge server** (`src/launcher/server.py`) — a stdlib-only `http.server` bound to `127.0.0.1:9234` (never network-exposed). It is the only component that can run commands. Started by `start-kiosk.sh` (not a service). Endpoints:
  - `GET /` and `/index.html` → serves the launcher UI
  - `GET /apps` → serves `apps.json` to the frontend
  - `POST /launch` `{cmd}` → runs `cmd` via `subprocess.Popen(shell=True, start_new_session=True)` so launched apps outlive a server restart
  - `POST /update-recents` `{recents}` → persists the recents list (capped at 8) back into `apps.json`
- **Kiosk** — `~/launcher/start-kiosk.sh` starts the bridge if port 9234 isn't already listening, waits for it, then `exec`s `chromium --kiosk --app=http://127.0.0.1:9234 --ozone-platform=wayland`. Sway's generated config (`~/.config/sway/config`) runs `start-kiosk.sh` on startup.

**Sway window behavior** (set in the config `vm/provision.sh` writes): every top-level app window is forced fullscreen (`for_window [app_id=".+"]` + `[shell="xwayland"]`). The kiosk runs fullscreen and a Sway fullscreen window stays on top of its output, so without this an app launched from the kiosk would open *behind* the launcher (focused but hidden). Fullscreening each new window pulls the launched app to the foreground; when it closes, Chromium is the sole window and fills the screen again.

**Remote keys**: the i25 Mini remote's Home button (`XF86HomePage`) is bound to `~/launcher/go-home.sh`, which refocuses and re-fullscreens the launcher window — matched by its page title `TV Launcher` (stable regardless of Wayland `app_id`, which Chromium-based web apps share) — returning to the home screen while the launched app keeps running. Use `wev` to discover the keysym a given remote button emits.

The frontend (`src/launcher/index.html`) is a single self-contained file: all HTML, CSS, and vanilla JS inline, no build step and no dependencies (only a Google Fonts `@import`). `BRIDGE = 'http://127.0.0.1:9234'` is hardcoded. It renders tiles + recents from `/apps`, supports keyboard arrows, gamepad (D-pad/stick + A/B buttons mapped to Enter/Escape via synthetic `KeyboardEvent`s), and type-to-search.

Key design point: the server uses CORS `Access-Control-Allow-Origin: null` because Chromium `--app=` pages have a `null` origin.

### Config: `src/launcher/apps.json`

Single source of truth for the launcher. `settings` (username, columns, accent_color), `apps[]` (each: `name`, `icon` emoji, `cmd` shell string, `accent` color, optional `badge` of `hot`/`new`/`update`, optional `match` Sway criteria for focus-or-launch), and `recents[]` (app names). The `recents` array is rewritten by the server at runtime — edits there will be overwritten.

#### Focus-or-launch and `match` selectors

`server.py`'s `POST /launch` does focus-or-launch: if an app object has a `match` criteria and a live Sway window matches, it raises + fullscreens that window (`swaymsg [<match>] focus, fullscreen enable`) instead of spawning a duplicate. Without a correct `match`, every launch piles up a new background window.

Verified selectors against the live `swaymsg -t get_tree` on the media box (host 10.0.0.20, user `sofa`):

| App | Runs under | `app_id` | Correct `match` |
| --- | --- | --- | --- |
| Spotify | Xwayland | `null` | `class="Spotify"` |
| Emby Theater | Xwayland | `null` | `class="Emby Theater"` (title `"Emby"` is unstable; `app_id` is null — the old `app_id="emby-theater"` never matched) |
| YouTube tile | Chromium `--app` | `chrome-www.youtube.com__-Default` | `app_id="chrome-www.youtube.com__-Default"` |
| Google Chrome | — | `google-chrome` | `app_id="google-chrome"` |
| Launcher kiosk | Chromium snap `--app` | `chrome-127.0.0.1__-Default` | matched by title `"TV Launcher"` in go-home.sh |

Rule of thumb: **Xwayland apps have `app_id=null` — match them by `class=` (capitalized, with spaces), never `app_id`.** Chromium `--app=` pages get a distinct per-URL `app_id` (`chrome-<host>__-Default`), not the bare `chromium` app_id.

**Focus-or-launch requires `SWAYSOCK` in the bridge's environment.** On a normal boot the bridge inherits it (Sway → `start-kiosk.sh` → `server.py`). Restarting the bridge from a plain SSH shell strips `SWAYSOCK` and silently breaks focus-or-launch (falls through to spawning a duplicate). To restart over SSH, relaunch through Sway: `swaymsg exec '~/launcher/start-kiosk.sh'`.

## Install & run

There is no build, test, or lint tooling — it's static HTML + a stdlib Python script.

```bash
# Provision a clean Ubuntu 24.04 machine end-to-end: installs Sway, Chromium +
# the launcher apps, deploys the launcher, writes the Sway config, and sets up
# tty1 auto-start. Run as your normal user (NOT root). Re-running is safe.
vm/provision.sh

# Headless smoke test: runs Sway on the wlroots headless backend and screenshots
# the kiosk with grim (no real display needed).
vm/test-launcher.sh [out.png]

# Run the bridge server directly for local dev (then open http://127.0.0.1:9234)
python3 src/launcher/server.py
```

`vm/provision.sh` copies `index.html`, `apps.json`, `server.py` into `~/launcher/`, generates `start-kiosk.sh`, `go-home.sh`, and `~/.config/sway/config`, and adds a tty1 `exec sway` hook to `~/.bash_profile`. Note that `apps.json` is **copied** at deploy time, so editing the repo copy does not affect a running install — edit `~/launcher/apps.json` (or re-run `vm/provision.sh`).

## Conventions / gotchas

- The repo copy under `src/launcher/` is the source; the deployed copy lives in `~/launcher/`. They diverge after provisioning.
- The Sway config and the `start-kiosk.sh` / `go-home.sh` helpers are **generated** by `vm/provision.sh` (the source of truth). To change window rules or remote keybindings, edit `vm/provision.sh` and re-run it, or edit `~/.config/sway/config` live and `swaymsg reload`. Note `for_window` rules apply only to windows mapped *after* the reload.
- Adding an app = a new object in `apps.json`. No code change needed.
- `cmd` is run through a shell on a trusted, loopback-only server — that's intentional for this single-user appliance, not an injection bug to "fix".
- **Legacy (X11) path**: `src/launcher/install.sh`, `tv-launcher-bridge.service`, `tv-launcher-kiosk.service`, and `src/initial-setup.md` describe an earlier Openbox + LightDM + systemd-user-services setup. That's superseded by the Sway/Wayland path in `vm/provision.sh` — don't mix the two. (Kept for reference / X11 hosts.)
