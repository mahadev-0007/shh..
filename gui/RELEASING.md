# Releasing ArkConnect

Versioning, signing and updates. Read the setup section once; after that a
release is a single command.

## How it fits together

| Piece | Where |
| --- | --- |
| Marketing version (`1.2.3`) | `gui/VERSION`, baked into `CFBundleShortVersionString` |
| Build number | commit count, baked into `CFBundleVersion` — Sparkle compares *this* |
| Update feed | `appcast.xml` in the repo, served over `raw.githubusercontent.com` |
| Binaries | GitHub Releases, one `.zip` asset per version |
| Authentication | EdDSA signature per archive (`sparkle:edSignature`) |

The app has **no Developer ID**, so updates are not authenticated by code
signing. Sparkle accepts either a code-signing match or an EdDSA signature, and
this setup uses the latter: the private key lives in the release machine's
keychain and never touches the repo; the public half is in `gui/.ed-public-key`
and is baked into `Info.plist` as `SUPublicEDKey`. An update whose signature
does not verify is refused — verified above with a deliberately corrupted
signature, which `sign_update --verify` rejects.

## One-time setup

1. **Create the GitHub repo and push.**

   ```sh
   gh auth login
   gh repo create <owner>/arkconnect --private --source=. --push
   ```

2. **Tell the release script where it lives.** Both files are git-ignored,
   because they are per-checkout.

   ```sh
   cd gui
   echo "<owner>/arkconnect" > .github-repo
   echo "https://raw.githubusercontent.com/<owner>/arkconnect/main/appcast.xml" > .feed-url
   ```

   `.feed-url` is what gets baked into the app as `SUFeedURL`. Until it exists,
   builds are "local" and the updater stays quiet rather than failing.

3. **The signing key already exists** in your login keychain (generated with
   Sparkle's `generate_keys`). Public half: `gui/.ed-public-key`.

   > Back the private key up. Losing it means existing installs can never be
   > updated again — you would have to redistribute the app by hand with a new
   > key. Export it with `generate_keys -x sparkle-private-key.txt`, put that
   > file somewhere safe and offline, then delete it from disk.

## Cutting a release

```sh
cd gui
./release.sh 1.1.0 --dry-run   # build, sign, update appcast — uploads nothing
./release.sh 1.1.0             # the real thing
```

It bumps `VERSION`, builds release, archives with `ditto` (a plain `zip`
mangles the bundle and Sparkle then refuses it), signs the archive, prepends an
entry to `appcast.xml`, creates the GitHub release with the zip attached, and
pushes the appcast so clients can see it.

Put user-facing notes in `RELEASE_NOTES.md` before releasing; they become both
the GitHub release body and the "what's new" text Sparkle shows.

Re-running for the same version is safe: the appcast entry is replaced rather
than duplicated.

## What your teammates see

Installed copies check the feed every few hours, and on finding a newer build
number offer it with release notes. If ssh sessions are live the app says so and
asks before relaunching, rather than dropping the connections.

**First install is the rough edge.** Because the app is only ad-hoc signed, a
zip downloaded in a browser is quarantined and Gatekeeper refuses it with
"ArkConnect is damaged" or "cannot be opened". Once, per person:

```sh
xattr -dr com.apple.quarantine /Applications/ArkConnect.app
```

or right-click the app → **Open** → **Open**. Sparkle-delivered updates after
that are not quarantined, so this is a one-time cost per machine, not per
update.

The only way to remove that step is a Developer ID certificate ($99/yr) plus
notarization. If you get one, add to `build.sh` after the bundle is assembled:

```sh
codesign --force --deep --options runtime --timestamp \
    --sign "Developer ID Application: <Your Name> (TEAMID)" "$APP"
xcrun notarytool submit "$ARCHIVE" --keychain-profile ark --wait
xcrun stapler staple "$APP"
```

## Checking it works

- `./release.sh <v> --dry-run` then inspect `gui/appcast.xml` and the zip in
  `gui/dist/`.
- Verify a signature by hand:
  `.build/artifacts/sparkle/Sparkle/bin/sign_update --verify dist/ArkConnect-<v>.zip "<sig>"`
- Point a build at a test feed without releasing:
  `SSHM_FEED_URL=https://example.com/appcast.xml ./build.sh`
