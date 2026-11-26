#!/bin/sh
# Installs the latest release of shh: into /Applications on macOS, or as a
# .deb on Ubuntu/Debian.
#
#   curl -fsSL https://raw.githubusercontent.com/mahadev-0007/shh../main/install.sh | sh
#
# The app is signed ad-hoc rather than with a paid Apple certificate, so macOS
# quarantines anything downloaded through a browser and then refuses to open it.
# Installing this way clears that flag, so there is nothing to work around.
set -e

REPO="${SHH_REPO:-mahadev-0007/shh..}"
DEST="${SHH_DEST:-/Applications}"
API="https://api.github.com/repos/$REPO/releases/latest"

# Ubuntu / Debian: the release carries a .deb per architecture. apt resolves
# the GTK and VTE libraries it needs.
if [ "$(uname -s)" = "Linux" ]; then
    command -v dpkg >/dev/null 2>&1 || {
        echo "This installer supports Debian/Ubuntu. Build from source: see linux/README.md"
        exit 1
    }
    ARCH=$(dpkg --print-architecture)
    echo "Looking up the latest release of shh ($ARCH)…"
    URL=$(curl -fsSL "$API" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | sed 's/.*"\(http[^"]*\)"/\1/' \
        | grep "_${ARCH}\.deb$" | head -1)
    [ -n "$URL" ] || { echo "no .deb for $ARCH on the latest release"; exit 1; }
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    DEB="$TMP/$(basename "$URL")"
    echo "Downloading $(basename "$URL")…"
    curl -fsSL "$URL" -o "$DEB"
    chmod 644 "$DEB"; chmod 755 "$TMP"      # apt's sandbox user must read it
    SUDO=""
    [ "$(id -u)" -eq 0 ] || SUDO="sudo"
    $SUDO apt-get install -y "$DEB"
    echo
    echo "Installed shh. Open it from the app grid, or run:  shh"
    echo "The terminal version is:  sshm"
    exit 0
fi

echo "Looking up the latest release of shh…"
ASSET=$(curl -fsSL "$API" | python3 -c '
import json, sys
rel = json.load(sys.stdin)
zips = [a for a in rel.get("assets", []) if a["name"].endswith(".zip")]
if not zips:
    sys.exit("no .zip asset on the latest release")
print(rel["tag_name"], zips[0]["browser_download_url"])
')
TAG=$(echo "$ASSET" | cut -d' ' -f1)
URL=$(echo "$ASSET" | cut -d' ' -f2)
echo "  $TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading…"
curl -fsSL "$URL" -o "$TMP/shh.zip"

echo "Unpacking…"
# ditto, not unzip: it preserves the bundle's symlinks and metadata
ditto -x -k "$TMP/shh.zip" "$TMP/out"

APP=$(find "$TMP/out" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "no .app inside the archive"; exit 1; }

# Replace any existing install, but refuse to clobber a running copy — that
# leaves you with two apps, one of them a ghost pointing at deleted files.
NAME=$(basename "$APP")
if pgrep -f "$DEST/$NAME/Contents/MacOS/" >/dev/null 2>&1; then
    echo "shh is currently running. Quit it and run this again."
    exit 1
fi

rm -rf "$DEST/$NAME"
cp -R "$APP" "$DEST/$NAME"
xattr -dr com.apple.quarantine "$DEST/$NAME" 2>/dev/null || true

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$DEST/$NAME/Contents/Info.plist" 2>/dev/null || echo "?")
echo
echo "Installed shh $VER to $DEST/$NAME"
echo "Open it from Applications, or:  open '$DEST/$NAME'"
echo "It updates itself from now on."
