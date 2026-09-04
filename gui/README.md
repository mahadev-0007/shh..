# sshm.app

A coding-agent opener. You keep **servers**, you keep **projects** (a directory on
a server), and each project opens with an **agent** — Claude Code, Codex, Gemini
CLI, a plain shell — in one click, in a terminal embedded in the window.

* AppKit + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). No Electron,
  no Node, no Python. A 3.5 MB bundle, one process, ~65 MB resident.
* Shares `~/.config/sshm/servers.conf` with the bash TUI, byte for byte, in both
  directions and live.

## Build

```sh
./build.sh          # -> sshm.app
open sshm.app       # or drag into /Applications
```

Needs the Swift toolchain (Xcode or Command Line Tools). The first build fetches
SwiftTerm; after that it is offline.

## The shape of it

A slim icon rail down the left — **Dashboard · Projects · Servers · Settings** —
and a rounded pill bar at the top of each page. Live sessions appear as pills in
that same bar, after a divider, each with a status dot: green while the process
is alive, grey once it exits.

* **Dashboard** — reachability and count tiles, what's running now, quick-launch
  cards, and what you opened recently.
* **Projects** — a card per project. Click to open; ⌥-click to force a second
  session when one is already running. Filter by server from the pill bar.
* **Servers** — a card per machine, with a Shell button and a full-page editor.
* **Settings** — Agents, Appearance, Config.

Every server, project and agent takes an icon you choose. One picker, four tabs:
**Emoji**, **Symbols** (SF Symbols, filtered to what this OS actually has),
**Logos** (vector marks drawn in code — Claude, OpenAI, Gemini, Cursor, terminal,
tmux, braces), and **Custom** — your own image. Custom takes png, jpeg, heic,
tiff, gif, pdf or icns; the file is copied into `~/.config/sshm/icons/`,
normalised to a 256px PNG, and referenced by name. You can also **drag an image
file straight onto any icon chip** in an edit form. Right-click a custom icon in
the picker to delete it.

The bundled logos are simplified marks, not official artwork — for an exact logo,
drop the real file in through the Custom tab. Colour is derived from the server's name with the same hash the
bash TUI uses, so a machine keeps its identity in both front ends — a pastel on
the cards, the vivid hue as the terminal's wash.

## Naming

You type a real name ("SaaS Server"); a slug (`saas-server`) is derived from it
and used as the key in `servers.conf`, so `sshm saas-server` still works in the
terminal. The slug is shown on the edit page and can be overridden.

## How a project opens

```
ssh -t user@host 'exec ${SHELL:-/bin/sh} -lc "cd -- <path> || exit 1; <agent>; exec $SHELL -l"'
```

Three things in there matter:

* **`-t`** forces a pty. Without one, full-screen agents like `claude` and
  `codex` refuse to start or render garbage.
* **A login shell** (`-lc`) sources `~/.zprofile`, where nvm/asdf/npm put these
  CLIs on the `PATH`. Without it you get "command not found" for a tool that
  works fine when you ssh in by hand. If yours is set up in `~/.zshrc` instead,
  change that agent's shell to `${SHELL:-/bin/sh} -lic` in Settings → Agents.
* **`exec $SHELL -l` at the end** (per-agent "Keep shell") leaves you at a prompt
  in the project directory when the agent exits, instead of the tab dying.

Paths and commands are single-quoted recursively, so spaces, apostrophes and `~`
all survive. The project editor shows the exact command it will run.

Opening several projects on one server reuses a single authenticated connection
(`ControlMaster` on a per-server socket), so you're asked for the password once.
Turn it off in Settings → Appearance.

## Agents

Seeded: Claude Code, Claude Code (continue), **Command Code** (`cmd`), Codex,
Gemini CLI, Aider, opencode, Cursor Agent, Shell, tmux, Editor. Each is just a name, an icon, a command, the
shell wrapper, and whether to keep a prompt afterwards — edit them or add your
own in Settings. An empty command means "just cd there".

## Keys

| Key | Action |
| --- | --- |
| `⌘1`–`⌘4` | Dashboard / Projects / Servers / Settings |
| `⌘N` | new project (or server, on the Servers page) |
| `⇧⌘N` | new server |
| `⌘W` | close the current session |
| `⇧⌘[` / `⇧⌘]` | previous / next session |
| `⌘R` | re-read both config files |
| `⌃⌘F` | focus mode — hide the sidebar and top bar, terminal owns the window |
| `⌃⇧⌘F` | macOS full screen |
| `⌘,` | Settings |

## Versioning and updates

The app carries a version (`gui/VERSION` → `CFBundleShortVersionString`) and a
build number (the commit count → `CFBundleVersion`), and updates itself through
[Sparkle](https://sparkle-project.org). Settings → Updates shows the version, a
"check now" button and an automatic-check toggle; ⌘-menu → Check for Updates…
does the same.

Because the app has no Developer ID, updates are authenticated by an EdDSA
signature on each archive rather than by code signing. Releases live on GitHub
Releases with an `appcast.xml` feed in the repo. See
[RELEASING.md](RELEASING.md) — including the one-time Gatekeeper step each
teammate needs on first install.

If ssh sessions are live when an update is ready, the app says so and asks
before relaunching instead of dropping them.

## Storage

| File | Holds |
| --- | --- |
| `~/.config/sshm/servers.conf` | host, user, port, auth, secret — the format the bash TUI defines. Untouched. |
| `~/.config/sshm/sshm.json` | display names, icons, projects, agents, settings. Nothing secret. |

Both are mode `0600`, written atomically, and watched — an edit from the bash TUI
shows up here within a second, and vice versa. Passwords remain base64 in
`servers.conf`, which is obfuscation and not encryption; the app says so in
Settings → Config. They still reach `sshpass` on **file descriptor 3** through a
fifo in a `0700` directory, so they never appear in `argv` or on disk.

If a server disappears from `servers.conf`, projects pointing at it are **not**
deleted — they show dimmed as orphans, with an explicit cleanup action in
Settings → Config.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `SSHM_ALIVE_INTERVAL` | `20` | keepalive seconds |
| `SSHM_ALIVE_COUNT` | `3` | missed keepalives before teardown |
| `SSHM_CONNECT_TIMEOUT` | `10` | ssh connect timeout |
| `SSHM_TERM` | `xterm-256color` | `TERM` sent to the remote host |
| `XDG_CONFIG_HOME` | `~/.config` | where `sshm/` lives |

## Images into a session

Paste (`⌘V`) or drag an image into a running session and it is uploaded to the
server over that session's existing connection; the remote path is then typed
into the terminal, ready to hand to the agent.

**Your clipboard is never written to.** The bash TUI's watcher polls the
pasteboard and replaces it with the remote path the moment any image appears,
which silently breaks local copy/paste. Here the upload happens only when you
paste or drop into a session, and the path goes straight into the terminal —
which is where you wanted it anyway.

Files land in `~/.cache/sshm-clip/` on the server. Turn the whole thing off in
Settings → Appearance → Paste images, and `⌘V` goes back to a plain text paste.

## Not done yet

Drag-to-reorder project cards, `ssh-copy-id` from the server editor, the
host-key trust prompt on `exit 6`, and the recent-activity filter pills.
