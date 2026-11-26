//! What a server can do, discovered once and remembered for the app's lifetime.
//!
//! Durable sessions need tmux on the far side. Rather than assume it, probe on
//! first connect over the control socket that is already open, and fall back to
//! a plain session when it isn't there.

use crate::{exec, TMUX_PATHS};
use shh_core::server::Server;
use shh_core::{shell, tools};
use std::collections::{HashMap, HashSet};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};

#[derive(Default)]
struct State {
    tmux: HashMap<String, bool>,
    probing: HashSet<String>,
}

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(Default::default)
}

fn key(s: &Server) -> String {
    format!("{}:{}", s.target(), s.port)
}

/// None while unknown — callers should treat unknown as "probably yes" and let
/// the remote script degrade gracefully, rather than block on a probe.
pub fn has_tmux(server: &Server) -> Option<bool> {
    state().lock().unwrap().tmux.get(&key(server)).copied()
}

/// Probe over the server's shared control socket. Blocking; call it from a
/// worker thread once the session's connection is up.
pub fn probe(server: &Server) {
    probe_with(server, &exec::control_path(server));
}

pub(crate) fn probe_script() -> String {
    // same search as the session wrapper, so the two agree
    format!("command -v tmux >/dev/null 2>&1 && echo yes && exit; for c in {TMUX_PATHS}; do [ -x \"$c\" ] && echo yes && exit; done; echo no")
}

/// Same, against an explicit socket (a session with connection sharing off).
pub fn probe_with(server: &Server, control_path: &str) {
    let k = key(server);
    {
        let mut st = state().lock().unwrap();
        if st.tmux.contains_key(&k) || !st.probing.insert(k.clone()) {
            return;
        }
    }
    // ride the session's existing master: no second handshake
    let out = Command::new(tools::ssh())
        .args(["-S", control_path, "-o", "BatchMode=yes", &server.target(),
               &format!("sh -c {}", shell::quote(&probe_script()))])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();

    let mut st = state().lock().unwrap();
    st.probing.remove(&k);
    if let Ok(out) = out {
        let found = String::from_utf8_lossy(&out.stdout).trim() == "yes";
        // a failed probe proves nothing about tmux, only about the socket, so
        // don't cache a negative in that case
        if found {
            st.tmux.insert(k, true);
        } else if out.status.success() {
            st.tmux.insert(k, false);
        }
    }
}
