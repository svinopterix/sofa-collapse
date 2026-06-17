#!/usr/bin/env bash
# Install the FCast receiver (Flatpak / Flathub).
#
# FCast (https://fcast.org) is FUTO's open casting protocol; this is the
# receiver that runs on the box so a phone (e.g. Grayjay) can cast to it. It is
# started at boot and kept running in the background by the Sway config (see
# start-background.sh, generated in vm/provision.sh) so casting is always
# available. The Flatpak bundles its own runtime, sidestepping Ubuntu dep skew.
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

FCAST_FLATPAK_ID="${FCAST_FLATPAK_ID:-org.fcast.Receiver}"

# Install system-wide with sudo, like the other Flatpak apps. A plain (system)
# `flatpak install` needs polkit authorization, which is absent over a
# non-interactive SSH shell ("Deploy not allowed for user") — sudo avoids that.
log "Installing FCast receiver ($FCAST_FLATPAK_ID via Flatpak)"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak info "$FCAST_FLATPAK_ID" >/dev/null 2>&1; then
  sudo flatpak install -y --noninteractive flathub "$FCAST_FLATPAK_ID" \
    || warn "FCast Flatpak install failed; re-run, or install it manually. Continuing without it."
fi
