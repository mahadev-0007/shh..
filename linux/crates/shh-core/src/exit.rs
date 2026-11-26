/// How a session's child process ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitStatus {
    Code(i32),
    Signal(i32),
}

impl ExitStatus {
    /// From a raw `waitpid` status word, which is what VTE's child-exited gives.
    pub fn from_raw(raw: i32) -> Self {
        let term = raw & 0x7f;
        if term == 0 {
            ExitStatus::Code((raw >> 8) & 0xff)
        } else if term == 0x7f {
            ExitStatus::Code(0)
        } else {
            ExitStatus::Signal(term)
        }
    }

    pub fn is_clean(self) -> bool {
        self == ExitStatus::Code(0)
    }

    pub fn detail(self) -> Option<String> {
        Some(match self {
            ExitStatus::Code(0) => return None,
            ExitStatus::Code(5) => "sshpass: wrong password".into(),
            ExitStatus::Code(6) => {
                "host key not accepted — connect once by hand to trust it".into()
            }
            ExitStatus::Code(255) => "ssh lost the connection or could not reach the host".into(),
            ExitStatus::Code(127) => "command not found on the server".into(),
            ExitStatus::Code(c) => format!("exit {c}"),
            ExitStatus::Signal(s) => format!("killed by signal {s}"),
        })
    }

    pub fn label(self) -> String {
        match self {
            ExitStatus::Code(c) => format!("exit {c}"),
            ExitStatus::Signal(s) => format!("signal {s}"),
        }
    }

    /// Only transport failures are worth retrying.
    pub fn should_reconnect(self) -> bool {
        matches!(self, ExitStatus::Code(255) | ExitStatus::Signal(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raw() {
        assert_eq!(ExitStatus::from_raw(0), ExitStatus::Code(0));
        assert_eq!(ExitStatus::from_raw(255 << 8), ExitStatus::Code(255));
        assert_eq!(ExitStatus::from_raw(9), ExitStatus::Signal(9));
        assert!(ExitStatus::from_raw(255 << 8).should_reconnect());
        assert!(!ExitStatus::from_raw(5 << 8).should_reconnect());
    }
}
