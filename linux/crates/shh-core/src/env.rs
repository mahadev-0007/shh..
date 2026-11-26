pub fn string(key: &str, fallback: &str) -> String {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => fallback.to_string(),
    }
}

/// Most servers have no terminfo entry for anything exotic.
pub fn remote_term() -> String {
    string("SSHM_TERM", "xterm-256color")
}
