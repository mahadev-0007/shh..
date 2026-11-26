//! Everything shh does on a server outside a terminal tab: short-lived ssh and
//! sftp helpers that ride a session's control socket. Ported from the Mac app's
//! RemoteExec / RemoteFS / RemoteFiles / RemoteSessions / ServerCapabilities /
//! ClipboardBridge. Remote command strings and socket paths are byte-identical
//! to the Swift originals on purpose.

pub mod capabilities;
pub mod clipboard;
pub mod exec;
pub mod files;
pub mod fs;
pub mod sessions;
pub mod ui;

/// Where tmux lives when it isn't on a bare PATH (Homebrew, MacPorts, local).
/// Same list as the Mac app's `Shell.tmuxPaths`; these are *remote* paths.
pub const TMUX_PATHS: &str = "/opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux";
