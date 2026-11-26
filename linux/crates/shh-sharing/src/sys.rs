//! Small OS helpers.
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::Duration;

pub fn user_name() -> String {
    if let Ok(u) = std::env::var("USER") {
        if !u.is_empty() {
            return u;
        }
    }
    let out = Command::new("id").arg("-un").output().ok();
    out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// What this machine calls itself, for labels.
pub fn host_label() -> String {
    for p in ["/etc/hostname", "/proc/sys/kernel/hostname"] {
        if let Ok(t) = std::fs::read_to_string(p) {
            let t = t.trim();
            if !t.is_empty() {
                return t.to_string();
            }
        }
    }
    let out = Command::new("hostname").output().ok();
    out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub struct Output {
    pub status: i32,
    pub out: String,
    pub err: String,
}

/// Run to completion with stdin closed (or fed `input`), killing it after
/// `timeout` so a wedged child cannot wedge the caller.
pub fn run(program: &str, args: &[&str], input: Option<&[u8]>, timeout: Option<Duration>) -> Output {
    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Output { status: -1, out: String::new(), err: e.to_string() },
    };
    if let (Some(data), Some(mut stdin)) = (input, child.stdin.take()) {
        use std::io::Write;
        let _ = stdin.write_all(data);
    }
    let pid = child.id() as libc::pid_t;
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    if let Some(t) = timeout {
        let done = done.clone();
        std::thread::spawn(move || {
            let step = Duration::from_millis(100);
            let mut left = t;
            while left > Duration::ZERO {
                if done.load(std::sync::atomic::Ordering::SeqCst) {
                    return;
                }
                std::thread::sleep(step);
                left = left.saturating_sub(step);
            }
            if !done.load(std::sync::atomic::Ordering::SeqCst) {
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        });
    }
    let mut stderr = child.stderr.take();
    let err_thread = std::thread::spawn(move || {
        let mut s = Vec::new();
        if let Some(e) = stderr.as_mut() {
            let _ = e.read_to_end(&mut s);
        }
        s
    });
    let mut out = Vec::new();
    if let Some(o) = child.stdout.as_mut() {
        let _ = o.read_to_end(&mut out);
    }
    let err = err_thread.join().unwrap_or_default();
    let status = child.wait().ok();
    done.store(true, std::sync::atomic::Ordering::SeqCst);
    Output {
        status: status.and_then(|s| s.code()).unwrap_or(-1),
        out: String::from_utf8_lossy(&out).into_owned(),
        err: String::from_utf8_lossy(&err).into_owned(),
    }
}
