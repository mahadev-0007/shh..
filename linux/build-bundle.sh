#!/bin/sh
# Builds the self-contained package: shh plus every library it needs, down to
# the C library and its loader, under /opt/shh. For systems whose own GTK is
# too old for the regular package — Ubuntu 22.04, Debian 12 and the like.
#
# Must run on Ubuntu 24.04 (it copies that system's libraries).
#   ./build-bundle.sh        -> dist/shh-bundled_<version>_<arch>.deb
set -e
cd "$(dirname "$0")"

if [ -n "$SHH_VERSION" ]; then VERSION="$SHH_VERSION"
elif [ -f ../gui/VERSION ]; then VERSION=$(tr -d ' \n' < ../gui/VERSION)
else VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -1); fi
ARCH=$(dpkg --print-architecture)
MULTI=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
TARGET="${CARGO_TARGET_DIR:-target}"

cargo build --release -p shh
BIN="$TARGET/release/shh"

STAGE=$(mktemp -d)
ROOT="$STAGE/pkg"
B="$ROOT/opt/shh"
mkdir -p "$B/bin" "$B/lib/gdk-pixbuf/loaders" "$B/share/glib-2.0/schemas" "$B/share/icons" \
         "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/DEBIAN"
install -m 755 "$BIN" "$B/bin/shh"

# image loaders are opened at run time, so ldd on the binary does not see them
PIX="/usr/lib/$MULTI/gdk-pixbuf-2.0/2.10.0"
cp "$PIX"/loaders/*.so "$B/lib/gdk-pixbuf/loaders/" 2>/dev/null || true

# every shared library the binary and the loaders pull in, loader included
deps() { ldd "$@" 2>/dev/null | awk '/=> \//{print $3} /^\t\/.* \(0x/{print $1}' | sort -u; }
for lib in $(deps "$B/bin/shh" "$B"/lib/gdk-pixbuf/loaders/*.so); do
    case "$(basename "$lib")" in
        ld-linux*) cp -L "$lib" "$B/lib/ld.so" ;;
        *)         cp -L "$lib" "$B/lib/" ;;
    esac
done
[ -f "$B/lib/ld.so" ] || { echo "could not find the dynamic loader"; exit 1; }
chmod 755 "$B/lib/ld.so"

# the loader cache lists absolute paths; write them as they will be installed
"/usr/lib/$MULTI/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders" "$B"/lib/gdk-pixbuf/loaders/*.so \
    | sed "s|$B|/opt/shh|g" > "$B/lib/gdk-pixbuf/loaders.cache"

cp /usr/share/glib-2.0/schemas/org.gtk.gtk4.Settings.*.gschema.xml "$B/share/glib-2.0/schemas/"
glib-compile-schemas "$B/share/glib-2.0/schemas"
cp -r /usr/share/icons/Adwaita "$B/share/icons/"
mkdir -p "$B/share/icons/hicolor" && cp /usr/share/icons/hicolor/index.theme "$B/share/icons/hicolor/"

cat > "$ROOT/usr/bin/shh" <<'WRAP'
#!/bin/sh
# shh, self-contained build: runs on its own copies of GTK and the C library.
D=/opt/shh
export SHH_BUNDLED=1 SHH_SELF=/usr/bin/shh
export SHH_ORIG_XDG_DATA_DIRS="${XDG_DATA_DIRS:-}"
export GDK_PIXBUF_MODULE_FILE="$D/lib/gdk-pixbuf/loaders.cache"
export GSETTINGS_SCHEMA_DIR="$D/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$D/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
# software drawing: the host's graphics drivers were not built for these libraries
export GSK_RENDERER="${GSK_RENDERER:-cairo}"
exec "$D/lib/ld.so" --library-path "$D/lib" --argv0 shh "$D/bin/shh" "$@"
WRAP
chmod 755 "$ROOT/usr/bin/shh"

[ -f ../sshm ] && install -m 755 ../sshm "$ROOT/usr/bin/sshm"
install -m 644 packaging/io.github.mahadev_0007.shh.desktop "$ROOT/usr/share/applications/"
for size in 48 128 256 512; do
    d="$ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$d" && install -m 644 "packaging/icons/$size.png" "$d/io.github.mahadev_0007.shh.png"
done

SIZE=$(du -sk "$ROOT" | cut -f1)
cat > "$ROOT/DEBIAN/control" <<CTL
Package: shh
Version: $VERSION+bundled
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE
Depends: openssh-client
Recommends: sshpass, tmux, openssh-server, wl-clipboard | xclip
Maintainer: shh maintainers <noreply@users.noreply.github.com>
Homepage: https://github.com/mahadev-0007/shh..
Description: SSH session manager and coding-agent opener (self-contained build)
 Servers, projects and coding agents over ssh, in a native window. This build
 carries its own GTK, libadwaita and VTE for systems whose own are too old,
 such as Ubuntu 22.04. On Ubuntu 24.04 and later use the regular package.
CTL
cat > "$ROOT/DEBIAN/postinst" <<'PI'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
PI
chmod 755 "$ROOT/DEBIAN/postinst"

mkdir -p dist
OUT="dist/shh-bundled_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT" >/dev/null
rm -rf "$STAGE"
echo "built $PWD/$OUT ($(du -h "$OUT" | cut -f1))"
