use serde::{Deserialize, Serialize};
use uuid::Uuid;

macro_rules! identity {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);
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
identity!(SessionId);
identity!(PaneId);
identity!(HostGeneration);
identity!(RuntimeGeneration);
identity!(AttachmentId);
identity!(CommandId);

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
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProcessState {
    Starting {},
    Running { pid: i32 },
    Stopping { pid: i32 },
    Exited { wait_status: i32 },
    Failed {},
    RecoveryRequired {},
}
#[derive(Clone, Debug, Serialize, Deserialize)]
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
    fn uuid_fields_validate_external_values() {
        assert!(serde_json::from_str::<PaneId>("\"not-a-uuid\"").is_err());
        let id = PaneId::new();
        assert_eq!(
            serde_json::from_str::<PaneId>(&serde_json::to_string(&id).unwrap()).unwrap(),
            id
        );
    }
}
