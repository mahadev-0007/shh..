#!/bin/sh
# Builds sshm.app. Version comes from ./VERSION; the build number is the commit
# count when this is a git repo, so it always moves forward.
set -e
cd "$(dirname "$0")"

APP="shh.app"
VERSION=$(tr -d ' \n' < VERSION)
if git rev-parse --git-dir >/dev/null 2>&1; then
    BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
else
    BUILD=1
fi

# Release metadata. Empty in a local build, which is how the app knows it has
# no update feed and hides the machinery.
FEED_URL="${SSHM_FEED_URL:-$(cat .feed-url 2>/dev/null || echo '')}"
PUBLIC_KEY="${SSHM_ED_PUBKEY:-$(cat .ed-public-key 2>/dev/null || echo '')}"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/SshmApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/shh"

# Sparkle ships as a framework and has to travel inside the bundle. SwiftPM
# links it from .build, so the copy plus an @rpath fixup is on us.
# the xcframework nests the macOS slice several levels down
SPARKLE=$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)
if [ -n "$SPARKLE" ]; then
    cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/shh" 2>/dev/null || true
fi

# The icon is generated once by tools/make-icon.swift and committed, so a
# release build needs no extra tooling.
if [ ! -f Resources/AppIcon.icns ]; then
    TMPSET=$(mktemp -d)/AppIcon.iconset
    swiftc -O -o "$TMPSET.bin" tools/make-icon.swift
    "$TMPSET.bin" "$TMPSET"
    iconutil -c icns "$TMPSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>shh</string>
  <key>CFBundleDisplayName</key>       <string>shh</string>
  <key>CFBundleExecutable</key>        <string>shh</string>
  <key>CFBundleIdentifier</key>        <string>local.sshm.gui</string>
  <key>CFBundleVersion</key>           <string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>SUFeedURL</key>                 <string>$FEED_URL</string>
  <key>SUPublicEDKey</key>             <string>$PUBLIC_KEY</string>
  <key>SUEnableInstallerLauncherService</key> <false/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for Gatekeeper to run a locally built app, and enough
# for Sparkle, which authenticates updates by EdDSA signature instead.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "built $PWD/$APP  —  $VERSION ($BUILD)"
[ -z "$FEED_URL" ] && echo "note: no update feed configured (local build)"
echo "run it with:  open $APP"
