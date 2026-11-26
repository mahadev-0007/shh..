//! Finding and ending shh's tmux sessions on a server, outside any tab.

use crate::exec::{self, RemoteError};
use crate::TMUX_PATHS;
use shh_core::server::Server;
use shh_core::shell;

/// A tmux session shh started on a server that no tab is attached to — the tab
/// was closed, or the app quit, but the agent in it is still running.
#[derive(Debug, Clone, PartialEq)]
pub struct BackgroundSession {
    pub server: Server,
    /// The tmux session name, `shh-<slug>-<ordinal>-<id4>`.
    pub name: String,
    /// The project slug inside the name (may itself contain dashes).
    pub slug: String,
    pub ordinal: i64,
    /// First four characters of the owning project's id, lowercased. The app
    /// matches this (then `slug` as a tie-break) against its project list.
    pub id4: String,
    /// Seconds since the epoch.
    pub created: i64,
    pub last_activity: i64,
    /// Clients attached right now — another machine, or a terminal on the box.
    pub attached_clients: i64,
}

/// Find tmux the way the session wrapper does (Homebrew's isn't on a bare PATH).
fn find_tmux() -> String {
    format!("t=$(command -v tmux 2>/dev/null); for c in {TMUX_PATHS}; do [ -z \"$t\" ] && [ -x \"$c\" ] && t=$c; done; ")
}

pub(crate) fn list_script() -> String {
    find_tmux() + "[ -n \"$t\" ] || exit 0; \"$t\" list-sessions -F \
'#{session_name}|#{session_created}|#{session_activity}|#{session_attached}' 2>/dev/null; exit 0"
}

pub(crate) fn kill_script(name: &str) -> String {
    let target = shell::quote(&format!("={name}"));
    format!("{}[ -n \"$t\" ] || exit 0; \"$t\" has-session -t {target} 2>/dev/null || exit 0; exec \"$t\" kill-session -t {target}",
            find_tmux())
}

/// Every `shh-` tmux session on a server. No tmux, or no tmux server running,
/// is an empty list rather than an error. Blocking.
pub fn list(server: &Server) -> Result<Vec<BackgroundSession>, RemoteError> {
    let out = run(server, &list_script(), None)?;
    Ok(out.lines().filter_map(|l| parse(l, server)).collect())
}

/// Kill one session by exact name. Already gone counts as success. Blocking.
pub fn kill(server: &Server, name: &str, control_path: Option<&str>) -> Result<(), RemoteError> {
    run(server, &kill_script(name), control_path).map(|_| ())
}

pub(crate) fn parse(line: &str, server: &Server) -> Option<BackgroundSession> {
    let f: Vec<&str> = line.split('|').collect();
    if f.len() != 4 || !f[0].starts_with("shh-") {
        return None;
    }
    // shh-<slug>-<ordinal>-<id4>; the slug itself may contain dashes
    let parts: Vec<&str> = f[0].split('-').filter(|p| !p.is_empty()).collect();
    if parts.len() < 4 {
        return None;
    }
    let ordinal: i64 = parts[parts.len() - 2].parse().ok()?;
    Some(BackgroundSession {
        server: server.clone(),
        name: f[0].to_string(),
        slug: parts[1..parts.len() - 2].join("-"),
        ordinal,
        id4: parts[parts.len() - 1].to_string(),
        created: f[1].parse().unwrap_or(0),
        last_activity: f[2].parse().unwrap_or(0),
        attached_clients: f[3].parse().unwrap_or(0),
    })
}

/// Rides an open session's socket when there is one, and otherwise opens one
/// that lingers a minute so the next check is free.
fn run(server: &Server, script: &str, control_path: Option<&str>) -> Result<String, RemoteError> {
    let own;
    let path = match control_path {
        Some(p) => p,
        None => {
            own = exec::control_path(server);
            &own
        }
    };
    exec::ssh_script(server, path, control_path.is_some() || exec::share_connection(), script)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn srv() -> Server {
        Server { name: "s".into(), host: "h".into(), user: "u".into(), port: "22".into(),
                 auth: "key".into(), secret: String::new() }
    }

    #[test]
    fn parses_names() {
        let b = parse("shh-arkboss-crm-2-0751|1700000000|1700000500|1", &srv()).unwrap();
        assert_eq!((b.slug.as_str(), b.ordinal, b.id4.as_str()), ("arkboss-crm", 2, "0751"));
        assert_eq!((b.created, b.last_activity, b.attached_clients), (1700000000, 1700000500, 1));
        assert!(parse("main|1|2|0", &srv()).is_none());
        assert!(parse("shh-x-y|1|2|0", &srv()).is_none());
        assert!(parse("shh-a-b-c-d|1|2|0", &srv()).is_none());
    }

    #[test]
    fn scripts_match_the_mac_app() {
        assert_eq!(list_script(),
            "t=$(command -v tmux 2>/dev/null); for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux; do [ -z \"$t\" ] && [ -x \"$c\" ] && t=$c; done; [ -n \"$t\" ] || exit 0; \"$t\" list-sessions -F '#{session_name}|#{session_created}|#{session_activity}|#{session_attached}' 2>/dev/null; exit 0");
        assert!(kill_script("shh-a-1-ab12").ends_with(
            "[ -n \"$t\" ] || exit 0; \"$t\" has-session -t '=shh-a-1-ab12' 2>/dev/null || exit 0; exec \"$t\" kill-session -t '=shh-a-1-ab12'"));
    }
}
