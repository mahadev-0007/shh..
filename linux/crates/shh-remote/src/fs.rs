//! Lists directories on a server so the project form can browse instead of
//! making you remember paths.

use crate::exec::{self, RemoteError};
use shh_core::server::Server;
use shh_core::{shell, tools};

#[derive(Debug, Clone, PartialEq)]
pub struct Listing {
    pub path: String,
    pub directories: Vec<String>,
}

/// `ls -1p` and keep the entries ending in "/" — one round trip. Blocking.
pub fn list(server: &Server, path: &str) -> Result<Listing, RemoteError> {
    let mut path = if path.is_empty() { "~".to_string() } else { path.to_string() };
    if path.chars().count() > 1 && path.ends_with('/') {
        path.pop();
    }
    // `|| true`: grep exits 1 when a directory has no subdirectories, which is
    // a fine empty listing. Exit 9 distinguishes "not a directory" from ssh
    // itself failing.
    let script = format!("cd -- {} 2>/dev/null || exit 9; pwd; ls -1p 2>/dev/null | grep '/$' || true",
                         shell::quote_path(&path));
    let mut args = vec!["-p".to_string(), server.port.clone()];
    args.extend(exec::options(server, &exec::control_path(server), exec::share_connection()));
    args.push(server.target());
    args.push(script);

    match exec::run(&tools::ssh(), &args, server.password().as_deref(), None) {
        Err(RemoteError::Exited(9, _)) => Err(RemoteError::NotADirectory(path)),
        Err(e) => Err(e),
        Ok(out) => parse(&out).ok_or(RemoteError::NotADirectory(path)),
    }
}

pub(crate) fn parse(out: &str) -> Option<Listing> {
    let mut lines = out.split('\n').filter(|l| !l.is_empty());
    // no pwd line means the cd never happened
    let resolved = lines.next()?.to_string();
    let mut dirs: Vec<String> = lines.map(|l| l.strip_suffix('/').unwrap_or(l).to_string()).collect();
    dirs.sort_by_key(|d| d.to_lowercase());
    Some(Listing { path: resolved, directories: dirs })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses() {
        let l = parse("/srv\nweb/\nApp/\n").unwrap();
        assert_eq!(l.path, "/srv");
        assert_eq!(l.directories, vec!["App", "web"]);
        assert!(parse("").is_none());
    }
}
