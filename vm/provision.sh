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
  python3 \
  jq curl wget gnupg ca-certificates apt-transport-https \
  fonts-noto-core fonts-noto-color-emoji

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
cp "$LAUNCHER_SRC/index.html" "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/apps.json"  "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/server.py"  "$LAUNCHER_DST/"
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
exec swaymsg '[title="TV Launcher"] focus, fullscreen enable'
GOHOME
chmod +x "$LAUNCHER_DST/go-home.sh"

# --- 7. Sway config: run the kiosk, hide cursor, easy exit ------------------
log "Writing Sway config"
mkdir -p "$SWAY_CFG_DIR"
cat > "$SWAY_CFG_DIR/config" <<SWAY
# Generated by vm/provision.sh — kiosk config for the TV launcher.
set \$mod Mod4

# Solid background; hide the pointer when idle.
output * bg #0a0c10 solid_color
seat * hide_cursor 2000

# Make the kiosk fill the screen with no decorations.
default_border none

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

# Remote control keys.
# i25 Mini "Home" button -> back to the launcher home screen. These remotes
# emit the Android Home key as XF86HomePage (Linux KEY_HOMEPAGE). If your unit
# sends a different key, run \`wev\` over SSH, press Home, and replace the keysym
# below (then \`swaymsg reload\`). \`wev\` also lets you map Back/Menu/etc. later.
bindsym XF86HomePage exec "\$HOME/launcher/go-home.sh"

# Escape hatches for testing.
bindsym \$mod+Shift+e exit
bindsym \$mod+Return exec foot
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

# --- 9. Auto-start Sway on tty1 login ---------------------------------------
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
