//! "Allow remote sessions": letting one specific person ssh into this machine
//! over Tailscale with an invite you send them.
//!
//! The host makes an invite, which carries a one-time token. The guest's shh
//! redeems it by POSTing the token and a fresh public key to a tiny listener
//! bound only to this machine's tailnet address. Tailscale itself says who is
//! calling (`tailscale whois`), the host clicks Allow, and the key goes into
//! authorized_keys locked to the guest's tailnet addresses. From then on it is
//! plain ssh to sshd. Turning it off removes every key it added.
use crate::http::{self, Delivered, Request, Response};
use crate::invite::{InviteCode, DEFAULT_PORT};
use crate::tailscale::{self, Peer, SelfNode};
use crate::{keys, sys};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

pub const INVITE_LIFETIME: f64 = 15.0 * 60.0;

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Invite {
    pub id: String,
    pub label: String,
    pub token_hash: String,
    pub created: f64,
    pub expires: f64,
}

impl Invite {
    pub fn is_expired(&self) -> bool {
        sys::now() > self.expires
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Guest {
    pub id: String,
    pub label: String,
    pub login: String,
    pub display_name: String,
    pub node: String,
    pub addresses: Vec<String>,
    pub key_fingerprint: String,
    pub invite_hash: String,
    pub added: f64,
}

/// sharing.json, exactly as the Mac app writes it.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
#[serde(default)]
pub struct File {
    pub enabled: bool,
    pub invites: Vec<Invite>,
    pub guests: Vec<Guest>,
}

#[derive(Clone, PartialEq, Debug)]
pub enum Status {
    Off,
    Starting,
    Listening(SelfNode),
    Problem(String),
}

/// Everything the page shows, copied out under one lock.
#[derive(Clone, PartialEq, Debug)]
pub struct Snapshot {
    pub file: File,
    pub status: Status,
    /// None until checked.
    pub sshd_on: Option<bool>,
    pub sshd_installed: bool,
    pub host_key_ready: bool,
    pub tailscale_installed: bool,
}

impl Snapshot {
    /// Nothing left for the host to set up: invites can be made and used.
    pub fn is_ready(&self) -> bool {
        matches!(self.status, Status::Listening(_)) && self.sshd_on == Some(true) && self.host_key_ready
    }
}

struct State {
    file: File,
    status: Status,
    sshd_on: Option<bool>,
    host_key_ready: bool,
    server: Option<http::Server>,
    failures: HashMap<String, (u32, Instant)>,
    /// bumped on every start/stop so a slow start can tell it was superseded
    epoch: u64,
    failed_at: Option<Instant>,
    loaded: bool,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();
static GENERATION: AtomicU64 = AtomicU64::new(0);
static MAINTAINER: AtomicBool = AtomicBool::new(false);

fn lock() -> MutexGuard<'static, State> {
    let m = STATE.get_or_init(|| {
        Mutex::new(State {
            file: File::default(),
            status: Status::Off,
            sshd_on: None,
            host_key_ready: false,
            server: None,
            failures: HashMap::new(),
            epoch: 0,
            failed_at: None,
            loaded: false,
        })
    });
    let mut s = m.lock().unwrap_or_else(|e| e.into_inner());
    if !s.loaded {
        s.loaded = true;
        shh_core::paths::ensure_dir();
        if let Ok(d) = std::fs::read(store_path()) {
            if let Ok(f) = serde_json::from_slice::<File>(&d) {
                s.file = f;
            }
        }
        reconcile(&mut s);
    }
    s
}

fn store_path() -> std::path::PathBuf {
    shh_core::paths::config_dir().join("sharing.json")
}

/// Changes whenever anything a page shows may have changed.
pub fn generation() -> u64 {
    GENERATION.load(Ordering::SeqCst)
}
fn changed() {
    GENERATION.fetch_add(1, Ordering::SeqCst);
}

fn mutate(s: &mut State, body: impl FnOnce(&mut File)) {
    let mut f = s.file.clone();
    body(&mut f);
    if f == s.file {
        return;
    }
    s.file = f;
    if let Ok(d) = serde_json::to_vec(&s.file) {
        let _ = shh_core::fsutil::write_atomic(&store_path(), &d, 0o600);
    }
    changed();
}

pub fn snapshot() -> Snapshot {
    let s = lock();
    Snapshot {
        file: s.file.clone(),
        status: s.status.clone(),
        sshd_on: s.sshd_on,
        sshd_installed: sshd_installed(),
        host_key_ready: s.host_key_ready,
        tailscale_installed: tailscale::cli().is_some(),
    }
}

pub fn port() -> u16 {
    shh_core::env::string("SSHM_SHARE_PORT", "").parse().unwrap_or(DEFAULT_PORT)
}

/// Bind somewhere other than the tailnet address and skip whois — only for
/// exercising this code on a machine without Tailscale.
fn test_bind() -> Option<String> {
    let v = shh_core::env::string("SSHM_SHARE_TEST_BIND", "");
    if v.is_empty() { None } else { Some(v) }
}

// ---- lifecycle -------------------------------------------------------------

/// Called at launch: pick up where we left off.
pub fn resume() {
    let enabled = lock().file.enabled;
    if enabled {
        start();
    }
    check_sshd();
    if !MAINTAINER.swap(true, Ordering::SeqCst) {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_secs(10));
            let retry = {
                let mut s = lock();
                drop_expired(&mut s);
                // stay enabled and keep trying: Tailscale may simply not be up yet
                s.file.enabled
                    && matches!(s.status, Status::Problem(_))
                    && s.failed_at.map_or(true, |t| t.elapsed() >= Duration::from_secs(20))
            };
            if retry {
                start();
            }
        });
    }
}

pub fn set_enabled(on: bool) {
    if on {
        mutate(&mut lock(), |f| f.enabled = true);
        start();
    } else {
        revoke_all();
        mutate(&mut lock(), |f| {
            f.enabled = false;
            f.invites.clear();
        });
        stop();
    }
    check_sshd();
}

fn start() {
    let epoch = {
        let mut s = lock();
        if let Some(srv) = s.server.take() {
            srv.stop();
        }
        s.epoch += 1;
        s.status = Status::Starting;
        s.failed_at = None;
        s.epoch
    };
    changed();
    std::thread::spawn(move || {
        let node = match test_bind() {
            Some(bind) => Ok(SelfNode { host_name: "test".into(), dns_name: String::new(), ipv4: bind }),
            None => tailscale::self_node().map_err(|e| e.to_string()),
        };
        let mut s = lock();
        if s.epoch != epoch || !s.file.enabled {
            return;
        }
        let port = port();
        let result = node.and_then(|me| {
            http::Server::start(&me.ipv4, port, Arc::new(handle))
                .map(|srv| (me.clone(), srv))
                .map_err(|e| format!("Couldn't listen on {}:{} — {}", me.ipv4, port, e))
        });
        match result {
            Ok((me, srv)) => {
                s.server = Some(srv);
                s.status = Status::Listening(me);
            }
            Err(message) => {
                s.status = Status::Problem(message);
                s.failed_at = Some(Instant::now());
            }
        }
        drop(s);
        changed();
    });
}

fn stop() {
    let mut s = lock();
    s.epoch += 1;
    if let Some(srv) = s.server.take() {
        srv.stop();
    }
    s.status = Status::Off;
    s.failed_at = None;
    drop(s);
    changed();
}

/// Look again at everything the setup steps report.
pub fn recheck() {
    check_sshd();
    let again = {
        let s = lock();
        s.file.enabled && matches!(s.status, Status::Problem(_))
    };
    if again {
        start();
    }
}

// ---- sshd ("Remote Login") -------------------------------------------------

pub fn sshd_installed() -> bool {
    std::path::Path::new("/usr/sbin/sshd").exists()
}

fn systemd_active(unit: &str) -> bool {
    shh_core::tools::which("systemctl")
        .map(|sc| sys::run(&sc, &["is-active", "--quiet", unit], None, Some(Duration::from_secs(5))).status == 0)
        .unwrap_or(false)
}

/// Is sshd accepting logins? 24.04 socket-activates it, so the service alone
/// being inactive doesn't mean it's off.
pub fn sshd_running() -> bool {
    systemd_active("ssh") || systemd_active("ssh.socket")
        || systemd_active("sshd")
        || http::probe("127.0.0.1", 22, Duration::from_secs(2))
}

pub fn check_sshd_blocking() -> bool {
    let on = sshd_running();
    let keyed = on && !keys::host_keys().is_empty();
    let mut s = lock();
    if s.sshd_on != Some(on) || s.host_key_ready != keyed {
        s.sshd_on = Some(on);
        s.host_key_ready = keyed;
        drop(s);
        changed();
    }
    on
}

pub fn check_sshd() {
    std::thread::spawn(check_sshd_blocking);
}

pub const INSTALL_HINT: &str = "sudo apt install openssh-server";

/// Turn the ssh server on: one password prompt (polkit). Blocks.
/// Err carries what to tell the user.
pub fn turn_on_sshd_blocking() -> Result<(), String> {
    if !sshd_installed() {
        return Err(format!("The ssh server isn't installed. Run:  {INSTALL_HINT}"));
    }
    let pkexec = shh_core::tools::which("pkexec")
        .ok_or_else(|| "pkexec isn't available. Run:  sudo systemctl enable --now ssh".to_string())?;
    let r = sys::run(&pkexec, &["systemctl", "enable", "--now", "ssh"], None, None);
    // 126: the dialog was dismissed; 127: not authorised
    if r.status == 126 {
        return Ok(());
    }
    std::thread::sleep(Duration::from_millis(600));
    if check_sshd_blocking() {
        Ok(())
    } else {
        Err(format!(
            "Couldn't turn the ssh server on{}. Run:  sudo systemctl enable --now ssh",
            if r.err.trim().is_empty() { String::new() } else { format!(" ({})", r.err.trim()) }
        ))
    }
}

/// Install openssh-server. Only ever called from an explicit Install button.
pub fn install_sshd_blocking() -> Result<(), String> {
    let pkexec = shh_core::tools::which("pkexec")
        .ok_or_else(|| format!("pkexec isn't available. Run:  {INSTALL_HINT}"))?;
    let r = sys::run(
        &pkexec,
        &["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "openssh-server"],
        None,
        None,
    );
    if r.status == 126 {
        return Ok(());
    }
    if !sshd_installed() {
        return Err(format!("The install didn't finish. Run:  {INSTALL_HINT}"));
    }
    std::thread::sleep(Duration::from_millis(600));
    if check_sshd_blocking() { Ok(()) } else { turn_on_sshd_blocking() }
}

// ---- invites ---------------------------------------------------------------

pub fn create_invite(label: &str) -> Result<InviteCode, String> {
    let mut s = lock();
    let Status::Listening(me) = s.status.clone() else {
        return Err("Remote sessions aren't ready yet. Finish the setup steps first.".into());
    };
    let fp = keys::host_keys()
        .first()
        .and_then(|k| keys::fingerprint(k))
        .ok_or_else(|| "This machine has no ssh host key yet. Turn on the ssh server first.".to_string())?;
    let token = keys::random_token(18);
    let now = sys::now();
    let invite = Invite {
        id: keys::random_token(6),
        label: if label.trim().is_empty() { "Invite".into() } else { label.trim().to_string() },
        token_hash: keys::hash(&token),
        created: now,
        expires: now + INVITE_LIFETIME,
    };
    mutate(&mut s, |f| f.invites.push(invite));
    let host = sys::host_label();
    Ok(InviteCode {
        address: me.ipv4.clone(),
        dns_name: me.dns_name.clone(),
        user: sys::user_name(),
        invite_port: port(),
        fingerprint: fp,
        token,
        host_label: if host.is_empty() { me.host_name } else { host },
    })
}

pub fn cancel_invite(id: &str) {
    mutate(&mut lock(), |f| f.invites.retain(|i| i.id != id));
}

fn drop_expired(s: &mut State) {
    if s.file.invites.iter().any(|i| i.is_expired()) {
        mutate(s, |f| f.invites.retain(|i| !i.is_expired()));
    }
}

// ---- guests ----------------------------------------------------------------

pub fn revoke(guest_id: &str) {
    let ids: HashSet<String> = [guest_id.to_string()].into();
    let _ = keys::remove_authorized(&ids);
    let mut s = lock();
    end_sessions(&s.file, &ids);
    mutate(&mut s, |f| f.guests.retain(|g| g.id != guest_id));
}

fn revoke_all() {
    let mut s = lock();
    let mut ids: HashSet<String> = s.file.guests.iter().map(|g| g.id.clone()).collect();
    ids.extend(keys::authorized_guest_ids());
    let _ = keys::remove_authorized(&ids);
    end_sessions(&s.file, &ids);
    mutate(&mut s, |f| f.guests.clear());
}

/// The remote host of an `ss` peer column: "100.64.0.9:51234", "[fd7a::9]:22".
pub fn peer_host(peer: &str) -> String {
    if let Some(rest) = peer.strip_prefix('[') {
        return rest.split(']').next().unwrap_or("").to_string();
    }
    peer.rsplit_once(':').map(|(h, _)| h).unwrap_or(peer).to_string()
}

/// (pid, peer host) for every established TCP connection an sshd of ours holds.
pub fn parse_ss(text: &str) -> Vec<(i32, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        // [State] Recv-Q Send-Q Local Peer users:(("sshd",pid=1,fd=4),…)
        let Some(users_at) = f.iter().position(|c| c.starts_with("users:")) else { continue };
        if users_at < 1 {
            continue;
        }
        let host = peer_host(f[users_at - 1]);
        let users = f[users_at..].join(" ");
        for part in users.split("(\"sshd\",pid=").skip(1) {
            let pid: String = part.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(pid) = pid.parse() {
                out.push((pid, host.clone()));
            }
        }
    }
    out
}

/// Revoking access should also end what they already have open, not just stop
/// the next login. The per-session sshd child runs as us, so we may signal it;
/// it is found by the guest's tailnet address on its socket.
fn end_sessions(file: &File, ids: &HashSet<String>) {
    let addrs: HashSet<String> = file
        .guests
        .iter()
        .filter(|g| ids.contains(&g.id))
        .flat_map(|g| g.addresses.iter().cloned())
        .collect();
    if addrs.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        let Some(ss) = shh_core::tools::which("ss") else { return };
        let r = sys::run(&ss, &["-Htnp", "state", "established"], None, Some(Duration::from_secs(5)));
        let me = std::process::id() as i32;
        for (pid, host) in parse_ss(&r.out) {
            if pid > 1 && pid != me && addrs.contains(&host) {
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        }
    });
}

/// authorized_keys is the source of truth for who can actually get in. A guest
/// whose line was removed by hand is gone; a tagged line with no guest behind
/// it is left alone here but removed when sharing turns off.
fn reconcile(s: &mut State) {
    let present = keys::authorized_guest_ids();
    if s.file.guests.iter().any(|g| !present.contains(&g.id)) {
        mutate(s, |f| f.guests.retain(|g| present.contains(&g.id)));
    }
    drop_expired(s);
}

// ---- prompts handed to the GTK main thread ---------------------------------

/// A join request waiting for the owner to click Allow or Deny.
pub struct Approval {
    pub heading: String,
    pub body: String,
    pub answer: mpsc::Sender<bool>,
}

static APPROVALS: Mutex<Vec<Approval>> = Mutex::new(Vec::new());
static NOTICES: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

pub fn take_approvals() -> Vec<Approval> {
    std::mem::take(&mut *APPROVALS.lock().unwrap_or_else(|e| e.into_inner()))
}
pub fn take_notices() -> Vec<(String, String)> {
    std::mem::take(&mut *NOTICES.lock().unwrap_or_else(|e| e.into_inner()))
}

fn ask(heading: String, body: String) -> bool {
    let (tx, rx) = mpsc::channel();
    APPROVALS.lock().unwrap_or_else(|e| e.into_inner()).push(Approval { heading, body, answer: tx });
    // nobody clicking for ten minutes is a no
    rx.recv_timeout(Duration::from_secs(600)).unwrap_or(false)
}

// ---- the join request ------------------------------------------------------

/// 100.64.0.0/10, the CGNAT range Tailscale hands out, or its v6 ULA.
pub fn is_tailnet(ip: &str) -> bool {
    if ip.to_lowercase().starts_with("fd7a:115c:a1e0:") {
        return true;
    }
    let o: Vec<u32> = ip.split('.').filter_map(|p| p.parse().ok()).collect();
    o.len() == 4 && ip.split('.').count() == 4 && o[0] == 100 && (64..=127).contains(&o[1])
}

fn handle(req: Request) -> (Response, Option<Delivered>) {
    let err = |status: u16, msg: &str| (Response::error(status, msg), None);
    if req.method != "POST" || req.path != "/shh/join" {
        return err(404, "Not found.");
    }
    let testing = test_bind().is_some();
    let ip = match req.remote_ip {
        Some(ip) if testing || is_tailnet(&ip) => ip,
        _ => return err(403, "Only reachable over Tailscale."),
    };

    let (invite, key, hash, device) = {
        let mut s = lock();
        if let Some((count, since)) = s.failures.get(&ip) {
            if *count >= 5 && since.elapsed() < Duration::from_secs(600) {
                return err(429, "Too many bad invites from this device. Try again later.");
            }
        }
        let obj: serde_json::Value = serde_json::from_slice(&req.body).unwrap_or_default();
        let (Some(token), Some(raw_key)) = (obj["token"].as_str(), obj["publicKey"].as_str()) else {
            return err(400, "Malformed request.");
        };
        let Some(key) = keys::normalize_public_key(raw_key) else {
            return err(400, "Malformed request.");
        };
        let device: String = obj["name"].as_str().unwrap_or("").chars().take(80).collect();

        drop_expired(&mut s);
        let hash = keys::hash(token);
        let Some(invite) = s.file.invites.iter().find(|i| i.token_hash == hash).cloned() else {
            let f = s.failures.entry(ip.clone()).or_insert((0, Instant::now()));
            if f.1.elapsed() > Duration::from_secs(600) {
                *f = (0, Instant::now());
            }
            f.0 += 1;
            if let Some(g) = s.file.guests.iter().find(|g| g.invite_hash == hash) {
                NOTICES.lock().unwrap_or_else(|e| e.into_inner()).push((
                    "An invite was used twice".into(),
                    format!(
                        "Someone at {ip} tried the invite already used by {}. They were turned away.",
                        g.display_name
                    ),
                ));
            }
            return err(403, "This invite has expired or was already used. Ask for a new one.");
        };
        // Burn it now, before anyone is asked anything: two people racing the
        // same link must not both reach the Allow prompt.
        mutate(&mut s, |f| f.invites.retain(|i| i.id != invite.id));
        (invite, key, hash, device)
    };

    let peer = if testing {
        Ok(Peer {
            login: "test@local".into(),
            display_name: "Test guest".into(),
            node: "loopback".into(),
            addresses: vec![ip.clone()],
        })
    } else {
        tailscale::whois(&ip)
    };
    let peer = match peer {
        Ok(p) => p,
        Err(e) => {
            return err(403, &format!("That machine couldn't confirm who you are on Tailscale: {e}"))
        }
    };

    let user = sys::user_name();
    let node = if peer.node.is_empty() { device.clone() } else { peer.node.clone() };
    let allowed = ask(
        format!("{} wants to use your invite", peer.display_name),
        format!(
            "Invite: {}\nTailscale account: {}\nDevice: {}\n\nIf you allow this, they can sign in \
             to this computer as {} over ssh until you revoke access or turn off remote sessions.",
            invite.label, peer.login, node, user
        ),
    );
    if !allowed {
        return err(403, "The owner of that machine declined.");
    }

    let mut s = lock();
    if !s.file.enabled {
        return err(403, "Remote sessions were turned off.");
    }
    let guest = Guest {
        id: keys::random_token(6),
        label: invite.label.clone(),
        login: peer.login.clone(),
        display_name: peer.display_name.clone(),
        node,
        addresses: peer.addresses.clone(),
        key_fingerprint: keys::fingerprint(&key).unwrap_or_default(),
        invite_hash: hash,
        added: sys::now(),
    };
    if keys::add_authorized(&keys::authorized_line(&key, &guest.addresses, &guest.id)).is_err() {
        return err(500, "That machine couldn't update its authorized_keys.");
    }
    let guest_id = guest.id.clone();
    mutate(&mut s, |f| f.guests.push(guest));

    let me = match &s.status {
        Status::Listening(n) => Some(n.clone()),
        _ => None,
    };
    let body = serde_json::json!({
        "user": user,
        "host": me.as_ref().map(|n| n.dns_name.clone()).unwrap_or_default(),
        "address": me.as_ref().map(|n| n.ipv4.clone()).unwrap_or_default(),
        "sshPort": 22,
        "hostKeys": keys::host_keys(),
        "name": sys::host_label(),
    });
    drop(s);
    let delivered: Delivered = Box::new(move |ok| {
        // they gave up waiting before Allow was clicked: they never got the
        // server details, so the key we just added would be a dangling door
        if !ok {
            revoke(&guest_id);
        }
    });
    (Response { status: 200, json: body }, Some(delivered))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tailnet_range() {
        assert!(is_tailnet("100.64.0.1"));
        assert!(is_tailnet("100.127.255.254"));
        assert!(is_tailnet("FD7A:115C:A1E0::9"));
        assert!(!is_tailnet("100.63.0.1"));
        assert!(!is_tailnet("100.128.0.1"));
        assert!(!is_tailnet("192.168.1.4"));
        assert!(!is_tailnet("100.64.0"));
    }

    #[test]
    fn sharing_json_matches_the_mac_app() {
        // as JSONEncoder writes it
        let mac = r#"{"enabled":true,"invites":[{"id":"a1","label":"Invite","tokenHash":"h=","created":1795469318.5,"expires":1795470218.5}],"guests":[{"id":"g1","label":"Invite","login":"amy@example.com","displayName":"Amy","node":"amy-mbp","addresses":["100.64.0.9"],"keyFingerprint":"SHA256:x","inviteHash":"h=","added":1795469400.25}]}"#;
        let f: File = serde_json::from_str(mac).unwrap();
        assert!(f.enabled);
        assert_eq!(f.guests[0].display_name, "Amy");
        let back: serde_json::Value = serde_json::to_value(&f).unwrap();
        let orig: serde_json::Value = serde_json::from_str(mac).unwrap();
        assert_eq!(back, orig);
    }

    #[test]
    fn finds_guest_sessions() {
        let out = "0 0 100.100.1.2:22 100.64.0.9:51234 users:((\"sshd\",pid=4321,fd=4),(\"sshd\",pid=4300,fd=4))\n\
                   0 0 [fd7a:115c:a1e0::1]:22 [fd7a:115c:a1e0::9]:40000 users:((\"sshd\",pid=5000,fd=4))\n\
                   0 0 10.0.0.2:443 1.2.3.4:5555 users:((\"firefox\",pid=77,fd=9))\n\
                   0 0 10.0.0.2:22 10.0.0.9:5555\n";
        assert_eq!(
            parse_ss(out),
            vec![
                (4321, "100.64.0.9".to_string()),
                (4300, "100.64.0.9".to_string()),
                (5000, "fd7a:115c:a1e0::9".to_string())
            ]
        );
    }
}
