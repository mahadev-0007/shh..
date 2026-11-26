//! Builds the single remote-command argv element handed to `ssh -t`.
//! Ported line for line from the Mac app's Shell.swift: the two apps must
//! produce the same string for the same project.
use crate::env;
use crate::meta::{AgentDef, DEFAULT_SHELL};

/// Single-quote for sh. Applied recursively, so a quoted script can be safely
/// embedded inside another quoted script.
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The shell expands a leading ~ before quoting would apply, so splice $HOME in.
pub fn quote_path(path: &str) -> String {
    if path == "~" {
        return "\"$HOME\"".into();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return format!("\"$HOME\"/{}", quote(rest));
    }
    quote(path)
}

pub fn is_safe(s: &str) -> bool {
    !s.contains('\0') && !s.contains('\n') && !s.contains('\r')
}

/// Where tmux lives on the *server* when it isn't on a bare PATH.
pub const TMUX_PATHS: &str = "/opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux";

fn keep_shell(agent: Option<&AgentDef>) -> bool {
    agent.map(|a| a.keep_shell).unwrap_or(true)
}

/// A human-readable version of what a project will run.
pub fn preview(target: &str, path: Option<&str>, agent: Option<&AgentDef>, durable: bool) -> String {
    let mut inner: Vec<String> = Vec::new();
    if let Some(p) = path.filter(|p| !p.is_empty()) {
        inner.push(format!("cd {p}"));
    }
    let command = agent.map(|a| a.command.trim_matches(' ')).unwrap_or("");
    if !command.is_empty() {
        inner.push(command.to_string());
    }
    if keep_shell(agent) {
        inner.push("exec $SHELL -l".into());
    }
    let wrapper = agent.map(|a| a.shell.as_str()).unwrap_or(DEFAULT_SHELL);
    let run = format!("{wrapper} '{}'", inner.join("; "));
    if durable {
        format!("ssh -t {target}\n  tmux new-session -A -s <project> -- {run}")
    } else {
        format!("ssh -t {target}\n  {run}")
    }
}

/// Wrap a command so it runs inside a named tmux session. `new-session -A`
/// attaches if it exists, otherwise creates — which is the whole feature.
pub fn tmux_wrap(inner: &str, name: &str, cwd: Option<&str>) -> String {
    let mut parts: Vec<String> =
        vec!["\"$t\"".into(), "-u".into(), "new-session".into(), "-A".into(), "-s".into(), quote(name)];
    if let Some(c) = cwd.filter(|c| !c.is_empty()) {
        parts.push("-c".into());
        parts.push(quote_path(c));
    }
    parts.push("--".into());
    let after = r"\; set-option -q mouse on";
    let script = format!(
        "t=$(command -v tmux 2>/dev/null); \
         for c in {TMUX_PATHS}; do [ -z \"$t\" ] && [ -x \"$c\" ] && t=$c; done; \
         if [ -n \"$t\" ]; then \
         \"$t\" set-option -g allow-passthrough on >/dev/null 2>&1; \
         exec {} {inner} {after}; fi; \
         exec {inner}",
        parts.join(" ")
    );
    // sh explicitly: the login shell on the far side may not be POSIX
    format!("exec sh -c {}", quote(&script))
}

/// `voice_bin`: when voice input is on, the directory holding the arecord shim,
/// put first on the session's PATH.
pub fn remote_script(
    path: Option<&str>,
    agent: Option<&AgentDef>,
    durable_name: Option<&str>,
    voice_bin: Option<&str>,
) -> Option<String> {
    let mut inner: Vec<String> = Vec::new();

    if let Some(p) = path.filter(|p| !p.is_empty()) {
        if !is_safe(p) {
            return None;
        }
        // a failed cd must not silently run the agent in $HOME
        inner.push(format!("cd -- {} || exit 1", quote_path(p)));
    }

    let command = agent.map(|a| a.command.trim_matches(' ')).unwrap_or("");
    if !command.is_empty() {
        if !is_safe(command) {
            return None;
        }
        if let Some(exe) = command.split(' ').find(|s| !s.is_empty()) {
            if !exe.starts_with('$') && !exe.contains('=') {
                let hint = format!(
                    "{exe} isn't on the PATH of this shell. \
                     Settings > Agents > Shell controls how it's launched \
                     (try adding -i, or give the full path)."
                );
                inner.push(format!(
                    "command -v {} >/dev/null 2>&1 || printf '\\033[33m%s\\033[0m\\n' {}",
                    quote(exe),
                    quote(&hint)
                ));
            }
        }
        // exec so the agent owns the pty directly and signals reach it
        inner.push(if keep_shell(agent) { command.to_string() } else { format!("exec {command}") });
    }

    if keep_shell(agent) {
        inner.push(format!("exec {} -l", env::string("SSHM_REMOTE_SHELL", "${SHELL:-/bin/sh}")));
    }

    if inner.is_empty() {
        return None;
    }
    if let Some(bin) = voice_bin {
        inner.insert(0, format!("PATH=\"{bin}:$PATH\"; export PATH"));
    }
    let script = inner.join("\n");
    let wrapper = agent.map(|a| a.shell.as_str()).unwrap_or(DEFAULT_SHELL);
    if !is_safe(wrapper) {
        return None;
    }
    let run = format!("{wrapper} {}", quote(&script));

    if let Some(name) = durable_name.filter(|n| is_safe(n)) {
        return Some(tmux_wrap(&run, name, path));
    }
    Some(format!("exec {run}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(cmd: &str, keep: bool) -> AgentDef {
        AgentDef {
            id: "x".into(),
            name: "x".into(),
            icon: None,
            command: cmd.into(),
            shell: "${SHELL:-/bin/sh} -lc".into(),
            keep_shell: keep,
            builtin: false,
        }
    }

    #[test]
    fn quoting() {
        assert_eq!(quote("it's"), "'it'\\''s'");
        assert_eq!(quote_path("~"), "\"$HOME\"");
        assert_eq!(quote_path("~/a b"), "\"$HOME\"/'a b'");
        assert_eq!(quote_path("/srv/x"), "'/srv/x'");
    }

    #[test]
    fn plain_script_matches_the_mac_app() {
        let a = agent("claude", true);
        let s = remote_script(Some("~/proj"), Some(&a), None, None).unwrap();
        let inner = "cd -- \"$HOME\"/'proj' || exit 1\n\
            command -v 'claude' >/dev/null 2>&1 || printf '\\033[33m%s\\033[0m\\n' \
            'claude isn'\\''t on the PATH of this shell. Settings > Agents > Shell controls \
            how it'\\''s launched (try adding -i, or give the full path).'\n\
            claude\n\
            exec ${SHELL:-/bin/sh} -l";
        assert_eq!(s, format!("exec ${{SHELL:-/bin/sh}} -lc {}", quote(inner)));
    }

    #[test]
    fn exec_when_not_keeping_a_shell() {
        let a = agent("htop", false);
        let s = remote_script(None, Some(&a), None, None).unwrap();
        assert!(s.contains("\nexec htop'"));
        assert!(!s.contains("-l'"));
    }

    #[test]
    fn unsafe_input_is_refused() {
        let a = agent("a\nb", true);
        assert!(remote_script(None, Some(&a), None, None).is_none());
        assert!(remote_script(Some("x\ny"), None, None, None).is_none());
    }

    #[test]
    fn durable_wraps_in_tmux() {
        let a = agent("claude", true);
        let s = remote_script(Some("/srv/x"), Some(&a), Some("shh-x-1-abcd"), None).unwrap();
        assert!(s.starts_with("exec sh -c '"));
        assert!(s.contains("new-session -A -s"));
        assert!(s.contains("set-option -q mouse on"));
    }

    #[test]
    fn it_actually_runs_under_sh() {
        // The quoting is only right if a real shell agrees.
        let a = agent("echo it\\'s-ok", false);
        let s = remote_script(Some("/"), Some(&a), None, None).unwrap();
        let out = std::process::Command::new("sh")
            .arg("-c")
            .arg(&s)
            .env("SHELL", "/bin/sh")
            .output()
            .unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "it's-ok");
    }
}
