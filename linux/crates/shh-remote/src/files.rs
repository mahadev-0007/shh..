//! File browsing and transfer for one server. Listing and housekeeping run as
//! shell commands over ssh; uploads and downloads go through sftp. Both ride
//! the same control socket, so an open session means no extra login at all.

use crate::exec::{self, RemoteError};
use shh_core::server::Server;
use shh_core::{shell, tools};
use std::cmp::Ordering;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// One entry in a remote directory.
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteEntry {
    pub name: String,
    /// A directory, or a symlink that points at one.
    pub is_dir: bool,
    pub is_link: bool,
    pub size: i64,
    /// Seconds since the epoch.
    pub modified: i64,
    /// `ls -l` style, e.g. "drwxr-xr-x".
    pub mode: String,
}

impl RemoteEntry {
    pub fn is_hidden(&self) -> bool {
        self.name.starts_with('.')
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Listing {
    pub path: String,
    pub entries: Vec<RemoteEntry>,
}

pub struct RemoteFiles {
    pub server: Server,
    control_path: String,
}

impl RemoteFiles {
    pub fn new(server: Server) -> Self {
        // With sharing off there is no session socket to borrow, but the
        // browser still wants one connection for all its round trips — so it
        // gets a private socket of its own.
        let control_path = if exec::share_connection() {
            exec::control_path(&server)
        } else {
            let id: u32 = rand::random();
            format!("/tmp/sshm-gui-{}-files-{:08X}.sock", exec::uid(), id)
        };
        RemoteFiles { server, control_path }
    }

    /// One round trip: resolve the path, mark which entries are directories
    /// (following links), then a single `stat` over the lot. GNU and BSD stat
    /// spell their formats differently, so try one and fall back to the other.
    pub fn list(&self, path: &str) -> Result<Listing, RemoteError> {
        let mut path = if path.is_empty() { "~".to_string() } else { path.to_string() };
        if path.chars().count() > 1 && path.ends_with('/') {
            path.pop();
        }
        match self.ssh(&list_script(&path)) {
            Err(RemoteError::Exited(9, _)) => Err(RemoteError::NotADirectory(path)),
            Err(e) => Err(e),
            Ok(out) => parse(&out).ok_or(RemoteError::NotADirectory(path)),
        }
    }

    pub fn make_directory(&self, path: &str) -> Result<(), RemoteError> {
        self.ssh(&format!("mkdir -- {}", shell::quote(path))).map(|_| ())
    }

    /// Refuses to overwrite: `mv` onto an existing directory would quietly move
    /// the item *into* it instead of renaming it.
    pub fn rename(&self, from: &str, to: &str) -> Result<(), RemoteError> {
        self.ssh(&rename_script(from, to)).map(|_| ())
    }

    /// Recursive. The UI is responsible for asking first.
    pub fn delete(&self, paths: &[String]) -> Result<(), RemoteError> {
        if paths.is_empty() {
            return Ok(());
        }
        let quoted: Vec<String> = paths.iter().map(|p| shell::quote(p)).collect();
        self.ssh(&format!("rm -rf -- {}", quoted.join(" "))).map(|_| ())
    }

    /// Copy local files or folders into a remote directory.
    pub fn upload(&self, locals: &[PathBuf], to_directory: &str) -> Result<(), RemoteError> {
        let batch: Vec<String> = locals.iter().map(|p| {
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            format!("put -r {} {}", sftp_quote(&p.to_string_lossy()),
                    sftp_quote(&join(to_directory, &name)))
        }).collect();
        self.sftp(&batch)
    }

    /// Copy remote files or folders to exact local destinations.
    pub fn download(&self, pairs: &[(String, PathBuf)]) -> Result<(), RemoteError> {
        let batch: Vec<String> = pairs.iter().map(|(remote, local)| {
            format!("get -r {} {}", sftp_quote(remote), sftp_quote(&local.to_string_lossy()))
        }).collect();
        self.sftp(&batch)
    }

    fn options(&self) -> Vec<String> {
        exec::options(&self.server, &self.control_path, true)
    }

    fn ssh(&self, script: &str) -> Result<String, RemoteError> {
        exec::ssh_script(&self.server, &self.control_path, true, script)
    }

    /// `sftp -b` forces BatchMode, which rules out password logins. So make
    /// sure a master connection is up first (a no-op when one already is),
    /// then let sftp ride it without authenticating at all.
    fn sftp(&self, commands: &[String]) -> Result<(), RemoteError> {
        self.ssh("true")?;
        let mut args = vec!["-P".to_string(), self.server.port.clone()];
        args.extend(self.options());
        args.extend(["-b".into(), "-".into(), self.server.target()]);
        let input = commands.join("\n") + "\n";
        exec::run(&tools::sftp(), &args, None, Some(input.as_bytes())).map(|_| ())
    }
}

pub(crate) fn list_script(path: &str) -> String {
    // "D/name" can't be confused with a stat line: a name never has a slash
    format!(
        "cd -- {} 2>/dev/null || exit 9\n\
         pwd\n\
         set --\n\
         for f in .[!.]* ..?* *; do\n\
         \x20 {{ [ -e \"$f\" ] || [ -L \"$f\" ]; }} || continue\n\
         \x20 set -- \"$@\" \"$f\"\n\
         \x20 [ -d \"$f\" ] && printf 'D/%s\\n' \"$f\"\n\
         done\n\
         echo '--'\n\
         [ $# -eq 0 ] && exit 0\n\
         if stat -c %s . >/dev/null 2>&1; then\n\
         \x20 stat -c '%A|%s|%Y|%n' -- \"$@\" 2>/dev/null\n\
         else\n\
         \x20 stat -f '%Sp|%z|%m|%N' -- \"$@\" 2>/dev/null\n\
         fi\n\
         exit 0",
        shell::quote_path(path))
}

pub(crate) fn rename_script(from: &str, to: &str) -> String {
    format!("[ -e {t} ] || [ -L {t} ] && {{ echo 'Something with that name already exists.' >&2; exit 1; }}; mv -- {f} {t}",
            t = shell::quote(to), f = shell::quote(from))
}

/// None when there is no pwd line, i.e. the cd never happened.
pub(crate) fn parse(out: &str) -> Option<Listing> {
    let mut lines = out.split('\n');
    let resolved = lines.next().filter(|l| !l.is_empty())?.to_string();

    let mut dirs: HashSet<&str> = HashSet::new();
    let mut entries = Vec::new();
    let mut in_stat = false;
    for line in lines.filter(|l| !l.is_empty()) {
        if !in_stat {
            if line == "--" {
                in_stat = true;
            } else if let Some(d) = line.strip_prefix("D/") {
                dirs.insert(d);
            }
            continue;
        }
        let parts: Vec<&str> = line.splitn(4, '|').collect();
        if parts.len() != 4 {
            continue;
        }
        entries.push(RemoteEntry {
            name: parts[3].to_string(),
            is_dir: dirs.contains(parts[3]),
            is_link: parts[0].starts_with('l'),
            size: parts[1].parse().unwrap_or(0),
            modified: parts[2].parse().unwrap_or(0),
            mode: parts[0].to_string(),
        });
    }
    entries.sort_by(|a, b| {
        if a.is_dir != b.is_dir {
            return if a.is_dir { Ordering::Less } else { Ordering::Greater };
        }
        natural_cmp(&a.name, &b.name)
    });
    Some(Listing { path: resolved, entries })
}

/// Finder-style ordering: case-insensitive, with digit runs compared as numbers
/// so `file2` sorts before `file10`.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (a, b): (Vec<char>, Vec<char>) = (a.to_lowercase().chars().collect(),
                                          b.to_lowercase().chars().collect());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let (si, sj) = (i, j);
            while i < a.len() && a[i].is_ascii_digit() { i += 1; }
            while j < b.len() && b[j].is_ascii_digit() { j += 1; }
            let na: String = a[si..i].iter().collect::<String>().trim_start_matches('0').to_string();
            let nb: String = b[sj..j].iter().collect::<String>().trim_start_matches('0').to_string();
            let ord = na.len().cmp(&nb.len()).then_with(|| na.cmp(&nb));
            if ord != Ordering::Equal { return ord; }
        } else {
            if a[i] != b[j] { return a[i].cmp(&b[j]); }
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

pub fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') { format!("{dir}{name}") } else { format!("{dir}/{name}") }
}

/// The parent of a remote path; "/" is its own parent.
pub fn parent(path: &str) -> String {
    let p = path.trim_end_matches('/');
    match p.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(i) => p[..i].to_string(),
    }
}

/// Escape one path for an sftp batch line.
///
/// sftp splits its commands on whitespace and globs every source path. Inside
/// double quotes it *double*-escapes a backslashed glob character, so `"a\*b"`
/// looks for a file literally named `a\*b` — which is what the Mac app's
/// quoting sends, and why it cannot fetch a file with `*`, `?` or `[` in its
/// name. Unquoted, a backslash does what you would expect: it makes the next
/// character literal, glob characters included. So nothing is quoted and
/// everything awkward is backslashed. `#` starts a comment at the head of a
/// word, hence its place in the list.
pub fn sftp_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        if " \t\"'\\*?[]#".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    if out.is_empty() { "\"\"".into() } else { out }
}

/// A local path that doesn't exist yet: `name`, then `name 2`, `name 3`…
pub fn unique_local(path: &Path) -> PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|s| s.to_string_lossy().into_owned());
    let dir = path.parent().unwrap_or(Path::new("."));
    for i in 2.. {
        let name = match &ext {
            Some(e) => format!("{stem} {i}.{e}"),
            None => format!("{stem} {i}"),
        };
        let c = dir.join(name);
        if !c.exists() {
            return c;
        }
    }
    unreachable!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sftp_quoting() {
        assert_eq!(sftp_quote("a b"), "a\\ b");
        assert_eq!(sftp_quote("it's"), "it\\'s");
        assert_eq!(sftp_quote("a*b?[c]\"\\"), "a\\*b\\?\\[c\\]\\\"\\\\");
        assert_eq!(sftp_quote("#x"), "\\#x");
        assert_eq!(sftp_quote("/plain/path.txt"), "/plain/path.txt");
    }

    #[test]
    fn joins_and_parents() {
        assert_eq!(join("/a", "b"), "/a/b");
        assert_eq!(join("/", "b"), "/b");
        assert_eq!(parent("/a/b"), "/a");
        assert_eq!(parent("/a"), "/");
        assert_eq!(parent("/"), "/");
    }

    #[test]
    fn parses_listing() {
        let out = "/srv/app\nD/src\nD/link\n--\n\
                   -rw-r--r--|120|1700000000|b|pipe.txt\n\
                   drwxr-xr-x|4096|1700000001|src\n\
                   lrwxrwxrwx|3|1700000002|link\n\
                   -rw-r--r--|9|1700000003|.env\n\
                   garbage\n";
        let l = parse(out).unwrap();
        assert_eq!(l.path, "/srv/app");
        let names: Vec<&str> = l.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["link", "src", ".env", "b|pipe.txt"]);
        assert!(l.entries[0].is_link && l.entries[0].is_dir);
        assert_eq!(l.entries[3].size, 120);
        assert!(l.entries[2].is_hidden());
        assert!(parse("").is_none());
        assert_eq!(parse("/empty\n--\n").unwrap().entries.len(), 0);
    }

    #[test]
    fn natural_order() {
        assert_eq!(natural_cmp("file2", "file10"), Ordering::Less);
        assert_eq!(natural_cmp("B", "a"), Ordering::Greater);
        assert_eq!(natural_cmp("a", "a1"), Ordering::Less);
    }

    #[test]
    fn scripts_match_the_mac_app() {
        assert!(list_script("~/x y").starts_with("cd -- \"$HOME\"/'x y' 2>/dev/null || exit 9\npwd\nset --\nfor f in .[!.]* ..?* *; do\n  { [ -e \"$f\" ] || [ -L \"$f\" ]; } || continue\n"));
        assert!(list_script("/").contains("  [ -d \"$f\" ] && printf 'D/%s\\n' \"$f\"\ndone\necho '--'\n"));
        assert!(list_script("/").ends_with("  stat -f '%Sp|%z|%m|%N' -- \"$@\" 2>/dev/null\nfi\nexit 0"));
        assert_eq!(rename_script("/a", "/b"),
            "[ -e '/b' ] || [ -L '/b' ] && { echo 'Something with that name already exists.' >&2; exit 1; }; mv -- '/a' '/b'");
    }
}
