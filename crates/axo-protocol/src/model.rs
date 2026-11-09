//! The catalog as clients see it: sessions, their panes and configuration.

use std::collections::HashSet;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::{Layout, SessionId, ShellId};

/// What runs in a pane.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneRole {
    /// The session's Pi agent.
    Pi,
    /// The user's shell.
    Terminal,
}

/// A session's state as shown in the sidebar.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionStatus {
    Starting,
    Ready,
    Working,
    NeedsAttention,
    Unavailable,
}

/// Whether a pane has a live process. On the wire this is `available` plus a nullable
/// `availabilityReason`; the reason is present exactly when the pane is unavailable. A dormant
/// pane is also `"dormant": true` (the key is left out otherwise), so clients that predate
/// dormancy see an unavailable pane with a reason that says what is going on.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "AvailabilityWire", into = "AvailabilityWire")]
pub enum Availability {
    Available,
    Unavailable {
        reason: String,
    },
    /// A Pi Axod has deliberately not started, as its Session wasn't active when Axod did; it
    /// starts as soon as anyone shows, prompts or types into the Session.
    Dormant,
}

/// What a client that predates dormancy shows for a dormant pane.
pub const DORMANT_PANE_REASON: &str = "Pi starts when this Session is opened or sent a message.";

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AvailabilityWire {
    available: bool,
    availability_reason: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    dormant: bool,
}

impl TryFrom<AvailabilityWire> for Availability {
    type Error = &'static str;

    fn try_from(wire: AvailabilityWire) -> Result<Self, Self::Error> {
        match (wire.available, wire.availability_reason, wire.dormant) {
            (true, None, false) => Ok(Availability::Available),
            (false, Some(reason), false) if !reason.is_empty() => {
                Ok(Availability::Unavailable { reason })
            }
            (false, Some(reason), true) if !reason.is_empty() => Ok(Availability::Dormant),
            (true, _, true) => Err("an available pane is not dormant"),
            _ => Err("availabilityReason must be present exactly when a pane is unavailable"),
        }
    }
}

impl From<Availability> for AvailabilityWire {
    fn from(availability: Availability) -> Self {
        match availability {
            Availability::Available => AvailabilityWire {
                available: true,
                availability_reason: None,
                dormant: false,
            },
            Availability::Unavailable { reason } => AvailabilityWire {
                available: false,
                availability_reason: Some(reason),
                dormant: false,
            },
            Availability::Dormant => AvailabilityWire {
                available: false,
                availability_reason: Some(DORMANT_PANE_REASON.to_owned()),
                dormant: true,
            },
        }
    }
}

/// One pane of a session.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellRecord {
    pub id: ShellId,
    /// Stable pane identity shared with Pi; Pi panes only.
    pub pane_id: Option<String>,
    pub role: PaneRole,
    /// Zero while the pane is unavailable.
    pub process_id: u32,
    pub initial_pwd: PathBuf,
    /// Empty while the pane is unavailable.
    pub pty_device: String,
    pub attach_socket_path: PathBuf,
    #[serde(flatten)]
    pub availability: Availability,
}

/// A session and its panes.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecord {
    pub id: SessionId,
    pub pi_session_file: Option<PathBuf>,
    pub pi_session_id: Option<String>,
    /// Pi's title for the Session. Clients show `manual_name` when it is set, and this otherwise.
    pub name: String,
    pub manual_name: Option<String>,
    pub emoji: Option<String>,
    /// Unix timestamp in seconds for the most recent completed user or assistant message.
    #[serde(default)]
    pub last_message_at: Option<i64>,
    /// Unix timestamp in seconds when the Session was created.
    #[serde(default)]
    pub created_at: i64,
    pub status: SessionStatus,
    /// The Session's folder, where its panes start (RFD0038).
    pub folder: PathBuf,
    pub shells: Vec<ShellRecord>,
    pub layout: Option<Layout>,
    /// What the Session's Pi runs, once it has said (RFD0033).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pi: Option<PiRuntime>,
}

/// What a Session's Pi runs, as pi-axo publishes it in `pi.state` (RFD0033).
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiRuntime {
    /// `None` when Pi has no model yet (no credentials anywhere).
    pub model: Option<PiModelRef>,
    pub thinking_level: ThinkingLevel,
}

/// A model as Pi's registry names it, with the name people read.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiModelRef {
    pub provider: String,
    pub id: String,
    pub name: String,
}

/// Pi's thinking levels, lowest first.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ThinkingLevel {
    Off,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl ThinkingLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Minimal => "minimal",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Xhigh => "xhigh",
            Self::Max => "max",
        }
    }
}

/// A slash command a client's prompt can run in the Session's Pi (RFD0033).
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiCommandInfo {
    pub name: String,
    pub description: String,
    pub source: PiCommandSource,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PiCommandSource {
    Extension,
    Prompt,
    Skill,
}

/// A model the Session's Pi could switch to, with the thinking levels it supports (RFD0033).
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiModelInfo {
    pub provider: String,
    pub id: String,
    pub name: String,
    pub thinking_levels: Vec<ThinkingLevel>,
}

impl ShellRecord {
    pub fn is_available(&self) -> bool {
        self.availability == Availability::Available
    }
}

impl SessionRecord {
    pub fn has_agent(&self) -> bool {
        self.shells.iter().any(|shell| shell.role == PaneRole::Pi)
    }

    pub fn terminal_shell_ids(&self) -> impl Iterator<Item = ShellId> + '_ {
        self.shells
            .iter()
            .filter(|shell| shell.role == PaneRole::Terminal)
            .map(|shell| shell.id)
    }
}

/// A session as published to the cloud relay: terminal panes only, and no local paths, process
/// IDs or devices.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSessionSnapshot {
    pub host_id: String,
    pub session_id: SessionId,
    /// The last component of the Session's folder; never the path (RFD0038).
    pub folder_name: Option<String>,
    pub name: String,
    pub emoji: Option<String>,
    pub status: SessionStatus,
    pub has_agent: bool,
    pub shells: Vec<RemoteShell>,
    /// The local layout pruned to terminal panes.
    pub layout: Option<Layout>,
    /// When this snapshot was taken, not when the Session was last active.
    pub updated_at: String,
    /// Unix seconds of the Session's latest completed user or assistant message, for listing
    /// chats by recent activity as the Mac does.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_message_at: Option<i64>,
    /// Unix seconds when the Session was created; absent when the store does not know.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    /// What the Session's Pi runs, once it has said (RFD0033).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pi: Option<PiRuntime>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteShell {
    pub shell_id: ShellId,
}

impl RemoteSessionSnapshot {
    pub fn from_record(record: &SessionRecord, host_id: &str, updated_at: &str) -> Self {
        let terminals: Vec<ShellId> = record.terminal_shell_ids().collect();
        let keep: HashSet<ShellId> = terminals.iter().copied().collect();
        RemoteSessionSnapshot {
            host_id: host_id.to_owned(),
            session_id: record.id,
            folder_name: folder_name(&record.folder),
            // What the Mac shows: a name someone typed wins over the one Pi chose.
            name: record.manual_name.as_ref().unwrap_or(&record.name).clone(),
            emoji: record.emoji.clone(),
            status: record.status,
            has_agent: record.has_agent(),
            shells: terminals
                .into_iter()
                .map(|shell_id| RemoteShell { shell_id })
                .collect(),
            layout: record
                .layout
                .as_ref()
                .and_then(|layout| layout.pruned_to(&keep)),
            updated_at: updated_at.to_owned(),
            last_message_at: record.last_message_at,
            created_at: (record.created_at > 0).then_some(record.created_at),
            pi: record.pi.clone(),
        }
    }
}

/// What remote clients show for a folder: its last component.
pub fn folder_name(folder: &std::path::Path) -> Option<String> {
    folder
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
}

/// A daemon setting clients may read and change.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum ConfigKey {
    /// The command line that starts Pi.
    #[serde(rename = "agent.command")]
    AgentCommand,
    /// The command line that starts terminal shells.
    #[serde(rename = "shell.command")]
    ShellCommand,
}

impl ConfigKey {
    pub fn as_str(self) -> &'static str {
        match self {
            ConfigKey::AgentCommand => "agent.command",
            ConfigKey::ShellCommand => "shell.command",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_dormant_pane_reads_as_unavailable_with_a_reason_to_older_clients() {
        let wire = serde_json::to_value(Availability::Dormant).unwrap();
        assert_eq!(
            wire,
            json!({ "available": false, "availabilityReason": DORMANT_PANE_REASON, "dormant": true })
        );
        assert_eq!(
            serde_json::from_value::<Availability>(wire).unwrap(),
            Availability::Dormant
        );
        // Only dormant panes carry the key.
        assert_eq!(
            serde_json::to_value(Availability::Available).unwrap(),
            json!({ "available": true, "availabilityReason": null })
        );
        for bad in [
            json!({ "available": true, "availabilityReason": null, "dormant": true }),
            json!({ "available": false, "availabilityReason": null, "dormant": true }),
        ] {
            assert!(serde_json::from_value::<Availability>(bad).is_err());
        }
    }

    fn shell(id: i64, role: PaneRole) -> ShellRecord {
        ShellRecord {
            id: ShellId::new(id).unwrap(),
            pane_id: None,
            role,
            process_id: 1234,
            initial_pwd: "/private/path".into(),
            pty_device: "/dev/ttys001".to_owned(),
            attach_socket_path: "/tmp/attach.sock".into(),
            availability: Availability::Available,
        }
    }

    #[test]
    fn availability_is_two_consistent_wire_fields() {
        let available = serde_json::to_value(shell(1, PaneRole::Terminal)).unwrap();
        assert_eq!(available["available"], true);
        assert_eq!(available["availabilityReason"], json!(null));
        let mut unavailable = shell(1, PaneRole::Pi);
        unavailable.availability = Availability::Unavailable {
            reason: "gone".to_owned(),
        };
        let wire = serde_json::to_value(&unavailable).unwrap();
        assert_eq!(
            (
                wire["available"].clone(),
                wire["availabilityReason"].clone()
            ),
            (json!(false), json!("gone"))
        );
        assert_eq!(
            serde_json::from_value::<ShellRecord>(wire).unwrap(),
            unavailable
        );
        let mut inconsistent = available;
        inconsistent["available"] = json!(false);
        assert!(serde_json::from_value::<ShellRecord>(inconsistent).is_err());
    }

    #[test]
    fn remote_snapshots_expose_terminals_only_and_no_local_details() {
        let record = SessionRecord {
            id: SessionId::from_u128(5),
            pi_session_file: Some("/private/pi.jsonl".into()),
            pi_session_id: None,
            name: "Fix".to_owned(),
            manual_name: None,
            emoji: Some("🦀".to_owned()),
            last_message_at: None,
            created_at: 0,
            status: SessionStatus::Ready,
            folder: "/private/path".into(),
            shells: vec![shell(11, PaneRole::Pi), shell(12, PaneRole::Terminal)],
            layout: Some(Layout::single(ShellId::new(12).unwrap())),
            pi: None,
        };
        let remote = RemoteSessionSnapshot::from_record(&record, "host", "now");
        let wire = serde_json::to_value(&remote).unwrap();
        assert_eq!(wire["shells"], json!([{ "shellId": 12 }]));
        assert_eq!(wire["hasAgent"], true);
        assert_eq!(wire["folderName"], "path");
        let text = wire.to_string();
        for secret in ["/private", "/dev/ttys001", "1234", "pi.jsonl"] {
            assert!(!text.contains(secret), "{secret} leaked");
        }
    }

    #[test]
    fn a_remote_snapshot_says_what_pi_runs_once_it_has_said() {
        let mut record: SessionRecord = serde_json::from_value(json!({
            "id": SessionId::from_u128(5), "piSessionFile": null, "piSessionId": null,
            "name": "Fix", "manualName": null,
            "emoji": null, "status": "ready", "folder": "/", "shells": [], "layout": null,
        }))
        .unwrap();
        let wire = serde_json::to_value(RemoteSessionSnapshot::from_record(&record, "host", "now"))
            .unwrap();
        assert!(wire.get("pi").is_none(), "old clients see nothing new");

        record.pi = Some(PiRuntime {
            model: Some(PiModelRef {
                provider: "anthropic".to_owned(),
                id: "claude-opus-4-1".to_owned(),
                name: "Opus 4.1".to_owned(),
            }),
            thinking_level: ThinkingLevel::Xhigh,
        });
        let wire = serde_json::to_value(RemoteSessionSnapshot::from_record(&record, "host", "now"))
            .unwrap();
        assert_eq!(
            wire["pi"],
            json!({ "model": { "provider": "anthropic", "id": "claude-opus-4-1", "name": "Opus 4.1" }, "thinkingLevel": "xhigh" })
        );
        for level in ["off", "minimal", "low", "medium", "high", "xhigh", "max"] {
            let parsed: ThinkingLevel = serde_json::from_value(json!(level)).unwrap();
            assert_eq!(parsed.as_str(), level);
        }
    }

    #[test]
    fn a_manual_name_wins_in_remote_snapshots() {
        let mut record = SessionRecord {
            id: SessionId::from_u128(5),
            pi_session_file: None,
            pi_session_id: None,
            name: "Pi's title".to_owned(),
            manual_name: None,
            emoji: None,
            last_message_at: None,
            created_at: 0,
            status: SessionStatus::Ready,
            folder: "/".into(),
            shells: vec![shell(12, PaneRole::Terminal)],
            layout: None,
            pi: None,
        };
        assert_eq!(
            RemoteSessionSnapshot::from_record(&record, "h", "t").name,
            "Pi's title"
        );
        record.manual_name = Some("Mine".to_owned());
        assert_eq!(
            RemoteSessionSnapshot::from_record(&record, "h", "t").name,
            "Mine"
        );
    }

    #[test]
    fn config_keys_use_their_dotted_wire_names() {
        assert_eq!(
            serde_json::to_value(ConfigKey::ShellCommand).unwrap(),
            "shell.command"
        );
        assert_eq!(
            serde_json::from_value::<ConfigKey>(json!("agent.command")).unwrap(),
            ConfigKey::AgentCommand
        );
        assert!(serde_json::from_value::<ConfigKey>(json!("shell")).is_err());
    }
}
