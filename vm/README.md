# Testing the launcher in a VM (Ubuntu 24.04 + Sway)

Three steps: **create** a clean Ubuntu 24.04 VM, **provision** it with `provision.sh`
(installs Sway + Chromium/Chrome/Spotify + Jellyfin Desktop + the launcher), then **test**.

The provisioning script targets **Sway (Wayland)** and drives the kiosk from
Sway's config — it deliberately does *not* use the production `tv-launcher-*.service`
units, which are Openbox/X11-specific.

## 1. Create the VM

Pick whichever you prefer (all installed on this host):

### Option A — multipass (fast, headless, fully scriptable)
Best for the automated screenshot test. No GUI; you verify via `test-launcher.sh`.

```bash
multipass launch 24.04 --name launcher-test --cpus 2 --memory 4G --disk 20G
multipass mount "$PWD" launcher-test:/home/ubuntu/sofa-collapse   # share this repo
multipass shell launcher-test
# inside the VM:
cd ~/sofa-collapse && ./vm/provision.sh && ./vm/test-launcher.sh
multipass transfer launcher-test:/home/ubuntu/launcher-test.png ./launcher-test.png   # (from host)
```

### Option B — QEMU/KVM or VirtualBox (real display, interactive)
Best to *see* the kiosk and actually launch the apps. Install Ubuntu 24.04 Desktop
(or Server) from an ISO, then copy this repo in (shared folder or `git clone`) and:

```bash
cd ~/sofa-collapse && ./vm/provision.sh
# log out / reboot — Sway auto-starts the kiosk on tty1
```

## 2. Provision

`./vm/provision.sh` (run as your normal sudo user, inside the VM). Idempotent.

Jellyfin is installed as a **Flatpak** from Flathub (`org.jellyfin.JellyfinDesktop`).
The old Qt `.deb` (`jellyfin-media-player`) hard-depends on libcec6/Qt5, which
aren't installable on newer Ubuntu (24.10+ ship libcec7), so the Flatpak — which
bundles its own runtime — is used instead. Override the app id if needed:

```bash
JELLYFIN_FLATPAK_ID="org.jellyfin.JellyfinDesktop" ./vm/provision.sh
```

## 3. Test

- **Interactive (Option B):** after provisioning, log in on tty1 — Sway launches
  the bridge + Chromium kiosk. `Mod+Shift+e` exits Sway, `Mod+Enter` opens a terminal.
- **Headless (Option A):** `./vm/test-launcher.sh` runs Sway on the wlroots headless
  backend and writes `~/launcher-test.png`. This confirms the launcher UI paints and
  the bridge answers; launching real app windows needs a real display (Option B).
