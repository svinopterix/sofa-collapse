#!/usr/bin/env bash
# Install VLC media player (Flatpak from Flathub).
#
# Flatpak is preferred for GUI apps off-LTS: it bundles its own runtime and
# sidesteps Ubuntu dep skew. The Flathub remote is set up by provision.sh (and
# re-added here so this is standalone-runnable). Launch via `flatpak run`.
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

VLC_FLATPAK_ID="${VLC_FLATPAK_ID:-org.videolan.VLC}"

log "Installing VLC ($VLC_FLATPAK_ID via Flatpak)"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak info "$VLC_FLATPAK_ID" >/dev/null 2>&1; then
  sudo flatpak install -y --noninteractive flathub "$VLC_FLATPAK_ID" \
    || warn "VLC Flatpak install failed; re-run, or install it manually. Continuing without it."
fi
