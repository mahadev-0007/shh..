//! `sshm.json`: display names, icons, projects, agents, settings. Nothing
//! secret. Field names are the Mac app's, so the file moves between machines.
use crate::{fsutil, paths};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;

pub const DEFAULT_SHELL: &str = "${SHELL:-/bin/sh} -lic";
pub const LEGACY_SHELL: &str = "${SHELL:-/bin/sh} -lc";
pub const SEED_VERSION: i64 = 4;
pub const FILE_VERSION: i64 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IconRef {
    /// "emoji" | "symbol" (an SF Symbol name on the Mac) | "mark" | "image"
    pub kind: String,
    pub value: String,
}

impl IconRef {
    pub fn emoji(v: &str) -> Self {
        IconRef { kind: "emoji".into(), value: v.into() }
    }
    pub fn mark(v: &str) -> Self {
        IconRef { kind: "mark".into(), value: v.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<IconRef>,
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Uppercase UUID v4, the shape Swift's `UUID().uuidString` produces.
pub fn new_id() -> String {
    let mut b: [u8; 16] = rand::random();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02X}")).collect();
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

fn d_path() -> String {
    "~".into()
}
fn d_true() -> bool {
    true
}
fn d_shell() -> String {
    DEFAULT_SHELL.into()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<IconRef>,
    pub server: String,
    #[serde(default = "d_path")]
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default = "now")]
    pub created_at: f64,
    #[serde(default)]
    pub last_opened_at: f64,
    #[serde(default)]
    pub order: i64,
}

impl Project {
    pub fn new(name: &str, server: &str, path: &str) -> Self {
        Project {
            id: new_id(),
            name: name.into(),
            icon: None,
            server: server.into(),
            path: path.into(),
            agent: None,
            created_at: now(),
            last_opened_at: 0.0,
            order: 0,
        }
    }
    pub fn touch(&mut self) {
        self.last_opened_at = now();
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDef {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<IconRef>,
    #[serde(default)]
    pub command: String,
    #[serde(default = "d_shell")]
    pub shell: String,
    #[serde(default = "d_true")]
    pub keep_shell: bool,
    #[serde(default)]
    pub builtin: bool,
}

pub fn seed_agents() -> Vec<AgentDef> {
    let a = |id: &str, name: &str, mark: &str, command: &str| AgentDef {
        id: id.into(),
        name: name.into(),
        icon: Some(IconRef::mark(mark)),
        command: command.into(),
        shell: DEFAULT_SHELL.into(),
        keep_shell: true,
        builtin: true,
    };
    vec![
        a("claude", "Claude Code", "claude", "claude"),
        a("claude-continue", "Claude Code (continue)", "claude", "claude --continue"),
        a("codex", "Codex", "openai", "codex"),
        a("gemini", "Gemini CLI", "gemini", "gemini"),
        a("command", "Command Code", "command", "cmd"),
        a("aider", "Aider", "aider", "aider"),
        a("opencode", "opencode", "opencode", "opencode"),
        a("cursor", "Cursor Agent", "cursor", "cursor-agent"),
        a("shell", "Shell", "terminal", ""),
        a("tmux", "tmux", "tmux", "tmux new -A -s sshm"),
        a("editor", "Editor", "editor", "${EDITOR:-vim} ."),
    ]
}

fn d_agent() -> String {
    "claude".into()
}
fn d_font() -> f64 {
    13.0
}
fn d_section() -> String {
    "dashboard".into()
}
fn d_theme() -> String {
    "dark".into()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    #[serde(default = "d_agent")]
    pub default_agent: String,
    #[serde(default = "d_font")]
    pub font_size: f64,
    #[serde(default = "d_section")]
    pub last_section: String,
    #[serde(default = "d_true")]
    pub share_connection_per_server: bool,
    #[serde(default = "d_theme")]
    pub theme: String,
    #[serde(default = "d_true")]
    pub paste_images_to_server: bool,
    #[serde(default = "d_true")]
    pub automatic_updates: bool,
    #[serde(default = "d_true")]
    pub durable_sessions: bool,
    #[serde(default = "d_true")]
    pub auto_reconnect: bool,
    #[serde(default = "d_true")]
    pub voice_input: bool,
    #[serde(default = "d_true")]
    pub notify_on_bell: bool,
    #[serde(default = "d_true")]
    pub notify_on_remote: bool,
    #[serde(default = "d_true")]
    pub notify_on_disconnect: bool,
    #[serde(default)]
    pub notify_on_idle: bool,
    #[serde(default = "d_true")]
    pub bell_sound: bool,
    /// Settings a newer build wrote that this one doesn't know: kept, not dropped.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Default for AppSettings {
    fn default() -> Self {
        serde_json::from_str("{}").expect("defaults")
    }
}

fn d_version() -> i64 {
    FILE_VERSION
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaFile {
    #[serde(default = "d_version")]
    pub version: i64,
    #[serde(default)]
    pub seeded_agents: i64,
    #[serde(default)]
    pub servers: BTreeMap<String, ServerMeta>,
    #[serde(default)]
    pub projects: Vec<Project>,
    #[serde(default)]
    pub agents: Vec<AgentDef>,
    #[serde(default)]
    pub settings: AppSettings,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Default for MetaFile {
    fn default() -> Self {
        serde_json::from_str("{}").expect("defaults")
    }
}

impl MetaFile {
    pub fn agent(&self, id: Option<&str>) -> Option<&AgentDef> {
        let want = id.unwrap_or(&self.settings.default_agent);
        self.agents.iter().find(|a| a.id == want)
    }
}

/// Bring an older file up to the current seeded agent set without resurrecting
/// agents the user deleted on purpose.
pub fn migrate(mut f: MetaFile) -> MetaFile {
    if f.seeded_agents < SEED_VERSION {
        let seeds = seed_agents();
        let known: std::collections::HashSet<String> = f.agents.iter().map(|a| a.id.clone()).collect();
        f.agents.extend(seeds.iter().filter(|s| !known.contains(&s.id)).cloned());
        if f.seeded_agents < 2 {
            for a in f.agents.iter_mut().filter(|a| a.builtin) {
                if a.icon.as_ref().map(|i| i.kind == "emoji").unwrap_or(false) {
                    if let Some(seed) = seeds.iter().find(|s| s.id == a.id) {
                        a.icon = seed.icon.clone();
                    }
                }
            }
        }
        if f.seeded_agents < 4 {
            for a in f.agents.iter_mut().filter(|a| a.builtin && a.shell == LEGACY_SHELL) {
                a.shell = DEFAULT_SHELL.into();
            }
        }
        f.seeded_agents = SEED_VERSION;
    }
    f
}

pub fn file() -> PathBuf {
    paths::config_dir().join("sshm.json")
}

/// The loaded file plus whether it is safe to write back.
#[derive(Debug, Clone)]
pub struct Store {
    pub file: MetaFile,
    /// A newer app wrote this file, or it could not be parsed: never overwrite.
    pub read_only: bool,
    pub load_error: Option<String>,
}

impl Store {
    pub fn load() -> Store {
        paths::ensure_dir();
        let path = file();
        let Ok(data) = std::fs::read(&path) else {
            let s = Store {
                file: MetaFile {
                    seeded_agents: SEED_VERSION,
                    agents: seed_agents(),
                    ..MetaFile::default()
                },
                read_only: false,
                load_error: None,
            };
            s.save();
            return s;
        };
        match serde_json::from_slice::<MetaFile>(&data) {
            Ok(original) => {
                let read_only = original.version > FILE_VERSION;
                let file = if read_only { original.clone() } else { migrate(original.clone()) };
                let s = Store { file, read_only, load_error: None };
                if s.file != original {
                    s.save();
                }
                s
            }
            Err(e) => Store {
                file: MetaFile {
                    seeded_agents: SEED_VERSION,
                    agents: seed_agents(),
                    ..MetaFile::default()
                },
                read_only: true,
                load_error: Some(e.to_string()),
            },
        }
    }

    pub fn save(&self) {
        if self.read_only || self.load_error.is_some() {
            return;
        }
        // through Value so keys come out sorted, like the Mac app's encoder
        let Ok(v) = serde_json::to_value(&self.file) else { return };
        let Ok(text) = serde_json::to_string_pretty(&v) else { return };
        let _ = fsutil::write_atomic(&file(), text.as_bytes(), 0o600);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Trimmed from a file the Mac app wrote.
    const MAC: &str = r#"{
      "agents": [{"builtin": true, "command": "claude",
                  "icon": {"kind": "mark", "value": "claude"}, "id": "claude",
                  "keepShell": true, "name": "Claude Code", "shell": "${SHELL:-/bin/sh} -lic"}],
      "projects": [{"agent": "claude", "createdAt": 1788548281.960316,
                    "icon": {"kind": "emoji", "value": "📁"},
                    "id": "0751DEF5-428F-4A4E-90A2-B0C5BE3E6B41",
                    "lastOpenedAt": 1795469318.956672, "name": "CRM", "order": 0,
                    "path": "/srv/app", "server": "saas-server-2"}],
      "seededAgents": 4,
      "servers": {"fan": {"displayName": "Fan", "icon": {"kind": "image", "value": "a.png"}}},
      "settings": {"autoReconnect": true, "fontSize": 12, "theme": "dark",
                   "someFutureSetting": 7},
      "version": 1
    }"#;

    #[test]
    fn reads_what_the_mac_app_writes() {
        let f: MetaFile = serde_json::from_str(MAC).unwrap();
        assert_eq!(f.projects[0].path, "/srv/app");
        assert_eq!(f.servers["fan"].display_name.as_deref(), Some("Fan"));
        assert_eq!(f.settings.font_size, 12.0);
        assert!(f.settings.durable_sessions); // absent → default
        assert_eq!(f.agent(None).unwrap().command, "claude");
    }

    #[test]
    fn unknown_settings_survive_a_round_trip() {
        let f: MetaFile = serde_json::from_str(MAC).unwrap();
        let v = serde_json::to_value(&f).unwrap();
        assert_eq!(v["settings"]["someFutureSetting"], 7);
        assert_eq!(v["projects"][0]["lastOpenedAt"], 1795469318.956672);
        let again: MetaFile = serde_json::from_value(v).unwrap();
        assert_eq!(again, f);
    }

    #[test]
    fn migration_adds_missing_seeds_once() {
        let mut f: MetaFile = serde_json::from_str(MAC).unwrap();
        f.seeded_agents = 3;
        let m = migrate(f);
        assert_eq!(m.agents.len(), seed_agents().len());
        assert_eq!(migrate(m.clone()), m);
    }

    #[test]
    fn ids_look_like_swift_uuids() {
        let id = new_id();
        assert_eq!(id.len(), 36);
        assert_eq!(id, id.to_uppercase());
    }
}
