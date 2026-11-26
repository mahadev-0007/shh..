use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

/// `$XDG_CONFIG_HOME/sshm`, the directory the bash TUI defines.
pub fn config_dir() -> PathBuf {
    let base = match std::env::var("XDG_CONFIG_HOME") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => home().join(".config"),
    };
    base.join("sshm")
}

pub fn ensure_dir() {
    let d = config_dir();
    if !d.exists() {
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&d);
    }
}

/// Where authorized_keys / known_hosts are edited. Overridable for tests.
pub fn ssh_dir() -> PathBuf {
    match std::env::var("SSHM_SSH_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => home().join(".ssh"),
    }
}
