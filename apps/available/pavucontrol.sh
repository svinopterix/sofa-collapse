#!/usr/bin/env bash
# Install pavucontrol (the PulseAudio/PipeWire volume-control GUI).
#
# Standalone-runnable (run as your normal sudo user) and idempotent. Ships in
# the default Ubuntu repos, so we refresh the apt cache first in case this is
# run on its own (provision.sh has already updated when run in the full flow).
set -euo pipefail
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Installing pavucontrol"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pavucontrol
