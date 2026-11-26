//! Everything shh shares with the bash TUI and the Mac app: file formats,
//! the name→hue hash, and the exact remote command that opens a project.
//! No GTK in here, so it is testable anywhere.
pub mod env;
pub mod exit;
pub mod fsutil;
pub mod meta;
pub mod paths;
pub mod server;
pub mod shell;
pub mod slug;
pub mod tools;
