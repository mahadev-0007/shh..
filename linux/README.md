# shh for Ubuntu

The Ubuntu port of shh: Rust, GTK4, libadwaita and VTE. One native binary, no
Electron, Node or Python. It reads and writes the same files as the Mac app and
the `sshm` terminal version, so all three can share a config directory.

Targets Ubuntu 24.04 and later.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mahadev-0007/shh../main/install.sh | sh
```

That downloads the `.deb` for your architecture from the latest release and
installs it with apt. The package also installs `sshm`.

## Build

```sh
sudo apt install build-essential pkg-config \
    libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev
# Rust from https://rustup.rs (Ubuntu 24.04's packaged rustc is too old)

cargo run -p shh              # run it
cargo test -p shh-core        # config formats, hue hash, remote command strings
./build-deb.sh                # -> dist/shh_<version>_<arch>.deb
```

At run time it wants `openssh-client`, and uses these when present: `sshpass`
(saved passwords), `tmux` on the server (sessions that survive a dropped link),
`tailscale` and `openssh-server` (sharing), `pw-record` or `parec` (voice).

### Building from a Mac

VTE does not build on macOS, so the app is compiled in a container:

```sh
docker build -f Dockerfile.build -t shh-build .
docker run -d --name shh-build -v "$PWD":/work \
    -v shh-target:/target -v shh-registry:/root/.cargo/registry \
    shh-build sleep infinity

docker exec shh-build cargo check -p shh
docker exec shh-build cargo test -p shh-core
docker exec -e SHH_VERSION="$(cat ../gui/VERSION)" shh-build ./build-deb.sh
```

The container mounts only `linux/`, so `build-deb.sh` there takes the version
from `SHH_VERSION` and leaves `sshm` out of the package. CI builds the real
packages (`.github/workflows/linux.yml`) for amd64 and arm64 on every `v*` tag
and attaches them to the GitHub release that `gui/release.sh` creates.

## Layout

| Crate | Holds |
| --- | --- |
| `shh-core` | `servers.conf` and `sshm.json`, hue hash, shell quoting, the remote command builder, exit-status mapping |
| `shh-remote` | remote exec, sftp file browser, tmux session listing, server capability probes |
| `shh-sharing` | Tailscale invites, guest keys, the invite listener, the voice bridge |
| `shh` | the GTK application |

## Differences from the Mac app

* **Shortcuts.** `Ctrl` belongs to the shell inside a terminal (`Ctrl+W`,
  `Ctrl+N`, `Ctrl+R`), so window shortcuts use `Ctrl+Shift` or `Alt`, the same
  convention GNOME Terminal follows. Copy and paste are `Ctrl+Shift+C` / `V`.
* **Updates.** There is no Sparkle. Releases are `.deb` files; the app checks
  GitHub for a newer version and tells you, and you install it with the
  one-line installer above.
* **Sharing.** Where the Mac app turns on Remote Login, this one checks
  `systemctl is-active ssh` and offers to run `systemctl enable --now ssh`
  through polkit. `openssh-server` is not installed on Ubuntu Desktop by
  default; the app tells you when it is missing. Invites are wire-compatible
  with the Mac app, in both directions.
* **Icons.** SF Symbols do not exist here. The Symbols tab offers the Adwaita
  symbolic set, and a symbol name saved by the Mac app falls back to a dot.
* **Notifications.** No permission prompt; they go through the desktop's
  notification service. OSC 9 / OSC 777 depend on the VTE version, and tmux
  filters them anyway. The terminal bell always works.
* **Look.** libadwaita widgets with the server colours layered on top, not a
  copy of the Mac design.

## Storage

Identical to the Mac app: `~/.config/sshm/` (or `$XDG_CONFIG_HOME/sshm/`) holds
`servers.conf`, `sshm.json`, `sharing.json`, `keys/` and `icons/`, mode `0600`,
written atomically and watched for outside edits.

## `sshm` on Linux

The terminal version runs unchanged. Its clipboard image bridge (`sshm paste`,
or `SSHM_CLIP_WATCH=1`) uses `wl-paste` / `wl-copy` on Wayland and `xclip` on
X11:

```sh
sudo apt install wl-clipboard xclip sshpass
```
