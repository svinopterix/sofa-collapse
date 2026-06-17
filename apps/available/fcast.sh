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
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Installing FCast receiver (Flatpak: org.fcast.Receiver)"
if ! flatpak info org.fcast.Receiver >/dev/null 2>&1; then
  flatpak install -y --noninteractive flathub org.fcast.Receiver
fi
