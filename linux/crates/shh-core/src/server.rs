//! `servers.conf`: `name|host|user|port|auth|secret`, one per line. The format
//! is fixed by the bash TUI and must stay byte-compatible.
use crate::{fsutil, paths};
use base64::Engine;
use std::collections::HashSet;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Server {
    pub name: String,
    pub host: String,
    pub user: String,
    pub port: String,
    /// "pass" | "key"
    pub auth: String,
    /// base64(password) when auth == pass, else an identity file path
    pub secret: String,
}

/// The TUI's twelve vivid hues, in the same order.
pub const PALETTE: [(u8, u8, u8); 12] = [
    (167, 139, 250), (34, 211, 238), (52, 211, 153), (251, 191, 36),
    (251, 113, 133), (56, 189, 248), (163, 230, 53), (232, 121, 249),
    (251, 146, 60), (45, 212, 191), (129, 140, 248), (248, 113, 113),
];
pub const PALETTE_NAMES: [&str; 12] = [
    "violet", "cyan", "emerald", "amber", "rose", "sky", "lime", "fuchsia", "orange", "teal",
    "indigo", "red",
];

impl Server {
    pub fn target(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }
    pub fn display(&self) -> String {
        if self.port == "22" {
            self.target()
        } else {
            format!("{}:{}", self.target(), self.port)
        }
    }
    /// The plaintext password, or None for key auth.
    pub fn password(&self) -> Option<String> {
        if self.auth != "pass" || self.secret.is_empty() {
            return None;
        }
        let d = base64::engine::general_purpose::STANDARD.decode(&self.secret).ok()?;
        String::from_utf8(d).ok()
    }
    pub fn encode_password(plain: &str) -> String {
        base64::engine::general_purpose::STANDARD.encode(plain.as_bytes())
    }
    /// The same stable name→hue hash the bash TUI and the Mac app use.
    pub fn hue(&self) -> usize {
        let mut sum: i64 = 0;
        for (i, c) in self.name.chars().enumerate() {
            sum += (c as i64) * (i as i64 + 3);
        }
        sum.rem_euclid(PALETTE.len() as i64) as usize
    }
    pub fn rgb(&self) -> (u8, u8, u8) {
        PALETTE[self.hue()]
    }
}

pub const HEADER: &str = "# sshm servers - name|host|user|port|auth|secret\n";

pub fn file() -> PathBuf {
    paths::config_dir().join("servers.conf")
}

/// Malformed lines are skipped, not fatal.
pub fn parse(text: &str) -> Vec<Server> {
    let mut out = Vec::new();
    for line in text.split('\n') {
        if line.is_empty() || line.starts_with('#') || line.starts_with(' ') {
            continue;
        }
        let f: Vec<&str> = line.split('|').collect();
        if f.len() < 3 || f[0].is_empty() || f[1].is_empty() || f[2].is_empty() {
            continue;
        }
        let get = |i: usize, d: &str| match f.get(i) {
            Some(v) if !v.is_empty() => v.to_string(),
            _ => d.to_string(),
        };
        out.push(Server {
            name: f[0].into(),
            host: f[1].into(),
            user: f[2].into(),
            port: get(3, "22"),
            auth: get(4, "pass"),
            secret: f.get(5).map(|s| s.to_string()).unwrap_or_default(),
        });
    }
    out
}

pub fn serialize(list: &[Server]) -> String {
    let mut text = String::from(HEADER);
    for s in list {
        text.push_str(&format!(
            "{}|{}|{}|{}|{}|{}\n",
            s.name, s.host, s.user, s.port, s.auth, s.secret
        ));
    }
    text
}

fn ensure_file() {
    paths::ensure_dir();
    let p = file();
    match std::fs::metadata(&p) {
        Err(_) => {
            let _ = fsutil::write_atomic(&p, HEADER.as_bytes(), 0o600);
        }
        Ok(m) => {
            // the script tightens loose permissions on sight; so do we
            if m.permissions().mode() & 0o077 != 0 {
                let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
            }
        }
    }
}

pub fn load() -> Vec<Server> {
    ensure_file();
    std::fs::read_to_string(file()).map(|t| parse(&t)).unwrap_or_default()
}

/// Every mutation re-reads the file first, so an edit the bash TUI made a
/// moment ago survives ours.
fn commit(mutate: impl FnOnce(&mut Vec<Server>)) {
    let mut list = load();
    mutate(&mut list);
    let _ = fsutil::write_atomic(&file(), serialize(&list).as_bytes(), 0o600);
}

pub fn add(s: Server) {
    commit(|l| l.push(s));
}

pub fn update(s: Server, slug: &str) {
    commit(|l| match l.iter().position(|x| x.name == slug) {
        Some(i) => l[i] = s,
        None => l.push(s),
    });
}

pub fn remove(slug: &str) {
    commit(|l| l.retain(|x| x.name != slug));
}

pub fn slugs() -> HashSet<String> {
    load().into_iter().map(|s| s.name).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_matches_the_tui() {
        let text = "# sshm servers - name|host|user|port|auth|secret\n\
                    saas-server|203.0.113.10|root|22|pass|aHVudGVyMg==\n\
                    db-01|10.0.0.9|admin|2222|key|/home/me/.ssh/id_ed25519\n\
                    short|h|u\n\
                    bad|\n\
                    \n leading-space|h|u\n";
        let s = parse(text);
        assert_eq!(s.len(), 3);
        assert_eq!(s[0].password().as_deref(), Some("hunter2"));
        assert_eq!(s[1].display(), "admin@10.0.0.9:2222");
        assert_eq!(s[1].password(), None);
        assert_eq!((s[2].port.as_str(), s[2].auth.as_str()), ("22", "pass"));
    }

    #[test]
    fn round_trip_is_byte_identical() {
        let text = "# sshm servers - name|host|user|port|auth|secret\n\
                    a|h|u|22|pass|cA==\nb|h2|u2|2222|key|~/.ssh/k\n";
        assert_eq!(serialize(&parse(text)), text);
    }

    #[test]
    fn hue_is_the_tui_hash() {
        // sum of codepoint * (index + 3), mod 12
        let s = |n: &str| Server { name: n.into(), ..Default::default() };
        assert_eq!(s("a").hue(), (97 * 3) % 12);
        assert_eq!(s("ab").hue(), (97 * 3 + 98 * 4) % 12);
        // README: saas-server is rose
        assert_eq!(PALETTE_NAMES[s("saas-server").hue()], "rose");
    }
}
