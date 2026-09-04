#!/bin/sh
# Cut a release: bump the version, build, sign the archive, update the appcast,
# and upload to GitHub Releases.
#
#   ./release.sh 1.1.0            # release version 1.1.0
#   ./release.sh 1.1.0 --dry-run  # build and sign, upload nothing
#
# One-time setup lives in RELEASING.md.
set -e
cd "$(dirname "$0")"

VERSION="$1"
DRY_RUN=""
[ "$2" = "--dry-run" ] && DRY_RUN=1

if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh <version> [--dry-run]"
    echo "current: $(cat VERSION)"
    exit 1
fi
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "version must look like 1.2.3"; exit 1 ;;
esac

REPO="${SSHM_REPO:-$(cat .github-repo 2>/dev/null || echo '')}"
if [ -z "$REPO" ] && [ -z "$DRY_RUN" ]; then
    echo "no GitHub repo configured. Put owner/name in gui/.github-repo"
    exit 1
fi

SIGN_TOOL=$(find .build/artifacts -name sign_update -type f | head -1)
[ -x "$SIGN_TOOL" ] || { echo "sign_update not found — run swift build first"; exit 1; }

# --- version -----------------------------------------------------------------
echo "$VERSION" > VERSION
# a dry run must not leave a commit or a tag behind
if [ -z "$DRY_RUN" ]; then
    git add VERSION 2>/dev/null || true
    git commit -qm "Release $VERSION" 2>/dev/null || true
    git tag -f "v$VERSION" >/dev/null
fi

# --- build -------------------------------------------------------------------
./build.sh release
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" shh.app/Contents/Info.plist)

ARCHIVE="dist/shh-$VERSION.zip"
mkdir -p dist
rm -f "$ARCHIVE"
# ditto, not zip: it preserves the bundle's symlinks and resource forks, which
# a plain zip mangles and Sparkle then refuses to install.
ditto -c -k --sequesterRsrc --keepParent shh.app "$ARCHIVE"

# --- sign --------------------------------------------------------------------
# EdDSA over the archive. This is what authenticates the update, since the app
# has no Developer ID to check against.
SIGNATURE=$("$SIGN_TOOL" "$ARCHIVE" 2>/dev/null | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
[ -n "$SIGNATURE" ] || { echo "signing failed — is the private key in the keychain?"; exit 1; }
LENGTH=$(stat -f%z "$ARCHIVE")

# --- appcast -----------------------------------------------------------------
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
URL="https://github.com/$REPO/releases/download/v$VERSION/shh-$VERSION.zip"
NOTES_FILE="dist/notes-$VERSION.html"
if [ -f "RELEASE_NOTES.md" ]; then
    printf '<![CDATA[%s]]>' "$(sed 's/^# .*//' RELEASE_NOTES.md)" > "$NOTES_FILE"
else
    printf '<![CDATA[<p>Version %s</p>]]>' "$VERSION" > "$NOTES_FILE"
fi

ITEM=$(cat <<XML
        <item>
            <title>$VERSION</title>
            <pubDate>$DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description>$(cat "$NOTES_FILE")</description>
            <enclosure url="$URL"
                       length="$LENGTH"
                       type="application/octet-stream"
                       sparkle:edSignature="$SIGNATURE" />
        </item>
XML
)

if [ ! -f appcast.xml ]; then
    cat > appcast.xml <<'HEAD'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>ArkConnect</title>
        <description>Updates for ArkConnect</description>
        <language>en</language>
    </channel>
</rss>
HEAD
fi
# newest item first, right after <language>
python3 - "$VERSION" <<PY
import sys, pathlib, re
version = sys.argv[1]
p = pathlib.Path("appcast.xml")
s = p.read_text()
item = '''$ITEM'''
# drop any existing entry for this version, so re-running is idempotent
s = re.sub(r"\s*<item>(?:(?!</item>).)*?<sparkle:shortVersionString>"
           + re.escape(version) + r"</sparkle:shortVersionString>.*?</item>",
           "", s, flags=re.S)
s = s.replace("<language>en</language>", "<language>en</language>\n" + item, 1)
p.write_text(s)
print("appcast updated for", version)
PY

# a disk image for people installing by hand; Sparkle keeps using the zip
DMG="dist/shh-$VERSION.dmg"
tools/make-dmg.sh "$VERSION" "$DMG"

echo "archive: $ARCHIVE  ($LENGTH bytes)"
echo "sig:     $SIGNATURE"

if [ -n "$DRY_RUN" ]; then
    echo "dry run — nothing uploaded"
    exit 0
fi

# --- publish -----------------------------------------------------------------
# the appcast has to be on the remote before the release, or a client that
# checks in the gap sees an entry pointing at an asset that isn't there yet
git add appcast.xml VERSION
git commit -qm "Appcast for $VERSION" || true
git push -q origin HEAD --tags

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release create "v$VERSION" "$ARCHIVE" "$DMG" \
        --repo "$REPO" --title "shh $VERSION" \
        --notes-file "${RELEASE_NOTES:-RELEASE_NOTES.md}" 2>/dev/null \
      || gh release upload "v$VERSION" "$ARCHIVE" "$DMG" --repo "$REPO" --clobber
else
    # gh isn't set up; fall back to the token git already uses for this remote
    echo "gh unavailable — publishing through the API"
    TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill \
            | sed -n 's/^password=//p')
    [ -n "$TOKEN" ] || { echo "no GitHub credential found; run: gh auth login"; exit 1; }
    TOKEN="$TOKEN" REPO="$REPO" VERSION="$VERSION" \
        ARCHIVE="$ARCHIVE" DMG="$DMG" python3 ../tools/publish-release.py
fi

echo
echo "released $VERSION ($BUILD)"
echo "feed: https://raw.githubusercontent.com/$REPO/main/gui/appcast.xml"
