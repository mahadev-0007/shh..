//! The few things shh asks of the Tailscale CLI: who this machine is on the
//! tailnet, and who is behind a given tailnet address. Everything blocks.
use serde_json::Value;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    NotInstalled,
    NotRunning(String),
    Failed(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::NotInstalled => {
                write!(f, "Tailscale isn't installed. Get it from tailscale.com/download.")
            }
            Failure::NotRunning(state) if state == "NeedsLogin" => {
                write!(f, "Tailscale is installed but not signed in.")
            }
            Failure::NotRunning(state) => write!(f, "Tailscale isn't connected ({state})."),
            Failure::Failed(s) => write!(f, "{s}"),
        }
    }
}

/// This machine on the tailnet.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SelfNode {
    pub host_name: String,
    /// MagicDNS name without the trailing dot.
    pub dns_name: String,
    pub ipv4: String,
}

/// The person and device behind a tailnet address, as Tailscale vouches.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Peer {
    pub login: String,
    pub display_name: String,
    pub node: String,
    pub addresses: Vec<String>,
}

pub fn cli() -> Option<String> {
    shh_core::tools::which("tailscale")
}

pub fn self_node() -> Result<SelfNode, Failure> {
    parse_status(&run_json(&["status", "--json", "--peers=false"])?)
}

pub fn parse_status(json: &Value) -> Result<SelfNode, Failure> {
    let state = json["BackendState"].as_str().unwrap_or("Unknown");
    if state != "Running" {
        return Err(Failure::NotRunning(state.to_string()));
    }
    let me = &json["Self"];
    let v4 = me["TailscaleIPs"]
        .as_array()
        .and_then(|ips| ips.iter().filter_map(|v| v.as_str()).find(|s| !s.contains(':')))
        .ok_or_else(|| {
            Failure::Failed("Tailscale didn't report an address for this machine.".into())
        })?;
    Ok(SelfNode {
        host_name: me["HostName"].as_str().unwrap_or("").to_string(),
        dns_name: me["DNSName"].as_str().unwrap_or("").trim_matches('.').to_string(),
        ipv4: v4.to_string(),
    })
}

pub fn whois(ip: &str) -> Result<Peer, Failure> {
    parse_whois(&run_json(&["whois", "--json", ip])?, ip)
}

pub fn parse_whois(json: &Value, ip: &str) -> Result<Peer, Failure> {
    let unknown = || Failure::Failed(format!("Tailscale doesn't know who {ip} is."));
    let node = json.get("Node").filter(|v| v.is_object()).ok_or_else(unknown)?;
    let user = json.get("UserProfile").filter(|v| v.is_object()).ok_or_else(unknown)?;
    let login = user["LoginName"].as_str().filter(|s| !s.is_empty()).ok_or_else(unknown)?;
    let addrs: Vec<String> = node["Addresses"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .map(|s| s.split('/').next().unwrap_or(s).to_string())
                .collect()
        })
        .unwrap_or_default();
    let name = match node["ComputedName"].as_str() {
        Some(n) => n.to_string(),
        None => node["Name"].as_str().unwrap_or("").split('.').next().unwrap_or("").to_string(),
    };
    Ok(Peer {
        login: login.to_string(),
        display_name: user["DisplayName"].as_str().unwrap_or(login).to_string(),
        node: name,
        addresses: if addrs.is_empty() { vec![ip.to_string()] } else { addrs },
    })
}

fn run_json(args: &[&str]) -> Result<Value, Failure> {
    let cli = cli().ok_or(Failure::NotInstalled)?;
    // a wedged daemon must not wedge the caller
    let r = crate::sys::run(&cli, args, None, Some(Duration::from_secs(8)));
    if r.status != 0 {
        let msg = r.err.trim().to_string();
        if msg.contains("doesn't appear to be running") || msg.contains("failed to connect") {
            return Err(Failure::NotRunning("Stopped".into()));
        }
        return Err(Failure::Failed(if msg.is_empty() {
            format!("tailscale {} failed.", args[0])
        } else {
            msg
        }));
    }
    match serde_json::from_str::<Value>(&r.out) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err(Failure::Failed(format!("Unexpected output from tailscale {}.", args[0]))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_and_whois() {
        let s: Value = serde_json::from_str(
            r#"{"BackendState":"Running","Self":{"HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["fd7a:115c:a1e0::1","100.101.102.103"]}}"#,
        )
        .unwrap();
        let n = parse_status(&s).unwrap();
        assert_eq!(n.ipv4, "100.101.102.103");
        assert_eq!(n.dns_name, "box.tail1.ts.net");

        let s: Value = serde_json::from_str(r#"{"BackendState":"NeedsLogin"}"#).unwrap();
        assert_eq!(parse_status(&s), Err(Failure::NotRunning("NeedsLogin".into())));

        let w: Value = serde_json::from_str(
            r#"{"Node":{"Name":"amy-mbp.tail1.ts.net.","Addresses":["100.64.0.9/32","fd7a:115c:a1e0::9/128"]},"UserProfile":{"LoginName":"amy@example.com","DisplayName":"Amy"}}"#,
        )
        .unwrap();
        let p = parse_whois(&w, "100.64.0.9").unwrap();
        assert_eq!(p.node, "amy-mbp");
        assert_eq!(p.addresses, vec!["100.64.0.9", "fd7a:115c:a1e0::9"]);
        assert_eq!(p.display_name, "Amy");
    }
}
