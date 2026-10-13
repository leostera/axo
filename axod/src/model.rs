use serde::{Deserialize, Serialize};
use uuid::Uuid;

macro_rules! identity {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                deserialize_uuid(deserializer).map(Self)
            }
        }
        impl std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                self.0.fmt(formatter)
            }
        }
        impl $name {
            pub fn new() -> Self {
                Self(Uuid::new_v4())
            }
        }
        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }
    };
}
/// Same RFC UUID text domain as the shared schema; case is not identity.
pub(crate) fn deserialize_uuid<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Uuid, D::Error> {
    let text = String::deserialize(deserializer)?;
    let value = Uuid::parse_str(&text).map_err(|_| serde::de::Error::custom("Invalid UUID"))?;
    let rfc =
        (1..=8).contains(&value.get_version_num()) && value.get_variant() == uuid::Variant::RFC4122;
    if text.len() != 36 || !(rfc || value.is_nil() || value == Uuid::max()) {
        return Err(serde::de::Error::custom("Invalid UUID"));
    }
    Ok(value)
}
identity!(MachineId);
identity!(WorkspaceId);
identity!(SessionId);
identity!(PaneId);
identity!(HostGeneration);
identity!(RuntimeGeneration);
identity!(AttachmentId);
identity!(CommandId);
identity!(StoreGeneration);

impl CommandId {
    pub(crate) fn as_uuid(self) -> Uuid {
        self.0
    }
}
impl SessionId {
    pub(crate) fn as_uuid(self) -> Uuid {
        self.0
    }
}

/// Validates the PID range, not process ownership. Only the live runtime may signal/reap it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "i32", into = "i32")]
pub struct ChildPid(i32);
impl TryFrom<i32> for ChildPid {
    type Error = &'static str;
    fn try_from(value: i32) -> Result<Self, Self::Error> {
        if value <= 0 {
            return Err("Child PID must be positive");
        }
        Ok(Self(value))
    }
}
impl From<ChildPid> for i32 {
    fn from(value: ChildPid) -> Self {
        value.0
    }
}
impl ChildPid {
    pub fn as_raw(self) -> i32 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClientId(pub(crate) u64);
impl ClientId {
    /// In-process terminal lease owner, not authentication or a caller-supplied wire ID.
    pub fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        Self(
            NEXT.try_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |id| id.checked_add(1),
            )
            .expect("Client identity capacity"),
        )
    }
}
impl Default for ClientId {
    fn default() -> Self {
        Self::new()
    }
}

/// Construct once at the resize boundary; downstream PTY operations receive valid dimensions.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalSize {
    rows: u16,
    columns: u16,
}
impl TerminalSize {
    pub fn new(rows: u16, columns: u16) -> Result<Self, &'static str> {
        if !(1..=500).contains(&rows) || !(1..=500).contains(&columns) {
            return Err("Terminal dimensions must be within 1..500");
        }
        Ok(Self { rows, columns })
    }
    pub fn rows(self) -> u16 {
        self.rows
    }
    pub fn columns(self) -> u16 {
        self.columns
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalTarget {
    pub session_id: SessionId,
    pub pane_id: PaneId,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeRef {
    pub host_generation: HostGeneration,
    pub target: TerminalTarget,
    pub runtime_generation: RuntimeGeneration,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttachmentRef {
    pub runtime: RuntimeRef,
    pub attachment_id: AttachmentId,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalLaunch {
    pub directory: String,
    pub argv: Vec<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProcessState {
    Starting {},
    Running { pid: ChildPid },
    Stopping { pid: ChildPid },
    Exited { wait_status: i32 },
    Failed {},
    RecoveryRequired {},
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalSnapshot {
    pub runtime: RuntimeRef,
    pub process: ProcessState,
    pub attached: bool,
    pub backlog_bytes: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn child_pids_reject_process_group_and_broadcast_values() {
        for value in [i32::MIN, -1, 0] {
            assert!(ChildPid::try_from(value).is_err());
            assert!(serde_json::from_str::<ChildPid>(&value.to_string()).is_err());
        }
        assert_eq!(
            serde_json::to_string(&ChildPid::try_from(42).unwrap()).unwrap(),
            "42"
        );
    }
    #[test]
    fn terminal_size_validates_both_axes_at_the_boundary() {
        for (rows, columns) in [(0, 1), (1, 0), (501, 1), (1, 501), (u16::MAX, 1)] {
            assert!(TerminalSize::new(rows, columns).is_err());
        }
        assert!(TerminalSize::new(1, 1).is_ok());
        assert!(TerminalSize::new(500, 500).is_ok());
    }
    #[test]
    fn uuid_fields_validate_external_values() {
        assert!(serde_json::from_str::<PaneId>("\"not-a-uuid\"").is_err());
        let id = PaneId::new();
        assert_eq!(
            serde_json::from_str::<PaneId>(&serde_json::to_string(&id).unwrap()).unwrap(),
            id
        );
    }
}
