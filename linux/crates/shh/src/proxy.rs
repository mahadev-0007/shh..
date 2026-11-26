//! `shh --pty-proxy <socket> <session-id> -- <argv…>`
//!
//! VTE 0.76 (Ubuntu 24.04) swallows OSC 9 / OSC 777 without telling anyone, so
//! notifications a remote tool sends itself would be lost. This sits between
//! VTE's pty and ssh: it runs the command on an inner pty, copies bytes both
//! ways untouched, and reports those two sequences to the app over a datagram
//! socket. VTE stays a real terminal on a real pty; if this helper is missing
//! the session simply runs without it.
use std::os::unix::net::UnixDatagram;
use std::sync::atomic::{AtomicBool, Ordering};

static WINCH: AtomicBool = AtomicBool::new(false);

extern "C" fn on_winch(_: libc::c_int) {
    WINCH.store(true, Ordering::Relaxed);
}

/// Finds complete OSC sequences in a byte stream that arrives in arbitrary chunks.
#[derive(Default)]
pub struct OscScanner {
    state: u8, // 0 text, 1 after ESC, 2 inside OSC, 3 inside OSC after ESC
    buf: Vec<u8>,
}

impl OscScanner {
    pub fn feed(&mut self, data: &[u8], mut found: impl FnMut(&[u8])) {
        for &b in data {
            match self.state {
                0 => {
                    if b == 0x1b {
                        self.state = 1;
                    }
                }
                1 => {
                    if b == b']' {
                        self.buf.clear();
                        self.state = 2;
                    } else if b != 0x1b {
                        self.state = 0;
                    }
                }
                2 => match b {
                    0x07 => {
                        found(&self.buf);
                        self.state = 0;
                    }
                    0x1b => self.state = 3,
                    _ => {
                        self.buf.push(b);
                        if self.buf.len() > 4096 {
                            self.state = 0; // not a notification; stop hoarding
                        }
                    }
                },
                _ => {
                    if b == b'\\' {
                        found(&self.buf);
                    }
                    self.state = 0;
                }
            }
        }
    }
}

/// `(title, body)` when an OSC payload is a notification. An empty title means
/// "use the session's name".
pub fn notification(osc: &[u8]) -> Option<(String, String)> {
    let text = std::str::from_utf8(osc).ok()?;
    if let Some(rest) = text.strip_prefix("777;") {
        // OSC 777;notify;title;body
        let parts: Vec<&str> = rest.split(';').collect();
        if parts.len() >= 3 && parts[0] == "notify" {
            return Some((parts[1].to_string(), parts[2..].join(";")));
        }
        return None;
    }
    let rest = text.strip_prefix("9;")?;
    // ConEmu uses 9;4;state;pct for progress — not a message
    if rest.is_empty() || rest.starts_with("4;") {
        return None;
    }
    Some((String::new(), rest.to_string()))
}

unsafe fn write_all(fd: i32, mut data: &[u8]) -> bool {
    while !data.is_empty() {
        let n = libc::write(fd, data.as_ptr() as *const _, data.len());
        if n < 0 {
            let e = *libc::__errno_location();
            if e == libc::EINTR || e == libc::EAGAIN {
                continue;
            }
            return false;
        }
        data = &data[n as usize..];
    }
    true
}

pub fn run(socket: &str, session: &str, argv: &[String]) -> i32 {
    let sock = UnixDatagram::unbound().ok();
    let report = |title: &str, body: &str| {
        if let Some(s) = &sock {
            let _ = s.send_to(format!("{session}\x1f{title}\x1f{body}").as_bytes(), socket);
        }
    };
    let cargs: Vec<std::ffi::CString> =
        argv.iter().filter_map(|a| std::ffi::CString::new(a.as_bytes()).ok()).collect();
    if cargs.is_empty() {
        return 127;
    }
    let mut ptrs: Vec<*const libc::c_char> = cargs.iter().map(|c| c.as_ptr()).collect();
    ptrs.push(std::ptr::null());

    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        libc::ioctl(0, libc::TIOCGWINSZ, &mut ws);
        let (mut master, mut slave) = (0, 0);
        if libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null(), &ws) != 0 {
            // no inner pty: run the command directly on VTE's
            libc::execvp(ptrs[0], ptrs.as_ptr());
            return 127;
        }
        let pid = libc::fork();
        if pid < 0 {
            libc::execvp(ptrs[0], ptrs.as_ptr());
            return 127;
        }
        if pid == 0 {
            libc::close(master);
            libc::setsid();
            libc::ioctl(slave, libc::TIOCSCTTY, 0);
            libc::dup2(slave, 0);
            libc::dup2(slave, 1);
            libc::dup2(slave, 2);
            if slave > 2 {
                libc::close(slave);
            }
            libc::execvp(ptrs[0], ptrs.as_ptr());
            libc::_exit(127);
        }
        libc::close(slave);

        let mut saved: libc::termios = std::mem::zeroed();
        let have_tty = libc::tcgetattr(0, &mut saved) == 0;
        if have_tty {
            let mut raw = saved;
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(0, libc::TCSANOW, &raw);
        }
        libc::signal(libc::SIGWINCH, on_winch as extern "C" fn(libc::c_int) as libc::sighandler_t);

        let mut scanner = OscScanner::default();
        let mut buf = [0u8; 16384];
        let mut stdin_open = true;
        let mut status = 0;
        let mut reaped = false;
        loop {
            // The command can exit while something it left behind (ssh's
            // ControlPersist master) still holds the inner pty open, so EOF
            // alone is not a reliable end. Once it is gone, drain and leave.
            if !reaped && libc::waitpid(pid, &mut status, libc::WNOHANG) == pid {
                reaped = true;
            }
            if WINCH.swap(false, Ordering::Relaxed) {
                let mut w: libc::winsize = std::mem::zeroed();
                if libc::ioctl(0, libc::TIOCGWINSZ, &mut w) == 0 {
                    libc::ioctl(master, libc::TIOCSWINSZ, &w);
                }
            }
            let mut fds = [
                libc::pollfd { fd: if stdin_open { 0 } else { -1 }, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 },
            ];
            let n = libc::poll(fds.as_mut_ptr(), 2, if reaped { 50 } else { 250 });
            if n < 0 {
                if *libc::__errno_location() == libc::EINTR {
                    continue;
                }
                break;
            }
            if reaped && (n == 0 || fds[1].revents & libc::POLLIN == 0) {
                break; // nothing more to show
            }
            if fds[1].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                let r = libc::read(master, buf.as_mut_ptr() as *mut _, buf.len());
                if r <= 0 {
                    break; // the command exited and its pty closed
                }
                let chunk = &buf[..r as usize];
                scanner.feed(chunk, |osc| {
                    if let Some((title, body)) = notification(osc) {
                        report(&title, &body);
                    }
                });
                if !write_all(1, chunk) {
                    break;
                }
            }
            if stdin_open && fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                let r = libc::read(0, buf.as_mut_ptr() as *mut _, buf.len());
                if r <= 0 {
                    // the terminal went away: hang up the command, as a closed window would
                    stdin_open = false;
                    libc::kill(pid, libc::SIGHUP);
                } else if !write_all(master, &buf[..r as usize]) {
                    break;
                }
            }
        }
        libc::close(master);
        while !reaped {
            let r = libc::waitpid(pid, &mut status, 0);
            if r == pid || (r < 0 && *libc::__errno_location() != libc::EINTR) {
                reaped = true;
            }
        }
        if have_tty {
            libc::tcsetattr(0, libc::TCSANOW, &saved);
        }
        if libc::WIFSIGNALED(status) {
            // die the same way, so the app's reconnect logic sees what ssh saw
            let sig = libc::WTERMSIG(status);
            libc::signal(sig, libc::SIG_DFL);
            libc::kill(libc::getpid(), sig);
            return 128 + sig;
        }
        libc::WEXITSTATUS(status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(chunks: &[&[u8]]) -> Vec<(String, String)> {
        let mut s = OscScanner::default();
        let mut out = Vec::new();
        for c in chunks {
            s.feed(c, |osc| {
                if let Some(n) = notification(osc) {
                    out.push(n);
                }
            });
        }
        out
    }

    #[test]
    fn osc_777_and_9() {
        let got = scan(&[b"hi \x1b]777;notify;Build;done; really\x07 and \x1b]9;Finished\x1b\\"]);
        assert_eq!(
            got,
            vec![("Build".into(), "done; really".into()), ("".into(), "Finished".into())]
        );
    }

    #[test]
    fn split_across_reads() {
        let got = scan(&[b"\x1b", b"]9;hel", b"lo", b"\x07"]);
        assert_eq!(got, vec![("".into(), "hello".into())]);
    }

    #[test]
    fn progress_and_titles_are_not_notifications() {
        assert!(scan(&[b"\x1b]9;4;1;50\x07\x1b]0;window title\x07\x1b]777;precmd\x07"]).is_empty());
    }

    #[test]
    fn runaway_osc_is_dropped() {
        let mut big = b"\x1b]9;".to_vec();
        big.extend(std::iter::repeat(b'x').take(10_000));
        big.extend(b"\x07\x1b]9;ok\x07");
        assert_eq!(scan(&[&big]), vec![("".into(), "ok".into())]);
    }
}
