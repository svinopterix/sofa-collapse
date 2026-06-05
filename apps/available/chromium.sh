#!/usr/bin/env bash
# Install Chromium (snap) — also used as the kiosk shell, and the runtime for
# the YouTube launcher tile (a Chromium --app window).
#
# Ubuntu's chromium is a snap; the snap command is `chromium`. The launcher
# tile uses `chromium-browser`, so we add a compatibility symlink.
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Installing Chromium (snap)"
if ! snap list chromium >/dev/null 2>&1; then
  sudo snap install chromium
fi
if [ ! -e /usr/local/bin/chromium-browser ]; then
  sudo ln -sf "$(command -v chromium || echo /snap/bin/chromium)" /usr/local/bin/chromium-browser
fi
