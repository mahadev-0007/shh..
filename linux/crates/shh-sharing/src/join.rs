//! The guest's half: turn an invite link into a working server entry.
use crate::invite::InviteCode;
use crate::{http, keys, sys};
use shh_core::server::Server;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    Refused(String),
    HostKeyMismatch,
    Keygen,
    Network(http::ClientError),
    Save(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::Refused(s) | Failure::Save(s) => write!(f, "{s}"),
            Failure::HostKeyMismatch => write!(
                f,
                "The machine that answered isn't the one that made this invite (its host key \
                 doesn't match). Nothing was saved."
            ),
            Failure::Keygen => write!(f, "Couldn't create an ssh key for this connection."),
            Failure::Network(e) => write!(f, "{e}"),
        }
    }
}

/// What a successful join produced: the saved server, and the name the host
/// goes by (for the display name; the server's `name` is only a slug).
pub struct Joined {
    pub server: Server,
    pub label: String,
}

/// Make a key, redeem the invite, trust the host key, save the server.
/// Blocks for as long as the host takes to click Allow (up to three minutes).
pub fn redeem(invite: &InviteCode) -> Result<Joined, Failure> {
    let first = if invite.dns_name.is_empty() {
        invite.address.as_str()
    } else {
        invite.dns_name.split('.').next().unwrap_or(&invite.address)
    };
    let key_name = format!("shh-{}", shh_core::slug::unique(first, &Default::default(), None));
    let (key_path, public_key) = keys::generate_guest_key(&key_name).map_err(|_| Failure::Keygen)?;
    let discard = || {
        let _ = std::fs::remove_file(&key_path);
        let _ = std::fs::remove_file(format!("{key_path}.pub"));
    };

    let body = serde_json::json!({
        "token": invite.token,
        "publicKey": public_key,
        "name": sys::host_label(),
    });
    // generous: the host has to notice the prompt and click Allow
    let reply = http::post(&invite.address, invite.invite_port, "/shh/join", &body,
                           Duration::from_secs(180));
    let result = match reply {
        Err(e) => Err(Failure::Network(e)),
        Ok((200, json)) => save(invite, &json, &key_path),
        Ok((status, json)) => Err(Failure::Refused(
            json["error"]
                .as_str()
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("The other machine refused ({status}).")),
        )),
    };
    if result.is_err() {
        discard();
    }
    result
}

/// The host keys in a reply that the invite vouches for; None if none match.
pub fn trusted_keys(invite: &InviteCode, reply: &serde_json::Value) -> Option<Vec<String>> {
    // The invite came over a channel the user trusts; the reply came over the
    // network. Only accept host keys the invite vouches for.
    let keys: Vec<String> = reply["hostKeys"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).filter_map(keys::normalize_public_key).collect())
        .unwrap_or_default();
    if keys.iter().any(|k| keys::fingerprint(k).as_deref() == Some(invite.fingerprint.as_str())) {
        Some(keys)
    } else {
        None
    }
}

fn save(invite: &InviteCode, reply: &serde_json::Value, key_path: &str) -> Result<Joined, Failure> {
    let keys = trusted_keys(invite, reply).ok_or(Failure::HostKeyMismatch)?;
    let host = if invite.dns_name.is_empty() { invite.address.clone() } else { invite.dns_name.clone() };
    let mut names = vec![host.clone()];
    if invite.address != host {
        names.push(invite.address.clone());
    }
    keys::add_known_hosts(&names, &keys).map_err(|e| Failure::Save(e.to_string()))?;

    let user = reply["user"]
        .as_str()
        .filter(|u| !u.is_empty() && shh_core::shell::is_safe(u) && !u.contains('|'))
        .unwrap_or(&invite.user)
        .to_string();
    let port = reply["sshPort"].as_i64().map(|p| p.to_string()).unwrap_or_else(|| "22".into());
    let server = Server {
        name: shh_core::slug::unique(&invite.host_label, &shh_core::server::slugs(), None),
        host,
        user,
        port,
        auth: "key".into(),
        secret: key_path.to_string(),
    };
    shh_core::server::add(server.clone());
    Ok(Joined { server, label: invite.host_label.clone() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_keys_the_invite_vouches_for() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
        let mut invite = InviteCode {
            address: "100.64.0.1".into(),
            dns_name: String::new(),
            user: "bob".into(),
            invite_port: 7022,
            fingerprint: keys::fingerprint(key).unwrap(),
            token: "t".into(),
            host_label: "Bob".into(),
        };
        let reply = serde_json::json!({ "hostKeys": [format!("{key} root@box"), "garbage"] });
        assert_eq!(trusted_keys(&invite, &reply), Some(vec![key.to_string()]));
        invite.fingerprint = "SHA256:somethingelse".into();
        assert_eq!(trusted_keys(&invite, &reply), None);
    }
}
