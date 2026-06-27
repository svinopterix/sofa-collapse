#!/usr/bin/env bash
# ============================================================================
# vm/provision.sh
#
# Turn a CLEAN Ubuntu 24.04 LTS install into a Sway-based kiosk running the
# TV launcher (the bridge server + a Chromium kiosk, with all launcher apps
# installed: Chromium, Google Chrome, Spotify, Jellyfin Desktop, Kodi, the
# FCast receiver). Spotify and the FCast receiver are also auto-started at boot
# and kept running in the background (see start-background.sh).
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
  pipewire pipewire-pulse pipewire-audio wireplumber pulseaudio-utils \
  udisks2 udiskie

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

# --- 2b. Let Flatpak media apps read auto-mounted USB drives ----------------
# udiskie (started from the Sway config) mounts USB drives under
# /run/media/$USER/<label>, but Flatpak apps (mpv, VLC, Jellyfin) are sandboxed
# and can't see paths outside their granted filesystem set. Grant every Flatpak
# read access to the mount root so a plugged-in drive's media is browsable. A
# user-level override (no sudo) applied globally; idempotent.
log "Granting Flatpak apps read access to USB mount root (/run/media/$USER)"
if command -v flatpak >/dev/null 2>&1; then
  flatpak override --user "--filesystem=/run/media/$USER:ro" || \
    warn "Could not set Flatpak filesystem override (no Flatpak apps yet?)."
fi

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
# Usage: media-seek.sh playpause|fwd|back|cancel
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
#   Kinogo (chromium --app, chrome-kinogo.ec..)     -> generic web-player keys via
#                                                      wtype (space = play/pause,
#                                                       Right/Left = seek)
#   mpv (native Wayland, app_id="mpv")              -> mpv hotkeys via wtype
#                                                      (space = pause, Right/Left
#                                                       = seek +/-5s). mpv has no
#                                                      MPRIS in the Flatpak, so it
#                                                      must be driven by keys.
#   Kodi (native Wayland, app_id="Kodi")            -> Kodi JSON-RPC HTTP API
#                                                      (Input.ExecuteAction:
#                                                      playpause, stepforward,
#                                                      stepback). NOT wtype:
#                                                      wtype's virtual keyboard
#                                                      crashes Kodi's Wayland
#                                                      input pump (mmap failed
#                                                      -> Kodi exits).
#   anything else (launcher/HOME/unknown)           -> the MPRIS player that is
#                                                      currently Playing, else
#                                                      playerctl's default
#
# The `cancel` action is the remote Back button: in mpv it sends Escape (closes
# an open uosc menu; a no-menu Escape is neutralised by `ESC ignore` in mpv's
# input.conf so it can't un-fullscreen the player); in Kodi it calls JSON-RPC
# Input.ExecuteAction "back" (Kodi's own Back/parent-menu); everywhere else it's
# browser-Back (Alt+Left), exactly what the old standalone XF86Back binding did.
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
  | jq -r '.. | objects | select(.focused==true) | (.app_id // "-"), (.window_properties.class // "-"), (.pid // "-")' \
  | head -3)
focus_app_id="${f[0]:--}"; focus_class="${f[1]:--}"; focus_pid="${f[2]:--}"

# The FCast receiver (a winit app) sets NO app_id and NO class, and its window
# title changes to the media name while a cast plays — so none of those identify
# it during playback (exactly when the media keys are used). Identify it by the
# focused window's process name instead, which is stable.
focus_comm=""
[ "$focus_pid" != "-" ] && focus_comm="$(ps -p "$focus_pid" -o comm= 2>/dev/null | tr -d ' ')"

playing_player() {
  # First MPRIS player reporting Playing; empty if none.
  local p
  while read -r p; do
    [ "$(playerctl --player="$p" status 2>/dev/null)" = "Playing" ] && { printf '%s' "$p"; return; }
  done < <(playerctl -l 2>/dev/null)
}

kodi_action() {
  # Drive Kodi via its JSON-RPC HTTP API, NOT wtype. wtype's virtual-keyboard
  # protocol crashes Kodi's Wayland input pump ("mmap failed: Invalid argument"
  # -> Kodi exits), so synthetic keys are unusable for it. The web server is
  # enabled (services.webserver) with Basic auth kodi:kodi on :8080 by
  # apps/available/kodi.sh. $1 is a Kodi action id (playpause/stepforward/...).
  curl -fsS --max-time 2 -u kodi:kodi -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Input.ExecuteAction\",\"params\":{\"action\":\"$1\"}}" \
    http://127.0.0.1:8080/jsonrpc >/dev/null 2>&1
}

# Back button: close mpv's uosc menu (Escape), Kodi's own Back (Backspace),
# else browser-Back (Alt+Left).
if [ "$action" = "cancel" ]; then
  if [ "$focus_app_id" = "mpv" ]; then
    wtype -k Escape
  elif [ "$focus_app_id" = "Kodi" ]; then
    kodi_action back
  elif [ "$focus_comm" = "fcast-receiver" ]; then
    wtype -k Escape
  else
    wtype -M alt -k Left -m alt
  fi
  exit 0
fi

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
elif [ "$focus_app_id" = "chrome-kinogo.ec__-Default" ]; then
  # Kinogo (chromium --app): a generic HTML5 web video player, NOT YouTube — so
  # the k/l/j hotkeys don't apply. Drive it with the standard web-player keys via
  # wtype (space = play/pause, Right/Left = seek). NB UNVERIFIED — confirm against
  # the live player and adjust (the site may embed the player in an iframe, which
  # can swallow these unless the player has focus).
  case "$action" in
    playpause) wtype -k space ;;
    fwd)       wtype -k Right ;;
    back)      wtype -k Left ;;
  esac
elif [ "$focus_app_id" = "mpv" ]; then
  case "$action" in
    playpause) wtype -k space ;;
    fwd)       wtype -k Right ;;
    back)      wtype -k Left ;;
  esac
elif [ "$focus_app_id" = "Kodi" ]; then
  # Native Wayland, app_id="Kodi" (capitalized). Driven by JSON-RPC, NOT wtype
  # (wtype crashes Kodi's Wayland input pump). See kodi_action above.
  case "$action" in
    playpause) kodi_action playpause ;;
    fwd)       kodi_action stepforward ;;
    back)      kodi_action stepback ;;
  esac
elif [ "$focus_comm" = "fcast-receiver" ]; then
  # FCast receiver: native-Wayland winit app, no MPRIS — so it CANNOT be driven
  # by playerctl, and the generic fallback below would grab the playing MPRIS
  # player (YouTube/Chromium) instead, which is the "keys control YouTube, not
  # the cast" bug. Drive it by key injection (wtype) like mpv. NB: the exact
  # receiver key bindings are UNVERIFIED — confirm against a live cast and adjust
  # (space/Right/Left are the common player defaults).
  case "$action" in
    playpause) wtype -k space ;;
    fwd)       wtype -k Right ;;
    back)      wtype -k Left ;;
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

# Always-on background apps (Spotify, FCast receiver). Started once at Sway
# startup, kept running in the background so they're instantly available — music
# resumes on the Spotify tile, and the FCast receiver is always listening for a
# cast from a phone (e.g. Grayjay). Bound to a Sway `exec` line in the config
# below. See the long comment in the script for why a final launcher raise is
# needed (the boot-time foreground race).
cat > "$LAUNCHER_DST/start-background.sh" <<'BGAPPS'
#!/usr/bin/env bash
# Start the always-on background apps (Spotify, FCast receiver) at boot, then
# raise the launcher so the box settles on the Home screen.
#
# These apps have *persistent* windows, so they don't fit the launcher's normal
# "absent until launched" model: each maps a window at boot that the Sway
# `for_window ... fullscreen enable` rule pulls to the front, and whichever maps
# *last* would otherwise cover Home. We don't add any extra hiding for them — a
# backgrounded app living behind the fullscreen launcher is exactly the resting
# state the remote Home button already produces (go-home.sh). We just wait until
# every window has finished mapping, then raise the launcher *last* (via
# go-home.sh), so the box lands on Home with Spotify/FCast stacked behind it,
# still running. A crashed background app is simply relaunched from its tile
# (focus-or-launch spawns it fresh) — there is deliberately no respawn here.
#
# Running under Sway, this inherits WAYLAND_DISPLAY / SWAYSOCK / XDG_RUNTIME_DIR
# and the audio env, which the launched apps need — the same env that is missing
# when the bridge is restarted from a bare SSH shell.
set -u
LAUNCHER_DST="$HOME/launcher"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
: "${SWAYSOCK:=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1)}"
export SWAYSOCK
# WAYLAND_DISPLAY is inherited from Sway on a normal boot, but derive it if unset
# so this also works from a bare SSH shell. The FCast receiver (a winit app)
# hard-errors without it ("neither WAYLAND_DISPLAY nor ... is set"), like mpv's
# DRM-master fallback — so it must be present before we launch the apps.
: "${WAYLAND_DISPLAY:=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)" 2>/dev/null)}"
export WAYLAND_DISPLAY

# Launch each background app once, detached (setsid) so it outlives this script,
# which exits as soon as it has raised the launcher. Guarded two ways: skip a
# missing app, and — crucially — skip one that is *already running* (pgrep on the
# process name), so a Sway reload or a stray invocation can't pile up a second
# copy. (The duplicate-FCast bug: this script launched one while a leftover
# instance was still alive.)
pgrep -x spotify >/dev/null 2>&1 \
  || { command -v spotify >/dev/null 2>&1 && setsid spotify >/dev/null 2>&1 & }
pgrep -x fcast-receiver >/dev/null 2>&1 \
  || { flatpak info org.fcast.Receiver >/dev/null 2>&1 \
       && setsid flatpak run org.fcast.Receiver >/dev/null 2>&1 & }

# Wait for windows to stop appearing — i.e. the kiosk and both background apps
# have all mapped — then raise the launcher last. We count windows (Sway tree
# nodes that carry a pid) rather than match each app, so this does NOT depend on
# FCast's app_id (still unverified). Break once the count has been stable for
# ~1s *and* the launcher window exists; cap at ~20s so a stuck/absent app can't
# hang the box off Home forever.
count_windows() {
  swaymsg -t get_tree 2>/dev/null \
    | jq '[.. | objects | select(has("pid") and .pid != null)] | length' 2>/dev/null
}
launcher_up() {
  swaymsg -t get_tree 2>/dev/null \
    | jq -e '.. | objects | select(.name? == "TV Launcher")' >/dev/null 2>&1
}
prev=-1; stable=0
for _ in $(seq 1 100); do
  n="$(count_windows)"; n="${n:-0}"
  if [ "$n" = "$prev" ]; then stable=$((stable + 1)); else stable=0; fi
  [ "$stable" -ge 5 ] && launcher_up && break
  prev="$n"
  sleep 0.2
done

# Raise the launcher last so we boot to Home with the background apps behind it.
exec "$LAUNCHER_DST/go-home.sh"
BGAPPS
chmod +x "$LAUNCHER_DST/start-background.sh"

# Cast handler: when the FCast receiver starts playing (a phone casts to it),
# bring it to the foreground and pause everything else; bound to a Sway `exec`
# in the config below. See the script header for why it watches PipeWire.
cat > "$LAUNCHER_DST/fcast-watch.sh" <<'FCASTWATCH'
#!/usr/bin/env bash
# React to the FCast receiver starting/stopping playback (a phone casting to it):
# on cast start, pause every other player and bring FCast to the foreground.
#
# Detection is via PipeWire, NOT Sway/MPRIS, because none of the obvious signals
# are reliable (all verified on the box): FCast registers no MPRIS player, never
# changes its window title, and emits no dependable Sway window event on cast
# start. What it DOES do while playing is open a PipeWire playback sink-input
# named "fcast-receiver" — present while casting, gone when it stops. So we
# subscribe to sink-input changes and act on the rising/falling edge.
#
# Bringing FCast to the front is also what makes the remote's media keys work:
# media-seek.sh routes a key to the *focused* window, and FCast (parked on the
# hidden "bg" workspace, never focused on its own) was being skipped — the keys
# fell through to the still-playing YouTube/Chromium player. Focusing FCast here
# means media-seek.sh then targets it.
set -u
LAUNCHER_DST="$HOME/launcher"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
: "${SWAYSOCK:=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1)}"
export SWAYSOCK

fcast_playing() {
  pactl list sink-inputs 2>/dev/null \
    | grep -q 'application.name = "fcast-receiver"'
}

surface_fcast() {
  # Pause other players (YouTube/Chromium, Spotify — FCast has no MPRIS so it is
  # untouched), then focus FCast by pid so it comes to the foreground regardless
  # of which workspace it is parked on (and becomes the media-key target).
  playerctl --all-players pause 2>/dev/null || true
  local pid
  pid="$(swaymsg -t get_tree 2>/dev/null \
    | jq -r '.. | objects | select(.pid? != null and (.name? == "FCast Receiver")) | .pid' \
    | head -1)"
  if [ -n "$pid" ] && [ "$pid" != "null" ]; then
    swaymsg "[pid=$pid] focus" >/dev/null 2>&1
  else
    swaymsg '[title="FCast Receiver"] focus' >/dev/null 2>&1
  fi
}

# Poll the stream state once a second and act only on a 0->1 transition (cast
# just started). Polling rather than `pactl subscribe | grep`: subscribe's
# stdout is block-buffered through a pipe, so low-volume events arrive late or
# not at all — a 1s poll is robust and the latency is unnoticeable. Cast STOP is
# intentionally a no-op — FCast just shows its idle screen and the user returns
# Home with the remote; this also avoids flapping if a stream briefly drops
# mid-cast. (A paused cast stays a corked sink-input, so pausing isn't a stop.)
last=0
while sleep 1; do
  if fcast_playing; then now=1; else now=0; fi
  [ "$now" = "$last" ] && continue
  last="$now"
  [ "$now" = 1 ] && surface_fcast
done
FCASTWATCH
chmod +x "$LAUNCHER_DST/fcast-watch.sh"

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

# Always-on background apps (Spotify, FCast receiver) start at boot, but must not
# flash in front of the launcher while the box comes up (they used to sit in the
# foreground for several seconds before the launcher was raised). Park them on a
# dedicated hidden workspace "bg" as their windows map — the rule fires at map
# time, before the window is shown, so they never appear on the visible
# workspace. The home screen is then the only thing on workspace 1 at boot.
# focus-or-launch (their tile) and the cast handler bring them onto the visible
# workspace on demand: \`[criteria] focus\` switches to whatever workspace the
# window is on, and go-home.sh switches back. FCast has no app_id/class (winit),
# so it is matched by title; Spotify is Xwayland, matched by class.
for_window [title="FCast Receiver"] move container to workspace bg
for_window [class="Spotify"] move container to workspace bg

# Auto-mount USB-attached drives. udiskie watches udisks2 and mounts removable
# media — both drives already plugged in at login and any hot-plugged after —
# under /run/media/\$USER/<label>, with no file-manager/desktop needed. udisks2's
# polkit rules grant the active local (tty1 autologin) session mount rights
# without a password. --no-tray (this kiosk has no tray/status bar) and
# --no-notify (no notification daemon runs here) keep it headless; -a forces
# automount on. The Flatpak media apps are granted read access to the mount root
# in provision.sh (step 2b) so they can actually browse the drives.
exec udiskie --no-tray --no-notify --automount

# Launch the launcher kiosk on Sway start.
exec "\$HOME/launcher/start-kiosk.sh"

# Start the always-on background apps (Spotify, FCast receiver) and then raise
# the launcher, so the box boots to the home screen with them running behind it
# (Spotify ready to resume; FCast always listening for a cast). See
# start-background.sh for why the final raise is needed.
exec "\$HOME/launcher/start-background.sh"

# Cast handler: bring FCast to the foreground + pause other players when a phone
# starts casting to it (detected via its PipeWire stream). See fcast-watch.sh.
exec "\$HOME/launcher/fcast-watch.sh"

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

  # Plymouth only draws a *graphical* splash if a KMS/DRM framebuffer is up
  # EARLY — i.e. the GPU's DRM driver has to be inside the initramfs. This box
  # uses dracut in host-only mode, and dracut does NOT pull the GPU driver into
  # the initramfs by default. Without it, Plymouth silently falls back to TEXT
  # mode: no splash, and the raw boot console shows through — including the
  # benign, unconditional dracut "Kernel command line option 'copymods' is
  # deprecated" warning (printed every boot by Ubuntu's copymods dracut module,
  # regardless of the cmdline). Forcing the in-use DRM driver in fixes the splash
  # and, by covering the console, hides that warning. Detect the driver from the
  # live GPU so this isn't hardcoded to one machine (here: i915, Intel CometLake).
  DRM_DRIVERS="$(for d in /sys/class/drm/card[0-9]*/device/driver; do
                   [ -e "$d" ] && basename "$(readlink -f "$d")"
                 done | sort -u | paste -sd' ' -)"
  if [ -n "$DRM_DRIVERS" ]; then
    if command -v dracut >/dev/null 2>&1; then
      log "Forcing DRM driver(s) into initramfs (dracut): $DRM_DRIVERS"
      sudo install -d /etc/dracut.conf.d
      printf 'force_drivers+=" %s "\n' "$DRM_DRIVERS" \
        | sudo tee /etc/dracut.conf.d/10-sofa-drm.conf >/dev/null
    else
      log "Adding DRM driver(s) to initramfs-tools modules: $DRM_DRIVERS"
      for m in $DRM_DRIVERS; do
        grep -qxF "$m" /etc/initramfs-tools/modules 2>/dev/null \
          || echo "$m" | sudo tee -a /etc/initramfs-tools/modules >/dev/null
      done
    fi
  else
    warn "Could not detect a DRM driver; Plymouth splash may fall back to text mode."
  fi

  # Make sofa-splash the default theme and rebuild the initramfs so it's present
  # early at boot. Newer Ubuntu (plymouth 24.x) dropped the plymouth-set-default-theme
  # helper, so select the theme via update-alternatives on default.plymouth; fall
  # back to the old helper if it's still around (older releases). The rebuild here
  # is also what bakes the DRM driver forced just above into the initramfs.
  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    sudo plymouth-set-default-theme -R sofa-splash
  else
    sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
      default.plymouth "$SPLASH_THEME_DIR/sofa-splash.plymouth" 200
    sudo update-alternatives --set default.plymouth "$SPLASH_THEME_DIR/sofa-splash.plymouth"
    sudo update-initramfs -u
  fi
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
