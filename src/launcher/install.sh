#!/usr/bin/env bash
# tv-launcher install script
# Run as your regular user (not root).
set -euo pipefail

LAUNCHER_DIR="$HOME/launcher"
SYSTEMD_DIR="$HOME/.config/systemd/user"

echo "==> Installing TV Launcher to $LAUNCHER_DIR"

# Copy files
mkdir -p "$LAUNCHER_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/index.html"  "$LAUNCHER_DIR/"
cp "$SCRIPT_DIR/apps.json"   "$LAUNCHER_DIR/"
cp "$SCRIPT_DIR/server.py"   "$LAUNCHER_DIR/"
chmod +x "$LAUNCHER_DIR/server.py"

# Install systemd user units
mkdir -p "$SYSTEMD_DIR"
sed "s|%h|$HOME|g" "$SCRIPT_DIR/tv-launcher-bridge.service" > "$SYSTEMD_DIR/tv-launcher-bridge.service"
sed "s|%h|$HOME|g" "$SCRIPT_DIR/tv-launcher-kiosk.service"  > "$SYSTEMD_DIR/tv-launcher-kiosk.service"

systemctl --user daemon-reload
systemctl --user enable tv-launcher-bridge.service
systemctl --user enable tv-launcher-kiosk.service

echo ""
echo "✓ Installed. To start now:"
echo "  systemctl --user start tv-launcher-bridge"
echo "  systemctl --user start tv-launcher-kiosk"
echo ""
echo "✓ Edit apps:  nano $LAUNCHER_DIR/apps.json"
echo "✓ Logs:       journalctl --user -u tv-launcher-bridge -f"
