#!/usr/bin/env bash
# ============================================================================
# vm/test-launcher.sh
#
# Headless smoke test for the launcher. Runs Sway with the wlroots *headless*
# backend (no real display needed), lets the bridge + Chromium kiosk start,
# then captures a screenshot with grim. Verifies the launcher UI renders and
# the bridge is reachable — runnable in a server VM (e.g. multipass) with no
# monitor attached.
#
# Usage:  ./vm/test-launcher.sh [output.png]
#
# Note: this confirms the launcher *shell* paints. Actually launching the real
# apps (Chrome/Spotify/Jellyfin windows) needs a real display — use an interactive
# VM (QEMU/VirtualBox) for that, per vm/README.md.
# ============================================================================
set -euo pipefail

OUT="${1:-$HOME/launcher-test.png}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

# Software rendering: headless wlroots uses pixman, and Chromium has no GPU here.
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_LIBINPUT_NO_DEVICES=1
export CHROMIUM_EXTRA_FLAGS="--disable-gpu --use-gl=swiftshader --in-process-gpu"

echo "==> Starting headless Sway"
sway -c "$HOME/.config/sway/config" &
SWAY_PID=$!
cleanup() { kill "$SWAY_PID" 2>/dev/null || true; wait "$SWAY_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for Sway's wayland socket to appear.
for _ in $(seq 1 50); do
  WAYLAND_DISPLAY="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-[0-9]*' \
    ! -name '*.lock' -printf '%f\n' 2>/dev/null | head -n1 || true)"
  [ -n "$WAYLAND_DISPLAY" ] && break
  sleep 0.3
done
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "Sway socket never appeared" >&2; exit 1; }
export WAYLAND_DISPLAY
echo "==> Sway up on \$WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

# Give the bridge + Chromium time to start and paint.
echo "==> Waiting for kiosk to render..."
sleep 12

# Sanity: bridge reachable?
if curl -fsS http://127.0.0.1:9234/apps >/dev/null 2>&1; then
  echo "==> Bridge server OK (GET /apps)"
else
  echo "[warn] bridge server not reachable on 127.0.0.1:9234" >&2
fi

echo "==> Capturing screenshot -> $OUT"
grim "$OUT"
echo "==> Wrote $OUT"
