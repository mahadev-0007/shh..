//! How to reach a server without a pty, and how to run ssh or sftp against it.

use shh_core::server::Server;
use shh_core::tools;
use std::fmt;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

static SHARE_CONNECTION: AtomicBool = AtomicBool::new(true);

/// Mirror of Settings → "share one connection per server". The app sets this
/// whenever settings load or change; it defaults to on, as the setting does.
pub fn set_share_connection(on: bool) {
    SHARE_CONNECTION.store(on, Ordering::Relaxed);
}
pub fn share_connection() -> bool {
    SHARE_CONNECTION.load(Ordering::Relaxed)
}

fn radix36(mut n: u64) -> String {
    if n == 0 {
        return "0".into();
    }
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    while n > 0 {
        out.push(digits[(n % 36) as usize]);
        n /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap()
}

/// The hash half of the socket name: djb2 over "user@host:port", base 36.
pub fn control_hash(target: &str, port: &str) -> String {
    let mut h: u64 = 5381;
    for b in format!("{target}:{port}").bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    radix36(h)
}

pub fn uid() -> u32 {
    unsafe { libc::getuid() }
}

/// One socket per server. Sessions use the same name, so helpers ride an open
/// session's connection instead of authenticating a second time.
pub fn control_path(server: &Server) -> String {
    format!("/tmp/sshm-gui-{}-{}.sock", uid(), control_hash(&server.target(), &server.port))
}

/// The `-o` options shared by ssh and sftp. The port flag is left out because
/// the two disagree on it (`-p` vs `-P`).
pub fn options(server: &Server, control_path: &str, master: bool) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "-o".into(), "ConnectTimeout=8".into(),
        "-o".into(), format!("ControlMaster={}", if master { "auto" } else { "no" }),
        "-o".into(), "ControlPersist=60".into(),
        "-o".into(), format!("ControlPath={control_path}"),
    ];
    if server.auth == "key" {
        // no prompt is possible or wanted here, so fail fast instead of hanging
        args.extend(["-i".into(), server.secret.clone(), "-o".into(), "IdentitiesOnly=yes".into(),
                     "-o".into(), "BatchMode=yes".into()]);
    } else {
        // NOT BatchMode: it disables password auth entirely, so sshpass would
        // never be offered a prompt to answer.
        args.extend(["-o".into(), "PubkeyAuthentication=no".into(),
                     "-o".into(), "PreferredAuthentications=password,keyboard-interactive".into(),
                     "-o".into(), "NumberOfPasswordPrompts=1".into()]);
    }
    args
}

#[derive(Debug, Clone, PartialEq)]
pub enum RemoteError {
    NotADirectory(String),
    Exited(i32, String),
    Spawn(String),
}

impl fmt::Display for RemoteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RemoteError::NotADirectory(p) => write!(f, "“{p}” isn't a directory you can read."),
            RemoteError::Exited(code, s) => {
                // ssh is chatty; the last non-empty line is the useful one
                if let Some(detail) = s.lines().filter(|l| !l.is_empty()).last() {
                    return write!(f, "{detail}");
                }
                if *code == 255 {
                    write!(f, "Could not reach the server.")
                } else {
                    write!(f, "The server refused that (exit {code}).")
                }
            }
            RemoteError::Spawn(s) => write!(f, "{s}"),
        }
    }
}
impl std::error::Error for RemoteError {}

/// Run ssh or sftp to completion and return stdout. Blocking: call it from a
/// worker thread, never the GTK main loop.
///
/// A password host goes through `sshpass -e` with SSHPASS in the environment
/// rather than the fd-3 fifo a session gets: this is a short-lived helper with
/// no pty, and a process's environment is readable only by its own user — the
/// same boundary that already protects servers.conf.
pub fn run(tool: &str, args: &[String], password: Option<&str>, input: Option<&[u8]>)
    -> Result<String, RemoteError> {
    let mut cmd = match (password, tools::sshpass()) {
        (Some(pass), Some(sshpass)) => {
            let mut c = Command::new(sshpass);
            c.arg("-e").arg(tool).args(args).env("SSHPASS", pass);
            c
        }
        _ => {
            let mut c = Command::new(tool);
            c.args(args);
            c
        }
    };
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    cmd.stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });

    let mut child = cmd.spawn().map_err(|e| RemoteError::Spawn(format!("{tool}: {e}")))?;

    // stdin and stderr each get a thread: a large upload or a chatty sftp can
    // fill one pipe while we are blocked on another, and then both sides wait.
    let writer = child.stdin.take().zip(input.map(|d| d.to_vec())).map(|(mut w, data)| {
        std::thread::spawn(move || {
            let _ = w.write_all(&data);
        })
    });
    let mut err = child.stderr.take().unwrap();
    let err_thread = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = err.read_to_end(&mut s);
        s
    });
    let mut out = Vec::new();
    let _ = child.stdout.take().unwrap().read_to_end(&mut out);
    let err_data = err_thread.join().unwrap_or_default();
    if let Some(w) = writer {
        let _ = w.join();
    }
    let status = child.wait().map_err(|e| RemoteError::Spawn(e.to_string()))?;

    if status.success() {
        Ok(String::from_utf8_lossy(&out).into_owned())
    } else {
        Err(RemoteError::Exited(status.code().unwrap_or(-1),
                                String::from_utf8_lossy(&err_data).trim().to_string()))
    }
}

/// Run a POSIX sh script on the server over its shared socket.
pub fn ssh_script(server: &Server, control_path: &str, master: bool, script: &str)
    -> Result<String, RemoteError> {
    let mut args = vec!["-p".to_string(), server.port.clone()];
    args.extend(options(server, control_path, master));
    args.push(server.target());
    // the remote login shell might be fish or anything else: sh explicitly
    args.push(format!("sh -c {}", shh_core::shell::quote(script)));
    run(&tools::ssh(), &args, server.password().as_deref(), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn radix() {
        assert_eq!(radix36(0), "0");
        assert_eq!(radix36(35), "z");
        assert_eq!(radix36(36), "10");
        assert_eq!(radix36(u64::MAX), "3w5e11264sgsf");
    }

    #[test]
    fn hash_is_djb2() {
        // h("a:1") by hand: ((5381*33+97)*33+58)*33+49
        let h = ((5381u64 * 33 + 97) * 33 + 58) * 33 + 49;
        assert_eq!(control_hash("a", "1"), radix36(h));
    }

    #[test]
    fn error_text() {
        assert_eq!(RemoteError::Exited(1, "a\n\nPermission denied".into()).to_string(),
                   "Permission denied");
        assert_eq!(RemoteError::Exited(255, String::new()).to_string(),
                   "Could not reach the server.");
        assert_eq!(RemoteError::Exited(3, String::new()).to_string(),
                   "The server refused that (exit 3).");
    }
}
