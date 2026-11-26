//! The invite a host sends to one person, written as a shh:// link.
//!
//! ```text
//! shh://join?v=1&a=100.101.102.103&h=bobs-mbp.tail1234.ts.net&u=bob
//!     &p=7022&fp=<host key sha256, base64url>&t=<token>&n=Bob's MacBook
//! ```
//!
//! Byte-compatible with what the Mac app's URLComponents produces.

pub const SCHEME: &str = "shh";
pub const DEFAULT_PORT: u16 = 7022;

#[derive(Debug, Clone, PartialEq)]
pub struct InviteCode {
    pub address: String,
    pub dns_name: String,
    pub user: String,
    pub invite_port: u16,
    /// "SHA256:…" as ssh-keygen prints it
    pub fingerprint: String,
    pub token: String,
    pub host_label: String,
}

impl InviteCode {
    pub fn string(&self) -> String {
        let items = [
            ("v", "1".to_string()),
            ("a", self.address.clone()),
            ("h", self.dns_name.clone()),
            ("u", self.user.clone()),
            ("p", self.invite_port.to_string()),
            ("fp", to_url_safe(&self.fingerprint)),
            ("t", self.token.clone()),
            ("n", self.host_label.clone()),
        ];
        let q: Vec<String> = items.iter().map(|(k, v)| format!("{k}={}", encode(v))).collect();
        format!("{SCHEME}://join?{}", q.join("&"))
    }

    /// Accepts the link as pasted, including the stray whitespace, quotes or
    /// angle brackets chat apps like to wrap around it.
    pub fn parse(raw: &str) -> Option<InviteCode> {
        let trimmed = raw.trim_matches(|c: char| c.is_whitespace() || "<>\"'`".contains(c));
        let rest = strip_prefix_ci(trimmed, "shh://")?;
        let (host, query) = match rest.split_once('?') {
            Some((h, q)) => (h, q),
            None => (rest, ""),
        };
        if host.trim_end_matches('/').to_ascii_lowercase() != "join" {
            return None;
        }
        let query = query.split('#').next().unwrap_or("");
        let mut q = std::collections::HashMap::new();
        for pair in query.split('&').filter(|p| !p.is_empty()) {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            q.insert(decode(k), decode(v));
        }
        let get = |k: &str| q.get(k).cloned().unwrap_or_default();
        let (a, u, t, fp, h) = (get("a"), get("u"), get("t"), get("fp"), get("h"));
        if a.is_empty() || u.is_empty() || t.is_empty() || fp.is_empty() {
            return None;
        }
        if !is_plain(&a) || !is_plain(&u) || !is_plain(&h) {
            return None;
        }
        let n = get("n");
        Some(InviteCode {
            host_label: if n.is_empty() { if h.is_empty() { a.clone() } else { h.clone() } } else { n },
            address: a,
            dns_name: h,
            user: u,
            invite_port: get("p").parse().unwrap_or(DEFAULT_PORT),
            fingerprint: from_url_safe(&fp),
            token: t,
        })
    }
}

fn strip_prefix_ci<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() >= prefix.len() && s.is_char_boundary(prefix.len())
        && s[..prefix.len()].eq_ignore_ascii_case(prefix)
    {
        Some(&s[prefix.len()..])
    } else {
        None
    }
}

/// Hosts and user names end up in servers.conf and on an ssh command line, so
/// anything beyond the characters they really use is refused.
fn is_plain(s: &str) -> bool {
    s.chars().all(|c| c.is_alphanumeric() || "-_.:@".contains(c))
}

// "+" and "/" in a fingerprint get mangled by some chat apps' link parsing
fn to_url_safe(fp: &str) -> String {
    fp.replace("SHA256:", "").replace('+', "-").replace('/', "_")
}
fn from_url_safe(s: &str) -> String {
    format!("SHA256:{}", s.replace('-', "+").replace('_', "/"))
}

/// Percent-encode a query value the way URLComponents does for a URLQueryItem.
fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"-._~!$'()*+,/:;?@".contains(&b);
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 3 <= b.len() {
            let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    // what the Mac app's URLComponents writes for this invite
    const SWIFT: &str = "shh://join?v=1&a=100.101.102.103&h=bobs-mbp.tail1234.ts.net&u=bob&p=7022&fp=AbC-def_123&t=tok_en-1&n=Bob's%20MacBook";

    fn sample() -> InviteCode {
        InviteCode {
            address: "100.101.102.103".into(),
            dns_name: "bobs-mbp.tail1234.ts.net".into(),
            user: "bob".into(),
            invite_port: 7022,
            fingerprint: "SHA256:AbC+def/123".into(),
            token: "tok_en-1".into(),
            host_label: "Bob's MacBook".into(),
        }
    }

    #[test]
    fn matches_the_swift_format() {
        assert_eq!(sample().string(), SWIFT);
        assert_eq!(InviteCode::parse(SWIFT), Some(sample()));
    }

    #[test]
    fn tolerates_wrapping_and_refuses_junk() {
        assert_eq!(InviteCode::parse(&format!("  <{SWIFT}>\n")), Some(sample()));
        assert!(InviteCode::parse("https://join?a=1&u=b&t=c&fp=d").is_none());
        assert!(InviteCode::parse("shh://join?a=1.2.3.4&u=bob;rm&t=c&fp=d").is_none());
        assert!(InviteCode::parse("shh://join?a=1.2.3.4&u=bob&fp=d").is_none());
        let i = InviteCode::parse("shh://join?a=1.2.3.4&u=bob&t=c&fp=d").unwrap();
        assert_eq!(i.invite_port, 7022);
        assert_eq!(i.host_label, "1.2.3.4");
        // a non-ASCII label round-trips
        let mut s = sample();
        s.host_label = "Zoë & co = 100%".into();
        assert_eq!(InviteCode::parse(&s.string()), Some(s));
    }
}
