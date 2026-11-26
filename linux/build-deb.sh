#!/bin/sh
# Builds dist/shh_<version>_<arch>.deb. Run on Ubuntu 24.04+ (or inside the
# build container: docker exec shh-build ./build-deb.sh).
#
# The version comes from ../gui/VERSION so the Mac and Ubuntu apps move
# together; SHH_VERSION overrides it (the build container only mounts linux/).
set -e
cd "$(dirname "$0")"
HERE=$PWD

APPID="io.github.mahadev_0007.shh"
if [ -n "$SHH_VERSION" ]; then
    VERSION="$SHH_VERSION"
elif [ -f ../gui/VERSION ]; then
    VERSION=$(tr -d ' \n' < ../gui/VERSION)
else
    VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -1)
fi
[ -n "$VERSION" ] || { echo "could not work out the version"; exit 1; }
ARCH=$(dpkg --print-architecture)

cargo build --release -p shh
BIN="${CARGO_TARGET_DIR:-$HERE/target}/release/shh"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/shh_${VERSION}_${ARCH}"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/doc/shh"

install -m 755 "$BIN" "$ROOT/usr/bin/shh"
# the bash TUI travels with it, when the checkout has it
if [ -f ../sshm ]; then
    install -m 755 ../sshm "$ROOT/usr/bin/sshm"
fi
install -m 644 "packaging/$APPID.desktop" "$ROOT/usr/share/applications/$APPID.desktop"
for png in packaging/icons/*.png; do
    size=$(basename "$png" .png)
    dir="$ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    install -m 644 "$png" "$dir/$APPID.png"
done
[ -f README.md ] && install -m 644 README.md "$ROOT/usr/share/doc/shh/README.md"

SIZE=$(du -sk "$ROOT/usr" | cut -f1)
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: shh
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE
Depends: libgtk-4-1, libadwaita-1-0, libvte-2.91-gtk4-0, openssh-client
Recommends: sshpass, tmux, openssh-server, pipewire-bin | pulseaudio-utils, wl-clipboard | xclip
Maintainer: shh maintainers <noreply@users.noreply.github.com>
Homepage: https://github.com/mahadev-0007/shh..
Description: SSH session manager and coding-agent opener
 Keep servers and projects, and open each project with an agent (Claude Code,
 Codex, a plain shell) in a terminal embedded in the window. Sessions run in
 tmux on the server and survive a dropped connection. Includes sshm, the
 terminal version, which shares the same configuration.
CONTROL

cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
POSTINST
cp "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

mkdir -p dist
OUT="dist/shh_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT" >/dev/null
echo "built $HERE/$OUT"
