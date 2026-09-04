#!/bin/sh
# Builds a drag-to-install disk image around an already-built sshm.app.
#   tools/make-dmg.sh <version> <output.dmg>
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
OUT="$2"
[ -n "$VERSION" ] && [ -n "$OUT" ] || { echo "usage: make-dmg.sh <version> <out.dmg>"; exit 1; }
[ -d shh.app ] || { echo "shh.app not built"; exit 1; }

STAGE=$(mktemp -d)/shh
mkdir -p "$STAGE"
cp -R shh.app "$STAGE/shh.app"
ln -s /Applications "$STAGE/Applications"

# Gatekeeper will refuse an ad-hoc signed app that arrives with a quarantine
# flag, so the fix travels with it rather than living only in a README.
cat > "$STAGE/First launch — read me.txt" <<TXT
shh $VERSION

INSTALL
  Drag shh.app onto the Applications folder in this window.

FIRST LAUNCH
  macOS will refuse to open it the first time, saying the app is damaged or
  from an unidentified developer. It is neither — the app just isn't signed
  with a paid Apple Developer certificate.

  Either:
    right-click shh.app in Applications -> Open -> Open

  or run this once in Terminal:
    xattr -dr com.apple.quarantine /Applications/shh.app

  You only do this once per Mac. Updates install themselves after that.
TXT

rm -f "$OUT"
hdiutil create -volname "shh $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
    -quiet "$OUT"
rm -rf "$(dirname "$STAGE")"
echo "  dmg: $OUT ($(du -h "$OUT" | cut -f1))"
