//! Key, fingerprint and authorized_keys plumbing.
use base64::Engine;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

pub fn ssh_dir() -> PathBuf {
    shh_core::paths::ssh_dir()
}
pub fn authorized_keys() -> PathBuf {
    ssh_dir().join("authorized_keys")
}
pub fn known_hosts() -> PathBuf {
    ssh_dir().join("known_hosts")
}
pub fn guest_key_dir() -> PathBuf {
    shh_core::paths::config_dir().join("keys")
}

pub const ALLOWED_TYPES: [&str; 6] = [
    "ssh-ed25519",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "ssh-rsa",
    "sk-ssh-ed25519@openssh.com",
];

/// "type base64" from a public key line, with any comment or options dropped.
/// None unless it is exactly one well-formed key.
pub fn normalize_public_key(line: &str) -> Option<String> {
    if !shh_core::shell::is_safe(line) || line.contains('"') {
        return None;
    }
    let parts: Vec<&str> = line.split(' ').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 || !ALLOWED_TYPES.contains(&parts[0]) {
        return None;
    }
    let blob = B64.decode(parts[1]).ok()?;
    if blob.len() < 32 {
        return None;
    }
    Some(format!("{} {}", parts[0], parts[1]))
}

/// SHA256 fingerprint in ssh-keygen's format.
pub fn fingerprint(public_key: &str) -> Option<String> {
    let parts: Vec<&str> = public_key.split(' ').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 {
        return None;
    }
    let blob = B64.decode(parts[1]).ok()?;
    let digest = B64.encode(Sha256::digest(&blob));
    Some(format!("SHA256:{}", digest.replace('=', "")))
}

/// This machine's sshd host keys, best first ("type base64").
pub fn host_keys() -> Vec<String> {
    let dir = shh_core::env::string("SSHM_HOST_KEY_DIR", "/etc/ssh");
    ["ed25519", "ecdsa", "rsa"]
        .iter()
        .filter_map(|kind| {
            let text = std::fs::read_to_string(format!("{dir}/ssh_host_{kind}_key.pub")).ok()?;
            normalize_public_key(text.trim())
        })
        .collect()
}

pub fn random_token(bytes: usize) -> String {
    use rand::RngCore;
    let mut b = vec![0u8; bytes];
    rand::rngs::OsRng.fill_bytes(&mut b);
    B64.encode(&b).replace('+', "-").replace('/', "_").replace('=', "")
}

pub fn hash(token: &str) -> String {
    B64.encode(Sha256::digest(token.as_bytes()))
}

// ---- authorized_keys -------------------------------------------------------

/// The tag that marks a line as ours. Revoking deletes exactly the lines
/// carrying a guest's tag and never touches anything else in the file.
pub fn tag(guest_id: &str) -> String {
    format!("shh-guest:{guest_id}")
}

/// Locked to the guest's own tailnet addresses. No forwarding of any kind.
pub fn authorized_line(key: &str, addresses: &[String], guest_id: &str) -> String {
    let from: Vec<&str> = addresses
        .iter()
        .map(|s| s.as_str())
        .filter(|a| shh_core::shell::is_safe(a) && !a.contains('"') && !a.contains(','))
        .collect();
    format!(
        "from=\"{}\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding {} {}",
        from.join(","),
        key,
        tag(guest_id)
    )
}

fn ensure_ssh_dir() -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    let d = ssh_dir();
    if !d.exists() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&d)?;
    }
    Ok(())
}

/// The real file behind a path, so a symlinked authorized_keys (dotfile
/// managers do this) is edited in place rather than replaced by a copy.
fn resolved(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

fn last_field(line: &str) -> &str {
    line.split(' ').filter(|p| !p.is_empty()).last().unwrap_or("")
}

/// `text` with one more line, keeping whatever was there.
pub fn appended(text: &str, line: &str) -> String {
    let mut t = text.to_string();
    if !t.is_empty() && !t.ends_with('\n') {
        t.push('\n');
    }
    t.push_str(line);
    t.push('\n');
    t
}

/// `text` without the lines tagged for these guests; None if nothing matched.
pub fn without_guests(text: &str, guest_ids: &HashSet<String>) -> Option<String> {
    let tags: HashSet<String> = guest_ids.iter().map(|g| tag(g)).collect();
    let lines: Vec<&str> = text.split('\n').collect();
    let kept: Vec<&str> = lines.iter().copied().filter(|l| !tags.contains(last_field(l))).collect();
    if kept.len() == lines.len() {
        return None;
    }
    Some(kept.join("\n"))
}

pub fn add_authorized(line: &str) -> io::Result<()> {
    ensure_ssh_dir()?;
    let url = resolved(&authorized_keys());
    let text = std::fs::read_to_string(&url).unwrap_or_default();
    shh_core::fsutil::write_atomic(&url, appended(&text, line).as_bytes(), 0o600)
}

pub fn remove_authorized(guest_ids: &HashSet<String>) -> io::Result<()> {
    if guest_ids.is_empty() {
        return Ok(());
    }
    let url = resolved(&authorized_keys());
    let Ok(text) = std::fs::read_to_string(&url) else { return Ok(()) };
    match without_guests(&text, guest_ids) {
        Some(t) => shh_core::fsutil::write_atomic(&url, t.as_bytes(), 0o600),
        None => Ok(()),
    }
}

/// Every shh guest tag currently present in authorized_keys.
pub fn authorized_guest_ids() -> HashSet<String> {
    let text = std::fs::read_to_string(resolved(&authorized_keys())).unwrap_or_default();
    text.split('\n')
        .filter_map(|l| last_field(l).strip_prefix("shh-guest:").map(|s| s.to_string()))
        .collect()
}

// ---- guest side ------------------------------------------------------------

/// A fresh ed25519 key for one host. Returns (private key path, public line).
pub fn generate_guest_key(name: &str) -> io::Result<(String, String)> {
    use std::os::unix::fs::DirBuilderExt;
    let dir = guest_key_dir();
    if !dir.exists() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    }
    let mut path = dir.join(name);
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{name}-{n}"));
        n += 1;
    }
    let path = path.to_string_lossy().into_owned();
    let keygen = shh_core::tools::which("ssh-keygen").unwrap_or_else(|| "/usr/bin/ssh-keygen".into());
    let r = crate::sys::run(
        &keygen,
        &["-q", "-t", "ed25519", "-N", "", "-C", "shh guest", "-f", &path],
        None,
        None,
    );
    let failed = || io::Error::new(io::ErrorKind::Other, "ssh-keygen failed");
    if r.status != 0 {
        return Err(failed());
    }
    let public = std::fs::read_to_string(format!("{path}.pub"))?;
    let line = normalize_public_key(public.trim()).ok_or_else(failed)?;
    Ok((path, line))
}

/// Trust these host keys for these names, as if the user had said "yes" to
/// ssh's prompt — except the keys were checked against the invite.
pub fn add_known_hosts(names: &[String], keys: &[String]) -> io::Result<()> {
    ensure_ssh_dir()?;
    let url = resolved(&known_hosts());
    let mut text = std::fs::read_to_string(&url).unwrap_or_default();
    let host_field: Vec<&str> = names.iter().map(|s| s.as_str()).filter(|n| !n.is_empty()).collect();
    let host_field = host_field.join(",");
    if host_field.is_empty() {
        return Ok(());
    }
    let mut added = false;
    for k in keys {
        let line = format!("{host_field} {k}");
        if text.contains(&line) {
            continue;
        }
        text = appended(&text, &line);
        added = true;
    }
    if !added {
        return Ok(());
    }
    shh_core::fsutil::write_atomic(&url, text.as_bytes(), 0o600)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    #[test]
    fn token_hash_matches_swift() {
        // base64(sha256("abc")), with padding, as CryptoKit + base64EncodedString give
        assert_eq!(hash("abc"), "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
        let t = random_token(18);
        assert_eq!(t.len(), 24);
        assert!(!t.contains('+') && !t.contains('/') && !t.contains('='));
        assert_ne!(t, random_token(18));
    }

    #[test]
    fn public_keys() {
        assert_eq!(normalize_public_key(&format!("{KEY} me@host")).as_deref(), Some(KEY));
        assert!(normalize_public_key("ssh-dss AAAAB3NzaC1kc3M=").is_none());
        assert!(normalize_public_key(&format!("{KEY}\nssh-rsa x")).is_none());
        assert!(normalize_public_key("command=\"x\" ssh-ed25519 AAAA").is_none());
        let fp = fingerprint(KEY).unwrap();
        assert!(fp.starts_with("SHA256:") && fp.len() == 7 + 43 && !fp.contains('='));
    }

    #[test]
    fn authorized_keys_lines() {
        let line = authorized_line(KEY, &["100.64.0.9".into(), "fd7a:115c:a1e0::9".into(), "bad,one".into()], "g1");
        assert_eq!(
            line,
            format!("from=\"100.64.0.9,fd7a:115c:a1e0::9\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding {KEY} shh-guest:g1")
        );
        let mine = "ssh-rsa AAAA someone@else";
        let text = appended(mine, &line);
        assert_eq!(text, format!("{mine}\n{line}\n"));
        let other = authorized_line(KEY, &["100.64.0.10".into()], "g2");
        let text = appended(&text, &other);
        let ids: HashSet<String> = ["g1".to_string()].into();
        let after = without_guests(&text, &ids).unwrap();
        assert_eq!(after, format!("{mine}\n{other}\n"));
        assert!(without_guests(&after, &ids).is_none());
    }
}
