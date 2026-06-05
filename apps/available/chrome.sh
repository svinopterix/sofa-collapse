#!/usr/bin/env bash
# Install Google Chrome (official apt repo).
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Installing Google Chrome"
if [ ! -f /etc/apt/keyrings/google-chrome.gpg ]; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
fi
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
  | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
