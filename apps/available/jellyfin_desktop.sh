#!/usr/bin/env bash
# Install Jellyfin Desktop (Flatpak from Flathub).
#
# The old Qt .deb (jellyfin-media-player) hard-depends on libcec6 / Qt5, which
# aren't installable on newer Ubuntu (24.10+ ship libcec7), so the .deb path
# breaks off-LTS. The Flatpak bundles its own runtime and is the client Jellyfin
# now ships — installing the (EOL) media-player app id auto-rebases to this one.
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

JELLYFIN_FLATPAK_ID="${JELLYFIN_FLATPAK_ID:-org.jellyfin.JellyfinDesktop}"

log "Installing Jellyfin ($JELLYFIN_FLATPAK_ID via Flatpak)"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak info "$JELLYFIN_FLATPAK_ID" >/dev/null 2>&1; then
  sudo flatpak install -y --noninteractive flathub "$JELLYFIN_FLATPAK_ID" \
    || warn "Jellyfin Flatpak install failed; re-run, or install it manually. Continuing without it."
fi
