#!/usr/bin/env bash
# ============================================================================
# vm/provision.sh
#
# Turn a CLEAN Ubuntu 24.04 LTS install into a Sway-based kiosk running the
# TV launcher (the bridge server + a Chromium kiosk, with all launcher apps
# installed: Chromium, Google Chrome, Spotify, Jellyfin Desktop).
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
SPLASH_SRC="$REPO_ROOT/vm/media/boot_splash.png"

# Per-app installers live in apps/available/ and are enabled by symlinking them
# into apps/install/ (sites-available/sites-enabled style). provision.sh runs
# every *.sh in apps/install/ below — to add or drop an app's install, add a
# script in apps/available/ and (un)link it in apps/install/. Each script is
# standalone-runnable and idempotent.
APPS_INSTALL="$REPO_ROOT/apps/install"

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
  flatpak \
  jq curl wget gnupg ca-certificates apt-transport-https \
  fonts-noto-core fonts-noto-color-emoji \
  language-pack-ru \
  pipewire pipewire-pulse pipewire-audio wireplumber pulseaudio-utils

# A minimal Sway install ships no sound server, so launched apps (Spotify, Jellyfin)
# have nothing to play through. Enable the PipeWire user services so they start
# with the sofa session. Run as the user (NOT via sudo) so they land in the
# right systemd --user instance; harmless if already enabled.
log "Enabling PipeWire user audio services"
systemctl --user enable --now pipewire pipewire-pulse wireplumber 2>/dev/null \
  || warn "Could not enable PipeWire user services now (no user session?); they are enabled and will start on next login."

# --- 2. Launcher apps (Chromium, Google Chrome, Spotify, Jellyfin, …) -------
# Each app's installer is its own idempotent script in apps/available/, enabled
# by a symlink in apps/install/. Run every enabled installer in turn (sorted by
# name). To add/remove an app's install, drop a script in apps/available/ and
# (un)link it in apps/install/ — no edit here needed.
log "Installing launcher apps from $APPS_INSTALL"
shopt -s nullglob
for app_script in "$APPS_INSTALL"/*.sh; do
  log "Running $(basename "$app_script")"
  bash "$app_script"
done
shopt -u nullglob

# --- 3. Deploy the launcher (bridge + UI) -----------------------------------
log "Deploying launcher to $LAUNCHER_DST"
mkdir -p "$LAUNCHER_DST"
cp "$LAUNCHER_SRC/index.html"       "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/apps.json"        "$LAUNCHER_DST/"
cp "$LAUNCHER_SRC/system.json"      "$LAUNCHER_DST/"
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

# State-aware media keys (Play/Pause, Fast-Forward, Rewind) bound to the
# remote's media buttons in keybindings.yaml. Routes each key to whatever app is
# actually *on screen* and does the natural thing for it. Needs playerctl
# (MPRIS), wtype (key injection) and swaymsg, all installed/present above.
cat > "$LAUNCHER_DST/media-seek.sh" <<'SEEK'
#!/usr/bin/env bash
# Usage: media-seek.sh playpause|fwd|back
#
# Routes a remote media key to whatever app is actually on screen, decided by
# the *focused* Sway window. We deliberately do NOT use the bridge's /state:
# /state tracks the last *launched* app and is blank (app=null) on HOME, so it
# drifts from the window you're looking at. And a bare `playerctl play-pause`
# (no --player) controls the first MPRIS player it lists -- usually
# Chromium/YouTube -- so it'd pause YouTube even while Spotify is in front.
#
#   Spotify (Xwayland, class="Spotify")             -> playerctl --player=spotify
#   YouTube (chromium --app, chrome-www.youtube..)  -> YouTube hotkeys via wtype
#                                                      (k = play/pause, l = +10s,
#                                                       j = -10s)
#   anything else (launcher/HOME/unknown)           -> the MPRIS player that is
#                                                      currently Playing, else
#                                                      playerctl's default
#
# wtype needs WAYLAND_DISPLAY and swaymsg needs SWAYSOCK. A remote keybinding
# normally inherits both from Sway, but derive them if missing so this also
# works when invoked from a plain SSH shell.
set -u
action="${1:-playpause}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
: "${WAYLAND_DISPLAY:=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)" 2>/dev/null)}"
export WAYLAND_DISPLAY
: "${SWAYSOCK:=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1)}"
export SWAYSOCK

# Focused window. Xwayland apps (Spotify) have app_id=null and must be matched by
# class; chromium --app pages carry a per-URL app_id. jq emits app_id then class
# (one per line) for the focused node; head -2 guards against odd trees.
mapfile -t f < <(swaymsg -t get_tree 2>/dev/null \
  | jq -r '.. | objects | select(.focused==true) | (.app_id // "-"), (.window_properties.class // "-")' \
  | head -2)
focus_app_id="${f[0]:--}"; focus_class="${f[1]:--}"

playing_player() {
  # First MPRIS player reporting Playing; empty if none.
  local p
  while read -r p; do
    [ "$(playerctl --player="$p" status 2>/dev/null)" = "Playing" ] && { printf '%s' "$p"; return; }
  done < <(playerctl -l 2>/dev/null)
}

if [ "$focus_class" = "Spotify" ]; then
  case "$action" in
    playpause) playerctl --player=spotify play-pause ;;
    fwd)       playerctl --player=spotify next ;;
    back)      playerctl --player=spotify previous ;;
  esac
elif [ "$focus_app_id" = "chrome-www.youtube.com__-Default" ]; then
  case "$action" in
    playpause) wtype k ;;
    fwd)       wtype l ;;
    back)      wtype j ;;
  esac
else
  p="$(playing_player)"
  set -- ${p:+--player=$p}
  case "$action" in
    playpause) playerctl "$@" play-pause ;;
    fwd)       playerctl "$@" next ;;
    back)      playerctl "$@" previous ;;
  esac
fi
SEEK
chmod +x "$LAUNCHER_DST/media-seek.sh"

# --- 4. Sway config: run the kiosk, hide cursor, easy exit ------------------
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

# Stack windows instead of tiling them. Apps launched from the kiosk pile up as
# siblings on one workspace; with the default tiled layout, the only thing
# hiding the others is whichever window is fullscreen — so exiting fullscreen
# (e.g. Spotify's own toggle) exposes a broken 2-3-way tile grid. Stacking keeps
# exactly one window visible at all times, fullscreen or not: leaving fullscreen
# falls back to a single stacked window (with a thin title bar) instead of a
# tiled grid. With default_border none the title bar is the only chrome, and it
# is never seen during normal use since launched apps are always fullscreened.
workspace_layout stacking

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

# --- 5. Auto-login on tty1 --------------------------------------------------
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

# --- 6. Speed up boot --------------------------------------------------------
# (a) *-wait-online ordering services hold up boot until every managed interface
# is "online", timing out after 120s if one never comes up (e.g. an unplugged
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

# (b) Trim the GRUB menu countdown to 1s (this box boots straight to the kiosk;
# no need to sit on the boot menu). Rewrite GRUB_TIMEOUT in place if present,
# else append; then regenerate grub.cfg. Idempotent.
if [ -f /etc/default/grub ]; then
  log "Setting GRUB menu timeout to 1s"
  if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
  else
    echo 'GRUB_TIMEOUT=1' | sudo tee -a /etc/default/grub >/dev/null
  fi
  # Ensure the kernel boots with "quiet splash" so Plymouth (the boot splash set
  # up in 6c below) takes over the screen instead of kernel log spam.
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
  else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' | sudo tee -a /etc/default/grub >/dev/null
  fi
  if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub
  else
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  fi
fi

# --- 6c. Boot splash (Plymouth) ---------------------------------------------
# Show vm/media/boot_splash.png full-screen during boot/shutdown instead of
# kernel log spam. Install Plymouth, drop a minimal "script" theme that centers
# the image (scaled to fit) on the kiosk's background color, make it the default,
# and rebuild the initramfs (-R) so the splash is present early at boot. The
# "quiet splash" cmdline added in 6b is what tells the kernel to show it.
if [ -f "$SPLASH_SRC" ]; then
  log "Installing boot splash (Plymouth)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y plymouth plymouth-themes
  SPLASH_THEME_DIR="/usr/share/plymouth/themes/sofa-splash"
  sudo install -d "$SPLASH_THEME_DIR"
  sudo install -m 0644 "$SPLASH_SRC" "$SPLASH_THEME_DIR/boot_splash.png"

  sudo tee "$SPLASH_THEME_DIR/sofa-splash.plymouth" >/dev/null <<'PLYMOUTH'
[Plymouth Theme]
Name=Sofa Splash
Description=Sofa-collapse boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/sofa-splash
ScriptFile=/usr/share/plymouth/themes/sofa-splash/sofa-splash.script
PLYMOUTH

  # Plymouth "script" language: center the image and scale it to *cover* the
  # whole screen (preserving aspect ratio, cropping the overflow), on the kiosk
  # background (#0a0c10) which only shows if scaling can't fully cover.
  sudo tee "$SPLASH_THEME_DIR/sofa-splash.script" >/dev/null <<'SCRIPT'
Window.SetBackgroundTopColor(0.039, 0.047, 0.063);
Window.SetBackgroundBottomColor(0.039, 0.047, 0.063);

screen_width  = Window.GetWidth();
screen_height = Window.GetHeight();

image = Image("boot_splash.png");
img_w = image.GetWidth();
img_h = image.GetHeight();

scale = screen_width / img_w;
scale_y = screen_height / img_h;
if (scale_y > scale)
    scale = scale_y;

splash = image.Scale(img_w * scale, img_h * scale);
sprite = Sprite(splash);
sprite.SetX(screen_width  / 2 - splash.GetWidth()  / 2);
sprite.SetY(screen_height / 2 - splash.GetHeight() / 2);
SCRIPT

  sudo plymouth-set-default-theme -R sofa-splash
else
  warn "Splash image not found at $SPLASH_SRC; skipping boot splash setup."
fi

# --- 7. Auto-start Sway on tty1 login --------------------------------------
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
