use std::os::unix::fs::PermissionsExt;
use std::path::Path;

pub fn which(name: &str) -> Option<String> {
    let path = std::env::var("PATH").unwrap_or_default();
    let dirs = path
        .split(':')
        .chain(["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/snap/bin"]);
    for d in dirs {
        if d.is_empty() {
            continue;
        }
        let p = Path::new(d).join(name);
        if let Ok(m) = std::fs::metadata(&p) {
            if m.is_file() && m.permissions().mode() & 0o111 != 0 {
                return Some(p.to_string_lossy().into_owned());
            }
        }
    }
    None
}

pub fn ssh() -> String {
    which("ssh").unwrap_or_else(|| "/usr/bin/ssh".into())
}
pub fn sftp() -> String {
    which("sftp").unwrap_or_else(|| "/usr/bin/sftp".into())
}
pub fn sshpass() -> Option<String> {
    which("sshpass")
}
