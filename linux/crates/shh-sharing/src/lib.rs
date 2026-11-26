//! Remote sessions over Tailscale, and the voice bridge.
//!
//! A port of the Mac app's Tailscale / SharingKeys / MiniHTTP / JoinInvite /
//! RemoteAccess / VoiceBridge. The invite link, the join request, sharing.json
//! and the authorized_keys lines are the same bytes on both platforms, so a Mac
//! and an Ubuntu machine can invite each other.

pub mod access;
pub mod http;
pub mod invite;
pub mod join;
pub mod keys;
pub mod sys;
pub mod tailscale;
pub mod ui;
pub mod voice;

/// Call once at app start, on the GTK main thread: resumes the invite listener
/// if sharing was left on, and starts the pump that shows approval prompts.
pub fn start() {
    access::resume();
    ui::install_pump();
}
