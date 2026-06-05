#!/usr/bin/env bash
# Install mpv (Flatpak from Flathub) + the uosc on-screen UI.
#
# mpv is the lightest serious player, but stock mpv has no real UI and its OSC
# buttons are tiny — not couch-friendly. uosc (https://github.com/tomasklaen/uosc)
# replaces it with a large, clean, remote-navigable controller. We install both
# and write an mpv.conf that disables the stock OSC so uosc owns the UI.
#
# uosc lives in mpv's *config* dir. For the Flatpak that's
# ~/.var/app/io.mpv.Mpv/config/mpv/ (the per-app sandbox config), which we
# create ourselves so this works before mpv's first run. The uosc release zip
# already lays out scripts/, fonts/ and script-opts/ in the right places.
#
# Flatpak is preferred for GUI apps off-LTS: it bundles its own runtime and
# sidesteps Ubuntu dep skew. The Flathub remote is set up by provision.sh (and
# re-added here so this is standalone-runnable). Launch via `flatpak run`.
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

MPV_FLATPAK_ID="${MPV_FLATPAK_ID:-io.mpv.Mpv}"
MPV_CONFIG_DIR="${MPV_CONFIG_DIR:-$HOME/.var/app/$MPV_FLATPAK_ID/config/mpv}"
UOSC_URL="https://github.com/tomasklaen/uosc/releases/latest/download/uosc.zip"

log "Installing mpv ($MPV_FLATPAK_ID via Flatpak)"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak info "$MPV_FLATPAK_ID" >/dev/null 2>&1; then
  sudo flatpak install -y --noninteractive flathub "$MPV_FLATPAK_ID" \
    || warn "mpv Flatpak install failed; re-run, or install it manually. Continuing without it."
fi

# unzip is needed to unpack the uosc release.
if ! command -v unzip >/dev/null 2>&1; then
  log "Installing unzip (needed to unpack uosc)"
  sudo apt-get install -y unzip || warn "could not install unzip; uosc step may fail"
fi

log "Installing uosc into $MPV_CONFIG_DIR"
mkdir -p "$MPV_CONFIG_DIR"
if [ ! -f "$MPV_CONFIG_DIR/scripts/uosc/main.lua" ] || [ "${UOSC_REFRESH:-0}" = "1" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  if curl -fsSL "$UOSC_URL" -o "$tmp/uosc.zip"; then
    unzip -oq "$tmp/uosc.zip" -d "$MPV_CONFIG_DIR"
  else
    warn "uosc download failed; mpv will still work with the stock OSC. Re-run to retry."
  fi
else
  log "uosc already present (set UOSC_REFRESH=1 to update)"
fi

# mpv.conf — hand the UI to uosc and make playback couch-friendly.
# osc=no/border=no are uosc's required settings; keep-open stops mpv quitting at
# end-of-file and idle=yes/force-window=yes keep the window up with no file (so a
# launch never just flashes back to the launcher — the tile passes these too, but
# baking them in makes a bare `flatpak run io.mpv.Mpv` behave the same);
# hwdec=auto uses GPU decode. Written only if absent, so local tweaks survive.
if [ ! -f "$MPV_CONFIG_DIR/mpv.conf" ]; then
  log "Writing $MPV_CONFIG_DIR/mpv.conf"
  cat > "$MPV_CONFIG_DIR/mpv.conf" <<'CONF'
# Managed by apps/available/mpv.sh — uosc provides the on-screen UI.
osc=no
border=no
fullscreen=yes
idle=yes
force-window=yes
keep-open=yes
hwdec=auto
CONF
else
  log "mpv.conf already exists; leaving it untouched"
fi

# input.conf — remote-friendly file opening. The remote's OK button reaches mpv
# as Enter (only the labelled media/Home keys are grabbed by Sway; the D-pad and
# OK pass through). Binding Enter to uosc's file browser works even on mpv's idle
# "no file" screen, where uosc draws no clickable controls. The `#!` comments add
# the same actions to uosc's menu (the hamburger button), so an air-mouse user
# can reach them by pointing too. uosc's menus are navigated with the D-pad + OK.
if [ ! -f "$MPV_CONFIG_DIR/input.conf" ]; then
  log "Writing $MPV_CONFIG_DIR/input.conf"
  cat > "$MPV_CONFIG_DIR/input.conf" <<'CONF'
# Managed by apps/available/mpv.sh — couch/remote bindings for uosc.
ENTER     script-binding uosc/open-file
KP_ENTER  script-binding uosc/open-file
o         script-binding uosc/open-file   #! Open file
P         script-binding uosc/items       #! Playlist
q         quit                            #! Quit
# The remote Back button (routed by media-seek.sh to a real Escape) closes an
# open uosc menu — uosc grabs Esc with a forced binding while a menu is up. But
# mpv's *default* Esc is "exit fullscreen", which would un-fullscreen the player
# when no menu is open (Sway then tiles it). Neutralise that default so a stray
# Back on the playback screen is a harmless no-op; uosc's menu-close still wins.
ESC       ignore
CONF
else
  log "input.conf already exists; leaving it untouched"
fi
