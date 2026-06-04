#!/usr/bin/env bash
# ============================================================================
# vm/provision.sh
#
# Turn a CLEAN Ubuntu 24.04 LTS install into a Sway-based kiosk running the
# TV launcher (the bridge server + a Chromium kiosk, with all launcher apps
# installed: Chromium, Google Chrome, Spotify, Emby Theater).
#
# Run INSIDE the VM, as your normal (non-root) user that has sudo:
#     ./vm/provision.sh
#
# Re-running is safe: apt installs are idempotent, repo/key adds are guarded,
# and config files are overwritten in place.
#
# After it finishes, log out and back in on tty1 (or reboot) and Sway will
# auto-start the kiosk. For a headless/automated check, run vm/test-launcher.sh.
# ============================================================================
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER_SRC="$REPO_ROOT/src/launcher"
LAUNCHER_DST="$HOME/launcher"
SWAY_CFG_DIR="$HOME/.config/sway"

# Emby Theater is not in Ubuntu's repos. We install a known-good .deb from
# GitHub releases. Override EMBY_DEB_URL to pin a different build, or set it
# empty (and adjust EMBY_GH_REPO) to fall back to auto-discovery.
EMBY_GH_REPO="${EMBY_GH_REPO:-MediaBrowser/Emby.Releases}"
EMBY_DEB_URL="${EMBY_DEB_URL:-https://github.com/MediaBrowser/emby-theater-electron/releases/download/3.0.21/emby-theater-deb_3.0.21_amd64.deb}"

# Mouse sensitivity → Sway/libinput pointer acceleration (pointer_accel), a
# value in -1.0 (slowest) .. 1.0 (fastest), where 0 is the libinput default.
# Override MOUSE_SENSITIVITY to taste; we then dial it down 20% (per request).
MOUSE_SENSITIVITY="${MOUSE_SENSITIVITY:-0.5}"
POINTER_ACCEL="$(awk "BEGIN { printf \"%.3f\", $MOUSE_SENSITIVITY * 0.8 }")"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user (not root)."; exit 1; }

# --- 1. Base system + Sway + Wayland tooling --------------------------------
log "Updating apt and installing Sway + base packages"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  sway swaybg swayidle \
  xwayland \
  foot \
  grim \
  wev \
  wl-clipboard \
  playerctl wtype \
  python3 python3-yaml \
  jq curl wget gnupg ca-certificates apt-transport-https \
  fonts-noto-core fonts-noto-color-emoji \
  language-pack-ru \
  pipewire pipewire-pulse pipewire-audio wireplumber pavucontrol pulseaudio-utils

# A minimal Sway install ships no sound server, so launched apps (Spotify, Emby)
# have nothing to play through. Enable the PipeWire user services so they start
# with the sofa session. Run as the user (NOT via sudo) so they land in the
# right systemd --user instance; harmless if already enabled.
log "Enabling PipeWire user audio services"
systemctl --user enable --now pipewire pipewire-pulse wireplumber 2>/dev/null \
  || warn "Could not enable PipeWire user services now (no user session?); they are enabled and will start on next login."

# --- 2. Chromium (snap) — also used as the kiosk shell ----------------------
# Ubuntu's chromium is a snap; the snap command is `chromium`. The launcher
# tile uses `chromium-browser`, so we add a compatibility symlink.
log "Installing Chromium (snap)"
if ! snap list chromium >/dev/null 2>&1; then
  sudo snap install chromium
fi
if [ ! -e /usr/local/bin/chromium-browser ]; then
  sudo ln -sf "$(command -v chromium || echo /snap/bin/chromium)" /usr/local/bin/chromium-browser
fi

# --- 3. Google Chrome (official apt repo) -----------------------------------
log "Installing Google Chrome"
if [ ! -f /etc/apt/keyrings/google-chrome.gpg ]; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
fi
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
  | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable

# --- 4. Spotify (snap) ------------------------------------------------------
log "Installing Spotify (snap)"
if ! snap list spotify >/dev/null 2>&1; then
  sudo snap install spotify
fi

# --- 5. Emby Theater (best-effort: latest .deb from GitHub releases) --------
log "Installing Emby Theater"
if ! command -v emby-theater >/dev/null 2>&1; then
  if [ -z "$EMBY_DEB_URL" ]; then
    EMBY_DEB_URL="$(curl -fsSL "https://api.github.com/repos/${EMBY_GH_REPO}/releases" \
      | jq -r '[.[].assets[]?.browser_download_url
                | select(test("(?i)theater"))
                | select(test("(?i)(amd64|x86_64)"))
                | select(endswith(".deb"))][0] // empty' 2>/dev/null || true)"
  fi
  if [ -n "$EMBY_DEB_URL" ]; then
    # Emby Theater is an Electron app; its .deb doesn't always pull in the
    # X screensaver lib it links against (libXss.so.1 -> libxss1), so install
    # it explicitly to avoid a missing-shared-library crash on launch.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libxss1
    tmp="$(mktemp --suffix=.deb)"
    curl -fSL "$EMBY_DEB_URL" -o "$tmp"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp"
    rm -f "$tmp"
  else
    warn "Could not auto-locate an Emby Theater .deb. Set EMBY_DEB_URL=<url> and"
    warn "re-run, or install it manually. Continuing without Emby."
  fi
fi

# --- 6. Deploy the launcher (bridge + UI) -----------------------------------
log "Deploying launcher to $LAUNCHER_DST"
mkdir -p "$LAUNCHER_DST"
cp "$LAUNCHER_SRC/index.html"       "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/apps.json"        "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/server.py"        "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/keybindings.yaml" "$LAUNCHER_DST/"
chmod +x "$LAUNCHER_DST/server.py"

# Kiosk launcher: start the bridge, wait for its port, then exec Chromium.
# (The frontend shows "bridge offline" if Chromium loads first, so we gate.)
cat > "$LAUNCHER_DST/start-kiosk.sh" <<'KIOSK'
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER_DST="$HOME/launcher"

# Start bridge server if not already listening on 9234.
if ! curl -fsS http://127.0.0.1:9234/apps >/dev/null 2>&1; then
  python3 "$LAUNCHER_DST/server.py" &
fi
for _ in $(seq 1 50); do
  curl -fsS http://127.0.0.1:9234/apps >/dev/null 2>&1 && break
  sleep 0.2
done

# Wayland-native Chromium kiosk pointed at the bridge.
exec chromium \
  --kiosk \
  --app=http://127.0.0.1:9234 \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform \
  ${CHROMIUM_EXTRA_FLAGS:-} \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --no-first-run \
  --check-for-update-interval=31536000
KIOSK
chmod +x "$LAUNCHER_DST/start-kiosk.sh"

# "Go home" action, bound to the remote's Home button in the Sway config below.
# Brings the launcher kiosk back to the front and fullscreens it, covering
# whatever app is currently showing. The launched app keeps running in the
# background — same as a TV/Android Home button. The kiosk is matched by its
# page <title> ("TV Launcher" in index.html), which is stable regardless of the
# window's Wayland app_id, so this also works when a Chromium-based web app
# (which shares app_id "chromium") happens to be the foreground window.
cat > "$LAUNCHER_DST/go-home.sh" <<'GOHOME'
#!/usr/bin/env bash
# Tell the bridge the UI is back on the home screen (fire-and-forget so a
# stopped bridge never blocks the Home button), then raise the launcher.
curl -fsS -m 2 -X POST http://127.0.0.1:9234/home >/dev/null 2>&1 || true
exec swaymsg '[title="TV Launcher"] focus, fullscreen enable'
GOHOME
chmod +x "$LAUNCHER_DST/go-home.sh"

# State-aware Fast-Forward / Rewind, bound to the remote's FF / Rev buttons in
# keybindings.yaml. Asks the bridge which app is in front (GET /state) and does
# the natural thing for it; falls back to track-skip when the bridge is down or
# the app is unknown. Needs playerctl (MPRIS) and wtype (key injection), both
# installed above.
cat > "$LAUNCHER_DST/media-seek.sh" <<'SEEK'
#!/usr/bin/env bash
# Usage: media-seek.sh fwd|back
#   YouTube  -> seek the video ±10s   (inject YouTube's l/j hotkeys via wtype)
#   Spotify  -> next / previous track (MPRIS via playerctl)
#   default  -> next / previous track (MPRIS via playerctl)
dir="${1:-fwd}"
app="$(curl -fsS -m 2 http://127.0.0.1:9234/state 2>/dev/null | jq -r '.app // ""')"
case "$app" in
  YouTube)
    # YouTube web player hotkeys: 'l' = +10s, 'j' = -10s. wtype types the key
    # into the focused (foreground) window.
    if [ "$dir" = back ]; then wtype j; else wtype l; fi
    ;;
  Spotify)
    if [ "$dir" = back ]; then playerctl --player=spotify previous; else playerctl --player=spotify next; fi
    ;;
  *)
    if [ "$dir" = back ]; then playerctl previous; else playerctl next; fi
    ;;
esac
SEEK
chmod +x "$LAUNCHER_DST/media-seek.sh"

# --- 7. Sway config: run the kiosk, hide cursor, easy exit ------------------
log "Writing Sway config"
mkdir -p "$SWAY_CFG_DIR"

# Build the hotkey bindings from keybindings.yaml (single source of truth for
# remote/keyboard hotkeys). The Python helper (python3-yaml, installed above)
# emits `bindsym <key> <command>` lines; `$mod`/`$HOME` pass through verbatim
# for Sway / its exec shell to expand, so we keep them out of bash expansion.
KEYBINDINGS="$(python3 - "$LAUNCHER_SRC/keybindings.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
out = []
for b in doc.get("bindings", []):
    if b.get("comment"):
        out.append("# " + b["comment"])
    out.append("bindsym %s %s" % (b["key"], b["command"]))
print("\n".join(out))
PY
)"
cat > "$SWAY_CFG_DIR/config" <<SWAY
# Generated by vm/provision.sh — kiosk config for the TV launcher.
set \$mod Mod4

# Solid background; hide the pointer when idle.
output * bg #0a0c10 solid_color
seat * hide_cursor 2000

# Make the kiosk fill the screen with no decorations.
default_border none

# Keyboard: US + Russian layouts, toggled with Alt+Shift. Cyrillic input works
# everywhere (search box, Spotify, Chrome). The Russian text in the UI itself is
# rendered by the Noto fonts installed above.
input "type:keyboard" {
    xkb_layout "us,ru"
    xkb_options "grp:alt_shift_toggle"
}

# Mouse pointer sensitivity (computed in provision.sh: MOUSE_SENSITIVITY dialed
# down 20%). pointer_accel range is -1.0 (slowest) .. 1.0 (fastest).
input "type:pointer" {
    pointer_accel $POINTER_ACCEL
}

# Open every top-level app window fullscreen. The kiosk (Chromium) runs
# fullscreen, and in Sway a fullscreen window stays on top of its output — so
# an app launched from the kiosk would otherwise open *behind* it (focused but
# hidden). Fullscreening each new window brings the launched app to the
# foreground; when it closes, Chromium is the sole remaining window and fills
# the screen again. First rule covers Wayland (xdg-shell) apps, second covers
# Xwayland apps (which have no app_id).
for_window [app_id=".+"] fullscreen enable
for_window [shell="xwayland"] fullscreen enable

# Launch the launcher kiosk on Sway start.
exec "\$HOME/launcher/start-kiosk.sh"

# Hotkey bindings — generated from src/launcher/keybindings.yaml. Edit that
# file and re-run vm/provision.sh (or \`swaymsg reload\` after) to change them.
$KEYBINDINGS
SWAY

# --- 8. Auto-login on tty1 --------------------------------------------------
# No display manager (lightdm) on this Wayland path — the kiosk is brought up by
# the .bash_profile hook below, which only fires after a tty1 login shell. Drop
# in a getty override so tty1 logs this user in automatically (no password
# prompt); the hook then exec's Sway. agetty's --autologin needs the username,
# which is whoever runs provision.sh (the "sofa" user on the box).
log "Configuring auto-login on tty1 for user '$USER'"
sudo install -d /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
AUTOLOGIN
sudo systemctl daemon-reload

# --- 9. Don't block boot waiting for the network -----------------------------
# *-wait-online ordering services hold up boot until every managed interface is
# "online", timing out after 120s if one never comes up (e.g. an unplugged
# ethernet port). Nothing here needs the network before login — the kiosk and
# bridge are loopback-only (127.0.0.1:9234) — so disable+mask whichever
# wait-online unit is present. Idempotent; ignores units that don't exist.
log "Disabling network-wait services (they stall boot up to 120s)"
for unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1 \
     && systemctl list-unit-files "$unit" | grep -q "$unit"; then
    sudo systemctl disable "$unit" 2>/dev/null || true
    sudo systemctl mask "$unit"    2>/dev/null || true
  fi
done

# --- 10. Auto-start Sway on tty1 login --------------------------------------
log "Configuring Sway auto-start on tty1"
PROFILE="$HOME/.bash_profile"
MARKER="# >>> tv-launcher sway autostart >>>"
if ! grep -qF "$MARKER" "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" <<'AUTOSTART'

# >>> tv-launcher sway autostart >>>
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  exec sway
fi
# <<< tv-launcher sway autostart <<<
AUTOSTART
fi

log "Done."
echo "  • Interactive: reboot — tty1 auto-logs in '$USER' and Sway starts the kiosk (no password)."
echo "  • Headless check: ./vm/test-launcher.sh  (writes a screenshot)"
echo "  • Exit Sway: Mod+Shift+e   |   Open a terminal: Mod+Enter"
