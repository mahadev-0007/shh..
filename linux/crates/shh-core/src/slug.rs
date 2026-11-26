use std::collections::HashSet;

/// "SaaS Server" → "saas-server". The slug is the key in servers.conf.
pub fn make(s: &str) -> String {
    let mut out = String::new();
    let mut last_dash = true;
    for ch in s.to_lowercase().chars() {
        if ch.is_alphanumeric() {
            out.push(ch);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        "server".into()
    } else {
        out
    }
}

pub fn unique(s: &str, taken: &HashSet<String>, keep: Option<&str>) -> String {
    let base = make(s);
    if Some(base.as_str()) == keep || !taken.contains(&base) {
        return base;
    }
    let mut i = 2;
    while taken.contains(&format!("{base}-{i}")) {
        i += 1;
    }
    format!("{base}-{i}")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn slugs() {
        assert_eq!(make("SaaS Server"), "saas-server");
        assert_eq!(make("  --a  b__c!! "), "a-b-c");
        assert_eq!(make("!!!"), "server");
        let taken: HashSet<String> = ["db".to_string(), "db-2".to_string()].into();
        assert_eq!(unique("DB", &taken, None), "db-3");
        assert_eq!(unique("DB", &taken, Some("db")), "db");
    }
}
