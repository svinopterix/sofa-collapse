# sofa-collapse

A couch/TV-friendly application launcher for a Linux media-center box.

`sofa-collapse` turns an Ubuntu machine wired to a TV into a 10-foot appliance:
on boot it drops straight into a fullscreen launcher you drive with a remote or a
gamepad, and from there you start Spotify, Jellyfin, YouTube, mpv, VLC, Chrome, etc.
No desktop, no mouse — just tiles on a TV.

![the launcher](vm/media/boot_splash.png)

## Install & run

Take clean Ubuntu 26.04, clone the repo, run *provision.sh*.

There's no build, test, or lint tooling — it's static HTML plus a stdlib Python script.


## How it works

Two small components wired together by **Sway** (a Wayland compositor that
auto-starts on tty1 login):

- **Bridge server** — [`src/launcher/server.py`](src/launcher/server.py), a stdlib-only
  `http.server` bound to `127.0.0.1:9234` (never network-exposed). It's the only piece
  that runs commands: the UI POSTs to it and it spawns the real apps, switches the audio
  output, and tracks what's on screen.
- **Kiosk** — Chromium launched with `--kiosk --app=http://127.0.0.1:9234`, displaying
  the launcher UI ([`src/launcher/index.html`](src/launcher/index.html) — a single
  self-contained HTML/CSS/JS file, no build step, no dependencies).

Sway forces every launched app window fullscreen so it pops in front of the kiosk, and
binds the remote's **Home** and **media** keys to small helper scripts. The remote's
Home button returns to the launcher while the launched app keeps running.

```
remote / gamepad ──▶ Chromium kiosk (index.html) ──HTTP──▶ bridge (server.py) ──▶ spawns apps
        │                                                         │
        └── Home / media keys ──▶ Sway ──▶ go-home.sh / media-seek.sh
```

## Repo layout

| Path | What it is |
| --- | --- |
| [`src/launcher/server.py`](src/launcher/server.py) | The bridge HTTP server (the only command-runner). |
| [`src/launcher/index.html`](src/launcher/index.html) | The self-contained launcher UI. |
| [`src/launcher/apps.json`](src/launcher/apps.json) | Single source of truth for the launcher: tiles, settings, recents. |
| [`src/launcher/system.json`](src/launcher/system.json) | Backs the **System** section — audio output profiles + current selection. |
| [`src/launcher/keybindings.yaml`](src/launcher/keybindings.yaml) | Remote / media-key bindings, parsed into the Sway config. |
| [`apps/available/`](apps/available/) | Per-app idempotent installer scripts (sites-available pattern). |
| [`apps/install/`](apps/install/) | Symlinks to the *enabled* installers (sites-enabled pattern). |
| [`vm/provision.sh`](vm/provision.sh) | Provisions a clean Ubuntu 24.04 box end-to-end. |
| [`vm/test-launcher.sh`](vm/test-launcher.sh) | Headless smoke test (Sway on the wlroots headless backend + a screenshot). |
| [`vm/README.md`](vm/README.md) | How to test the launcher in a VM. |
| `src/launcher/install.sh`, `tv-launcher-*.service`, `src/initial-setup.md` | **Legacy** Openbox/X11 + systemd path, superseded by the Sway path. Kept for reference. |
