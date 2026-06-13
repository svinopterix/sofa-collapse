#!/usr/bin/env bash
# Install Kodi (Flatpak from Flathub) + seed a minimalist, local-files-first
# config.
#
# Flatpak is preferred for GUI apps off-LTS: it bundles its own runtime and
# sidesteps Ubuntu dep skew. The Flathub remote is set up by provision.sh (and
# re-added here so this is standalone-runnable). Launch via `flatpak run`.
#
# Two things make this more than a bare `flatpak install`:
#   1. Filesystem access. The Flatpak is sandboxed and can't see the host's
#      removable media by default. The box automounts drives under /run/media,
#      so we grant Kodi access to exactly that path (persistent --user override;
#      the launcher tile also passes --filesystem=/run/media at run time so a
#      stock `flatpak run` works even if this override was never applied).
#   2. Minimalist, local-files-focused UI. We pre-seed Kodi's userdata before
#      its first run:
#        - sources.xml adds a "Media" source pointing at /run/media for Videos,
#          Music, Pictures and the file manager — the closest Kodi has to a
#          "default path" (Kodi has no single startup path; a source named per
#          section is the idiomatic way to make it the entry point).
#        - addon_data/skin.estuary/settings.xml hides the stock Estuary home
#          menu items that aren't local files (library Movies/TV Shows, Live
#          TV/Radio, Music Videos, Add-ons/Programs, Games, Weather), leaving
#          Videos, Music, Pictures and Favourites. Estuary is Kodi's built-in
#          skin — no fragile third-party skin download — pared down to the
#          essentials. This is best-effort: it's still adjustable live via
#          Settings > Interface > Skin > Configure skin.
#
# Kodi's Flatpak userdata lives at ~/.var/app/tv.kodi.Kodi/data/userdata
# (XDG_DATA_HOME for the sandboxed app — *not* data/.kodi/...). Seeded files are
# written only if absent, so local tweaks survive a re-run.
#
# Standalone-runnable (run as your normal sudo user) and idempotent.
set -euo pipefail
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

KODI_FLATPAK_ID="${KODI_FLATPAK_ID:-tv.kodi.Kodi}"
KODI_DATA_DIR="${KODI_DATA_DIR:-$HOME/.var/app/$KODI_FLATPAK_ID/data}"
KODI_USERDATA="$KODI_DATA_DIR/userdata"
MEDIA_PATH="${KODI_MEDIA_PATH:-/run/media/}"

log "Installing Kodi ($KODI_FLATPAK_ID via Flatpak)"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak info "$KODI_FLATPAK_ID" >/dev/null 2>&1; then
  sudo flatpak install -y --noninteractive flathub "$KODI_FLATPAK_ID" \
    || warn "Kodi Flatpak install failed; re-run, or install it manually. Continuing without it."
fi

# Let the sandbox read the automounted removable media. Narrow on purpose —
# only /run/media, not the whole host.
log "Granting Kodi filesystem access to $MEDIA_PATH"
flatpak override --user --filesystem="${MEDIA_PATH%/}" "$KODI_FLATPAK_ID" \
  || warn "flatpak override failed; the tile still passes --filesystem at run time"

mkdir -p "$KODI_USERDATA"

# Enable Kodi's JSON-RPC HTTP server. The launcher's remote media keys
# (media-seek.sh) drive Kodi through this API instead of synthetic keystrokes:
# wtype's Wayland virtual-keyboard protocol crashes Kodi's input pump
# ("Exception in Wayland message pump, exiting: mmap failed" -> Kodi quits), so
# JSON-RPC is the only reliable way to send it play/pause/seek. Basic auth
# kodi:kodi on :8080 — the web server binds all interfaces, so the password
# (weak, but present) is the only guard; fine for a single-user box on a
# trusted LAN, consistent with the rest of this appliance's threat model.
# Settings live in guisettings.xml, which Kodi rewrites on exit, so this must
# run while Kodi is STOPPED (true at provision time). Idempotent: patches the
# keys in place if the file exists, else creates a minimal one Kodi fills out.
log "Enabling Kodi JSON-RPC web server (port 8080, user kodi)"
KODI_USERDATA="$KODI_USERDATA" python3 - <<'PY' || warn "could not seed Kodi web-server settings; enable it in Settings > Services > Control"
import os, re
p = os.path.join(os.environ["KODI_USERDATA"], "guisettings.xml")
s = open(p).read() if os.path.exists(p) else '<settings version="2">\n</settings>\n'
def setval(s, sid, val):
    pat = re.compile(r'<setting id="%s"[^>]*?(?:/>|>.*?</setting>)' % re.escape(sid))
    repl = '<setting id="%s">%s</setting>' % (sid, val)
    return pat.sub(repl, s, count=1) if pat.search(s) \
        else s.replace('</settings>', '    %s\n</settings>' % repl)
for sid, val in [("services.webserver", "true"), ("services.webserverport", "8080"),
                 ("services.webserverauthentication", "true"),
                 ("services.webserverusername", "kodi"), ("services.webserverpassword", "kodi")]:
    s = setval(s, sid, val)
open(p, "w").write(s)
print("  guisettings.xml: web server enabled")
PY

# sources.xml — point Videos / Music / Pictures / Files at the media path.
if [ ! -f "$KODI_USERDATA/sources.xml" ]; then
  log "Writing $KODI_USERDATA/sources.xml (Media -> $MEDIA_PATH)"
  cat > "$KODI_USERDATA/sources.xml" <<SRC
<sources>
    <programs>
        <default pathversion="1"></default>
    </programs>
    <video>
        <default pathversion="1"></default>
        <source>
            <name>Media</name>
            <path pathversion="1">$MEDIA_PATH</path>
            <allowsharing>true</allowsharing>
        </source>
    </video>
    <music>
        <default pathversion="1"></default>
        <source>
            <name>Media</name>
            <path pathversion="1">$MEDIA_PATH</path>
            <allowsharing>true</allowsharing>
        </source>
    </music>
    <pictures>
        <default pathversion="1"></default>
        <source>
            <name>Media</name>
            <path pathversion="1">$MEDIA_PATH</path>
            <allowsharing>true</allowsharing>
        </source>
    </pictures>
    <files>
        <default pathversion="1"></default>
        <source>
            <name>Media</name>
            <path pathversion="1">$MEDIA_PATH</path>
            <allowsharing>true</allowsharing>
        </source>
    </files>
</sources>
SRC
else
  log "sources.xml already exists; leaving it untouched"
fi

# Estuary skin settings — strip the home menu down to local-files sections.
# HomeMenuNo<X>Button = true hides that top-level item; the ones left out
# (Videos, Music, Pictures, Favourites) stay visible.
ESTUARY_DATA="$KODI_USERDATA/addon_data/skin.estuary"
if [ ! -f "$ESTUARY_DATA/settings.xml" ]; then
  log "Writing $ESTUARY_DATA/settings.xml (minimalist home menu)"
  mkdir -p "$ESTUARY_DATA"
  cat > "$ESTUARY_DATA/settings.xml" <<'SKIN'
<settings version="2">
    <setting id="HomeMenuNoMovieButton">true</setting>
    <setting id="HomeMenuNoTVShowButton">true</setting>
    <setting id="HomeMenuNoTVButton">true</setting>
    <setting id="HomeMenuNoRadioButton">true</setting>
    <setting id="HomeMenuNoMusicVideoButton">true</setting>
    <setting id="HomeMenuNoProgramsButton">true</setting>
    <setting id="HomeMenuNoGamesButton">true</setting>
    <setting id="HomeMenuNoWeatherButton">true</setting>
    <setting id="HomeMenuNoVideosButton">false</setting>
    <setting id="HomeMenuNoMusicButton">false</setting>
    <setting id="HomeMenuNoPicturesButton">false</setting>
    <setting id="HomeMenuNoFavButton">false</setting>
</settings>
SKIN
else
  log "Estuary settings.xml already exists; leaving it untouched"
fi
