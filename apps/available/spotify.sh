#!/usr/bin/env bash
# Install Spotify (snap).
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Installing Spotify (snap)"
if ! snap list spotify >/dev/null 2>&1; then
  sudo snap install spotify
fi
