//! Lends this computer's microphone to Claude Code running on the server.
//!
//! Claude Code's voice mode records on the machine it runs on. On Linux, with
//! no sound card, it falls back to spawning `arecord -f S16_LE -r 16000 -c 1
//! -t raw -` and reading raw PCM from its stdout. So the bridge is:
//!
//!   server: ~/.local/share/shh/bin/arecord (a shim, first on the session's
//!           PATH) → 127.0.0.1:<remote port> on the server
//!   ssh:    a remote forward on the session's control master
//!   here:   this listener on 127.0.0.1 → pw-record / parec → 16 kHz mono s16le
//!
//! The mic is only open while a shim is connected in `record` mode, i.e. while
//! you are holding the voice key. The forwarded port is reachable by anyone on
//! the server's loopback, so every connection must present a per-launch token
//! kept in a 0700 directory in the user's home.
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

/// Where the shim lives on the server. Sessions put it first on PATH.
pub const REMOTE_BIN: &str = "$HOME/.local/share/shh/bin";

fn token() -> &'static str {
    static T: OnceLock<String> = OnceLock::new();
    T.get_or_init(|| {
        use rand::RngCore;
        let mut b = [0u8; 24];
        rand::rngs::OsRng.fill_bytes(&mut b);
        b.iter().map(|x| format!("{x:02x}")).collect()
    })
}

/// The local port, once the listener is up.
fn ensure_listening() -> Option<u16> {
    static PORT: OnceLock<Option<u16>> = OnceLock::new();
    *PORT.get_or_init(|| {
        let l = match TcpListener::bind(("127.0.0.1", 0)) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("shh voice: could not create listener: {e}");
                return None;
            }
        };
        let port = l.local_addr().ok()?.port();
        std::thread::spawn(move || {
            for c in l.incoming().flatten() {
                std::thread::spawn(move || accept(c));
            }
        });
        Some(port)
    })
}

fn same(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    x.len() == y.len() && x.iter().zip(y).fold(0u8, |acc, (p, q)| acc | (p ^ q)) == 0
}

/// What a connection's first line asks for, if it is allowed to ask.
#[derive(Debug, PartialEq)]
pub enum Ask {
    Probe,
    Record,
}

/// `SHH-VOICE <token> <probe|record>`, and nothing else is accepted.
pub fn parse_header(line: &str, token: &str) -> Option<Ask> {
    let parts: Vec<&str> = line.split(' ').filter(|p| !p.is_empty()).collect();
    if parts.len() != 3 || parts[0] != "SHH-VOICE" || !same(parts[1], token) {
        return None;
    }
    match parts[2] {
        "probe" => Some(Ask::Probe),
        "record" => Some(Ask::Record),
        _ => None,
    }
}

fn accept(mut c: TcpStream) {
    let _ = c.set_read_timeout(Some(Duration::from_secs(10)));
    let mut buf = Vec::new();
    let mut one = [0u8; 1];
    loop {
        match c.read(&mut one) {
            Ok(1) if one[0] == b'\n' => break,
            Ok(1) => buf.push(one[0]),
            _ => return,
        }
        if buf.len() > 256 {
            return;
        }
    }
    let _ = c.set_read_timeout(None);
    match parse_header(&String::from_utf8_lossy(&buf), token()) {
        Some(Ask::Probe) => {
            let _ = c.write_all(b"OK\n");
        }
        Some(Ask::Record) => record(c),
        None => {}
    }
}

// ---- recording -------------------------------------------------------------

/// The capture command: 16 kHz mono signed 16-bit little-endian on stdout.
pub fn recorder() -> Option<(String, Vec<&'static str>)> {
    if let Some(p) = shh_core::tools::which("pw-record") {
        return Some((p, vec!["--rate", "16000", "--channels", "1", "--format", "s16", "-"]));
    }
    if let Some(p) = shh_core::tools::which("parec") {
        return Some((p, vec!["--rate=16000", "--channels=1", "--format=s16le", "--raw"]));
    }
    if let Some(p) = shh_core::tools::which("arecord") {
        return Some((p, vec!["-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", "-"]));
    }
    None
}

type Talker = Arc<Mutex<Child>>;
static RECORDING: Mutex<Option<Talker>> = Mutex::new(None);

fn kill(t: &Talker) {
    let mut c = t.lock().unwrap_or_else(|e| e.into_inner());
    let _ = c.kill();
    let _ = c.wait();
}

fn record(mut c: TcpStream) {
    let Some((program, args)) = recorder() else {
        eprintln!("shh voice: no pw-record, parec or arecord to record with");
        return;
    };
    let mut child = match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(ch) => ch,
        Err(e) => {
            eprintln!("shh voice: could not start the microphone: {e}");
            return;
        }
    };
    let Some(mut audio) = child.stdout.take() else { return };
    let talker: Talker = Arc::new(Mutex::new(child));
    // one talker at a time; the newest press wins
    let previous = RECORDING.lock().unwrap_or_else(|e| e.into_inner()).replace(talker.clone());
    if let Some(p) = previous {
        kill(&p);
    }

    // The shim never writes after its header, so the stream ending means
    // Claude stopped recording and killed it.
    if let Ok(mut watch) = c.try_clone() {
        let t = talker.clone();
        std::thread::spawn(move || {
            let mut b = [0u8; 1024];
            loop {
                match watch.read(&mut b) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
            kill(&t);
        });
    }

    let mut buf = [0u8; 4096];
    loop {
        match audio.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if c.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        }
    }
    kill(&talker);
    let _ = c.shutdown(std::net::Shutdown::Both);
    let mut cur = RECORDING.lock().unwrap_or_else(|e| e.into_inner());
    if cur.as_ref().map_or(false, |t| Arc::ptr_eq(t, &talker)) {
        *cur = None;
    }
}

// ---- per-session setup -----------------------------------------------------

/// Control masters that already carry a forward to us, by control path, so a
/// shared connection with five tabs on it gets one forward, not five.
static FORWARDED: Mutex<Option<HashMap<String, (String, String)>>> = Mutex::new(None);

fn ssh(args: &[&str], input: Option<&[u8]>) -> crate::sys::Output {
    crate::sys::run(&shh_core::tools::ssh(), args, input, None)
}

/// "pid" out of `Master running (pid=12345)`.
pub fn parse_master_pid(text: &str) -> String {
    text.split_once("pid=")
        .and_then(|(_, rest)| rest.split_once(')'))
        .map(|(pid, _)| pid.to_string())
        .unwrap_or_else(|| "?".into())
}

/// The control master's pid, or None if it isn't up yet.
fn master_pid(ctl: &str, target: &str) -> Option<String> {
    let r = ssh(&["-o", &format!("ControlPath={ctl}"), "-O", "check", target], None);
    if r.status != 0 {
        return None;
    }
    Some(parse_master_pid(&format!("{}{}", r.err, r.out)))
}

/// The remote command that installs the shim (read from stdin) and says where
/// to connect.
pub fn install_script(remote_port: &str, token: &str) -> String {
    format!(
        "umask 077; d=\"$HOME/.cache/shh-voice\"; b=\"{REMOTE_BIN}\"; \
         mkdir -p \"$d\" \"$b\" && cat > \"$b/.arecord.$$\" \
         && chmod 755 \"$b/.arecord.$$\" && mv -f \"$b/.arecord.$$\" \"$b/arecord\" \
         && printf '%s\\n' {remote_port} > \"$d/port\" \
         && printf '%s\\n' {token} > \"$d/token\""
    )
}

/// Wire a freshly launched session to the bridge: wait for its control master
/// (a password may still be being typed), add the remote forward, and install
/// the shim plus where-to-connect on the server. Returns at once.
pub fn attach(control_path: String, target: String, port: String) {
    std::thread::spawn(move || {
        let Some(local) = ensure_listening() else { return };
        let ctl = control_path;
        // up to two minutes to finish logging in
        let mut pid = None;
        for _ in 0..120 {
            if let Some(p) = master_pid(&ctl, &target) {
                pid = Some(p);
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        let Some(pid) = pid else { return };

        let known = {
            let f = FORWARDED.lock().unwrap_or_else(|e| e.into_inner());
            f.as_ref()
                .and_then(|m| m.get(&ctl))
                .filter(|(p, _)| *p == pid)
                .map(|(_, remote)| remote.clone())
        };
        let remote = match known {
            Some(r) => r,
            None => {
                let r = ssh(
                    &["-o", &format!("ControlPath={ctl}"), "-O", "forward",
                      "-R", &format!("127.0.0.1:0:127.0.0.1:{local}"), &target],
                    None,
                );
                let remote = r.out.trim().to_string();
                if r.status != 0 || remote.is_empty() || !remote.chars().all(|c| c.is_ascii_digit()) {
                    eprintln!("shh voice: remote forward refused ({}): {}", r.status, r.err.trim());
                    return;
                }
                FORWARDED
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get_or_insert_with(HashMap::new)
                    .insert(ctl.clone(), (pid, remote.clone()));
                remote
            }
        };

        let install = install_script(&remote, token());
        let r = ssh(
            &["-o", &format!("ControlPath={ctl}"), "-o", "ControlMaster=no", "-p", &port, &target,
              &format!("sh -c {}", shh_core::shell::quote(&install))],
            Some(SHIM.as_bytes()),
        );
        if r.status != 0 {
            eprintln!("shh voice: could not install the shim: {}", r.err.trim());
        }
    });
}

// ---- the server side -------------------------------------------------------

/// Stands in for `arecord`. Claude Code calls it three ways: `--version` to see
/// it exists, `… /dev/null` as a quick probe, and `… -` to record raw PCM to
/// stdout until it sends SIGTERM. The record path ends in `exec cat`, so that
/// SIGTERM closes the socket and the mic here goes off with it. When shh isn't
/// reachable it hands over to the real arecord, if any.
///
/// Identical to the Mac app's shim, byte for byte.
pub const SHIM: &str = r##"#!/bin/sh
# shh voice bridge: lets Claude Code's voice mode hear the Mac's microphone
# over the SSH connection. Installed and refreshed by shh.
self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
real() {
  old_ifs=$IFS; IFS=:
  for d in $PATH; do
    [ "$d" = "$self_dir" ] && continue
    if [ -x "$d/arecord" ]; then IFS=$old_ifs; exec "$d/arecord" "$@"; fi
  done
  IFS=$old_ifs
  echo "arecord: no microphone here and shh's voice bridge is not connected" >&2
  exit 1
}
case "$1" in --version|-V) echo "arecord: shh voice bridge"; exit 0 ;; esac
dir="$HOME/.cache/shh-voice"
port=$(cat "$dir/port" 2>/dev/null); token=$(cat "$dir/token" 2>/dev/null)
case "$port" in ''|*[!0-9]*) real "$@" ;; esac
[ -n "$token" ] || real "$@"
command -v bash >/dev/null 2>&1 || real "$@"
last=; for a in "$@"; do last=$a; done
bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 3
  printf "SHH-VOICE %s probe\n" "$2" >&3
  IFS= read -r -t 3 r <&3; [ "$r" = OK ]' sh "$port" "$token" 2>/dev/null || real "$@"
[ "$last" = /dev/null ] && exit 0
exec bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
  printf "SHH-VOICE %s record\n" "$2" >&3
  exec cat <&3' sh "$port" "$token"
"##;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_needs_the_token() {
        assert_eq!(parse_header("SHH-VOICE abc probe", "abc"), Some(Ask::Probe));
        assert_eq!(parse_header("SHH-VOICE abc record", "abc"), Some(Ask::Record));
        assert_eq!(parse_header("SHH-VOICE abd record", "abc"), None);
        assert_eq!(parse_header("SHH-VOICE abc play", "abc"), None);
        assert_eq!(parse_header("GET / HTTP/1.1", "abc"), None);
    }

    #[test]
    fn master_pid_and_install() {
        assert_eq!(parse_master_pid("Master running (pid=12345)\r\n"), "12345");
        assert_eq!(parse_master_pid("Master running"), "?");
        let s = install_script("40123", "tok");
        assert!(s.contains("b=\"$HOME/.local/share/shh/bin\""));
        assert!(s.contains("printf '%s\\n' 40123 > \"$d/port\""));
        assert!(SHIM.starts_with("#!/bin/sh\n") && SHIM.ends_with("sh \"$port\" \"$token\"\n"));
    }

    #[test]
    fn probe_over_loopback() {
        let port = ensure_listening().unwrap();
        let mut c = TcpStream::connect(("127.0.0.1", port)).unwrap();
        c.write_all(format!("SHH-VOICE {} probe\n", token()).as_bytes()).unwrap();
        let mut s = String::new();
        c.read_to_string(&mut s).unwrap();
        assert_eq!(s, "OK\n");
        let mut c = TcpStream::connect(("127.0.0.1", port)).unwrap();
        c.write_all(b"SHH-VOICE nope probe\n").unwrap();
        let mut s = String::new();
        c.read_to_string(&mut s).unwrap();
        assert_eq!(s, "");
    }
}
