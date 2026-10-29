//! The catalog as clients see it: sessions, their panes, workspaces and configuration.

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
/// `availabilityReason`; the reason is present exactly when the pane is unavailable.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "AvailabilityWire", into = "AvailabilityWire")]
pub enum Availability {
    Available,
    Unavailable { reason: String },
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AvailabilityWire {
    available: bool,
    availability_reason: Option<String>,
}

impl TryFrom<AvailabilityWire> for Availability {
    type Error = &'static str;

    fn try_from(wire: AvailabilityWire) -> Result<Self, Self::Error> {
        match (wire.available, wire.availability_reason) {
            (true, None) => Ok(Availability::Available),
            (false, Some(reason)) if !reason.is_empty() => Ok(Availability::Unavailable { reason }),
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
            },
            Availability::Unavailable { reason } => AvailabilityWire {
                available: false,
                availability_reason: Some(reason),
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
    pub session_uuid: String,
    pub pi_session_file: Option<PathBuf>,
    pub pi_session_id: Option<String>,
    pub workspace_id: Option<String>,
    pub workspace_name: Option<String>,
    /// The title shown to the user: the manual name if set, otherwise Pi's.
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
    pub initial_pwd: PathBuf,
    pub shells: Vec<ShellRecord>,
    pub layout: Option<Layout>,
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
    pub session_uuid: String,
    pub workspace_id: Option<String>,
    pub workspace_name: Option<String>,
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
            session_uuid: record.session_uuid.clone(),
            workspace_id: record.workspace_id.clone(),
            workspace_name: record.workspace_name.clone(),
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
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkspaceState {
    Open,
}

/// A named directory sessions can be created in.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRecord {
    pub workspace_id: String,
    pub name: String,
    pub directory_path: String,
    /// Present only in `axo.workspace.create` results.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<WorkspaceState>,
    /// The Home Workspace, at the user's home directory: it always exists and cannot be
    /// archived. Omitted for every other Workspace.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home: bool,
}

/// A Workspace as a remote person sees it: its name, never its directory on the Mac.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteWorkspace {
    pub workspace_id: String,
    pub name: String,
    /// The Home Workspace, which clients list first. Omitted for every other Workspace.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home: bool,
}

impl From<&WorkspaceRecord> for RemoteWorkspace {
    fn from(record: &WorkspaceRecord) -> Self {
        RemoteWorkspace {
            workspace_id: record.workspace_id.clone(),
            name: record.name.clone(),
            home: record.home,
        }
    }
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
            id: SessionId::new(5).unwrap(),
            session_uuid: "uuid".to_owned(),
            pi_session_file: Some("/private/pi.jsonl".into()),
            pi_session_id: None,
            workspace_id: Some("w".to_owned()),
            workspace_name: Some("private".to_owned()),
            name: "Fix".to_owned(),
            manual_name: None,
            emoji: Some("🦀".to_owned()),
            last_message_at: None,
            created_at: 0,
            status: SessionStatus::Ready,
            initial_pwd: "/private/path".into(),
            shells: vec![shell(11, PaneRole::Pi), shell(12, PaneRole::Terminal)],
            layout: Some(Layout::single(ShellId::new(12).unwrap())),
        };
        let remote = RemoteSessionSnapshot::from_record(&record, "host", "now");
        let wire = serde_json::to_value(&remote).unwrap();
        assert_eq!(wire["shells"], json!([{ "shellId": 12 }]));
        assert_eq!(wire["hasAgent"], true);
        let text = wire.to_string();
        for secret in ["/private/path", "/dev/ttys001", "1234", "pi.jsonl"] {
            assert!(!text.contains(secret), "{secret} leaked");
        }
    }

    #[test]
    fn a_manual_name_wins_in_remote_snapshots() {
        let mut record = SessionRecord {
            id: SessionId::new(5).unwrap(),
            session_uuid: "uuid".to_owned(),
            pi_session_file: None,
            pi_session_id: None,
            workspace_id: None,
            workspace_name: None,
            name: "Pi's title".to_owned(),
            manual_name: None,
            emoji: None,
            last_message_at: None,
            created_at: 0,
            status: SessionStatus::Ready,
            initial_pwd: "/".into(),
            shells: vec![shell(12, PaneRole::Terminal)],
            layout: None,
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
