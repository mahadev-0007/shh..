# sshm

A fast, vibrant SSH connection manager in a single bash script.

Pick a server from a full-screen list, hit Enter, and you're in a completely
normal `ssh` session. No daemon, no Python/Node runtime, no ncurses, no
dependencies beyond `ssh` itself.

```
╭──────────────────────────────────────────────────────────────────╮
│                                                                  │
│       ███████╗███████╗██╗  ██╗███╗   ███╗                        │
│       ██╔════╝██╔════╝██║  ██║████╗ ████║                        │
│   🤫  ███████╗███████╗███████║██╔████╔██║                        │
│       ╚════██║╚════██║██╔══██║██║╚██╔╝██║                        │
│       ███████║███████║██║  ██║██║ ╚═╝ ██║                        │
│       ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝                        │
│                                                                  │
│   5 servers  ·  rose                      ssh connection manager │
│                                                                  │
│   press / to filter                                              │
│   SERVER       CONNECTION                                   AUTH │
│   ────────────────────────────────────────────────────────────   │
│ ❯ saas-server  root@139.5.189.22                            PASS │
│ ● prod-web     root@10.0.0.5                                PASS │
│ ● db-01        admin@10.0.0.9:2222                          KEY  │
│ ● staging      ubuntu@staging.example.com                   PASS │
│                                                                  │
│   ────────────────────────────────────────────────────────────   │
│   ssh root@139.5.189.22                                          │
│   ↑↓ move   ⏎ connect   / filter   a add   e edit   q quit       │
╰──────────────────────────────────────────────────────────────────╯
```

The shushing face is the logo, because that is what ssh has always been telling
you to do. It is measured as two terminal columns, which is what keeps the frame
square around it.

### The colour aura

Every server gets a colour derived from its name — stable, so a given server is
always the same colour. That colour marks its dot in the list, fills its
selection bar, and lights an **aura that glows out along the screen border**,
brightest at the row you are on and fading with distance. Move the cursor and
the whole frame shifts hue, so you can tell at a glance which machine you are
about to connect to.

The aura uses 24-bit colour where the terminal advertises it (`COLORTERM`), and
falls back to a three-step 256-colour ramp otherwise. `NO_COLOR` turns it all
off.

### The aura follows you into the session

A running `ssh` session owns the whole screen, so there is no border left for
`sshm` to draw on. Instead it tints the terminal itself for the length of the
session, and puts everything back when you exit:

* the **cursor** takes the server's colour
* the **background** gets a faint wash of that hue (`#311f27` for a rose server)
* the **window title** becomes `🤫 saas-server · root@139.5.189.22:22`
* the session is framed top and bottom by a full-width rule in the server colour

So the machine you are on stays identifiable the entire time you are on it, not
just while you are picking it. Set `SSHM_TINT=0` to disable the tinting and keep
only the rules. If a session is ever killed hard enough to skip the restore,
this puts your terminal back:

```sh
printf '\033]111\007\033]112\007'
```

### Filtering

Press `/` and type. The list narrows as you go, matching against name, user and
host. `↑`/`↓` still move while filtering, Enter accepts, `esc` clears.

## Install

```sh
chmod +x sshm
ln -s "$PWD/sshm" /usr/local/bin/sshm     # or anywhere on your PATH
```

For saved passwords to be filled in automatically you also need `sshpass`:

```sh
brew install sshpass
```

Without it everything still works — `ssh` just prompts for the password itself.

## Usage

```sh
sshm             # open the interactive list
sshm prod-web    # connect straight to a saved server
sshm list        # print saved servers, no TUI
sshm paste       # put the clipboard image on the server (see below)
sshm --help
```

### Keys

| Key            | Action                                    |
| -------------- | ----------------------------------------- |
| `↑` `↓` / `k` `j` | move                                   |
| `⏎`            | connect                                   |
| `/`            | filter as you type                        |
| `esc`          | clear the filter                          |
| `a`            | add a server                              |
| `e`            | edit the selected server                  |
| `d`            | delete the selected server                |
| `c`            | copy your public key to the server        |
| `g` / `G`      | jump to first / last                      |
| `q`            | quit                                      |

Adding a server asks for name, IP/host, username (defaults to `$USER`), port
(defaults to `22`), and then either a password or the path to an identity file.
When editing, pressing Enter on a field keeps its current value.

### Pasting screenshots into a remote agent

A terminal only ever sends text down the wire, so an image on your clipboard
pastes into a remote shell as nothing at all — which makes handing a screenshot
to a coding agent running on the server annoying.

`sshm` bridges it. Run `sshm paste` from another terminal tab while a session is
open: it copies the image on your clipboard to the server over that session's
own connection and prints the **remote path**, which you can hand to the agent.

```sh
sshm paste          # -> /root/.cache/sshm-clip/clip-….png
```

There is also a background watcher that uploads automatically the moment an
image lands on the clipboard, and replaces the clipboard with the remote path.
**It is off by default**, because rewriting the system clipboard behind your
back breaks ordinary local copy/paste — copy a PNG in Finder to paste somewhere
else and you would get a server path instead. Turn it on per session if you
want it:

```sh
SSHM_CLIP_WATCH=1 sshm prod-web
```

Even then it now only reacts to raw image data (a screenshot taken with
`ctrl-cmd-shift-4`), never to files copied in Finder.

The GUI in `gui/` handles this better and needs no watcher at all: paste or drag
an image into a session and it uploads and types the remote path in for you,
leaving your clipboard untouched.

The upload rides the session's existing authenticated connection (an SSH
control socket), so there is no second password prompt and no second handshake.
Nothing is uploaded unless the clipboard actually changes to an image.

From another terminal tab, `sshm paste` does the same thing on demand against
whichever session is open, and prints the path.

Requirements: macOS (`pbcopy` + `osascript`, both built in). `pngpaste` is used
if installed but is not needed. Uploaded images pile up in
`~/.cache/sshm-clip/` on the server — delete them whenever you like.

```sh
SSHM_CLIP_WATCH=1 sshm prod-web  # turn the background watcher on (off by default)
SSHM_CLIP=0 sshm prod-web        # turn the bridge off entirely, `sshm paste` included
SSHM_CLIP_POLL=2 sshm prod-web   # watcher: check the clipboard less often
```

## Config

`~/.config/sshm/servers.conf` — created on first run, directory `0700`, file `0600`.
(Honours `$XDG_CONFIG_HOME` if you set it.)

One record per line:

```
name|host|user|port|auth|secret
```

* `auth` is `pass` or `key`
* `secret` is base64 of the password when `auth=pass`, or the path to the
  identity file when `auth=key`

```
prod-web|10.0.0.5|root|22|pass|U3VwZXJTZWNyZXQ=
db-01|10.0.0.9|admin|2222|key|/Users/you/.ssh/id_ed25519
```

The file is plain text you can edit by hand; malformed lines are reported and
skipped rather than breaking the whole config.

## About password storage

**Passwords are base64-encoded, and base64 is encoding, not encryption.**
Anyone who can read your user account — or a Time Machine/cloud backup of it, or
any process running as you — can recover every saved password with one command.
The encoding only keeps `|`, spaces and newlines from corrupting the config file
and stops passwords being readable over your shoulder.

What the script does do:

* the config file is kept at mode `0600`, and permissions are tightened
  automatically if they ever loosen
* the password is handed to `sshpass` over **file descriptor 3**, never as a
  command-line argument — so it does not show up in `ps` output, and it is
  never written to a temporary file

If that trade-off isn't acceptable for a given host, use key auth instead:
press `c` on a server to run `ssh-copy-id`, and the script offers to switch that
entry over to the key afterwards.

## Troubleshooting

### `Session exited with status 6`

`sshpass` couldn't answer ssh's first-connect *"Are you sure you want to continue
connecting?"* prompt, so it refused rather than trusting an unverified key.

`sshm` now catches this: it fetches the server's host key with `ssh-keyscan`,
prints the fingerprint, and asks whether to trust it. Check the fingerprint
against your server console or hosting panel, answer `y`, and the connection
retries automatically. Answering `n` leaves `known_hosts` untouched.

You can also just do the first handshake by hand — `ssh root@your-host`, type
`yes` — and `sshm` works from then on.

### `'xterm-ghostty': unknown terminal type` on the remote host

Terminals like Ghostty, kitty and WezTerm export a `TERM` value that most
servers do not have in their terminfo database, so the remote shell complains
and `clear`, `vim` and `less` misbehave.

`sshm` handles this: unless your `TERM` is one of the widely-recognised values,
it sends `xterm-256color` to the remote host instead. Override it if you need
something else:

```sh
SSHM_TERM=xterm sshm prod-web
```

To keep your terminal's exact capabilities on a server you control, install its
terminfo entry there once:

```sh
infocmp -x | ssh root@your-host -- tic -x -
```

### Stray `^[[D` before the remote's banner

Keystrokes left in the input queue when the session starts get handed straight
to the remote shell, which echoes them back as `^[[D` (a left-arrow) or similar.
`sshm` now drains pending input before launching `ssh`, so this should not
recur.

### Random `[<35;108;41M` strings when you move the mouse

A full-screen program on the remote host — Claude Code, `vim`, `htop`, `tmux` —
switches your terminal's mouse reporting on. If it exits uncleanly, or the
connection drops before it can switch it back off, the mode stays on in *your*
terminal, and every mouse movement is echoed as a raw SGR mouse report:

```
[<35;108;41M[<35;108;40M[<35;107;33M…
```

`sshm` now turns every mouse mode off both before and after each session, and
again on exit, so the noise cannot outlive the session that caused it. If a
session is already spewing them, `printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l'`
(or plain `reset`) clears it.

### The session hangs after being idle

NAT gateways, home routers and cloud firewalls drop the state for a connection
that has been silent for a few minutes, without telling either end. `ssh` then
sits in a read that will never return, and the only way out is `~.` (Enter,
tilde, dot) or killing the window.

`sshm` now sends a keepalive every 20 seconds on an idle session, which keeps
the mapping alive and — if the peer really has gone — tears the session down
after 3 missed replies instead of hanging. Tune or disable it:

```sh
SSHM_ALIVE_INTERVAL=60 sshm prod-web   # quieter
SSHM_ALIVE_INTERVAL=0  sshm prod-web   # off (old behaviour)
SSHM_ALIVE_COUNT=6     sshm prod-web   # tolerate a longer outage
```

If the remote side is what dies (a laptop server sleeping, a container being
paused), also set `ClientAliveInterval 30` in the server's `/etc/ssh/sshd_config`.

### `Session exited with status 5`

`sshpass` reports the password was rejected. Press `e` on that server to
re-enter it.

### `Session exited with status 255`

ssh itself failed to connect — wrong host or port, firewall, or the server
refusing the auth method.

## Notes

* Written for **bash 3.2**, so it runs on stock macOS `/bin/bash` as well as
  modern bash on Linux.
* The whole UI is repainted into one buffered write per keystroke, with no
  subshells in the render path — it stays responsive over a slow link.
* The terminal size comes from `stty size` (a kernel ioctl), not `tput`. `tput`
  trusts `$COLUMNS`/`$LINES` when they are exported, so a stale 80x24 in the
  environment would otherwise leave the UI drawn in a small box in the corner of
  a full-screen window. It also needs no terminfo entry, so an unrecognised
  `TERM` such as `xterm-ghostty` costs nothing. The frame is re-measured on
  every repaint, so resizing the window just works.
* Host-key checking is left at `ssh`'s defaults — you'll still get the usual
  fingerprint prompt on first connect.
* For password entries the script passes
  `-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive`
  so `ssh` doesn't exhaust its auth attempts on agent keys first.
* `Ctrl-C` at the menu restores the cursor and leaves the alternate screen
  cleanly.

## Out of scope

Port forwarding, jump hosts, groups/tags, search, and importing `~/.ssh/config`.

The clipboard bridge is macOS-only and one-directional: local image → server.
Pulling a file back from the server, and Linux/Wayland clipboards, are not
handled.
