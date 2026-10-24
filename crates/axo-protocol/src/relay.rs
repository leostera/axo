//! The cloud relay connection's status, as reported to local clients.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RelayState {
    Disconnected,
    Connecting,
    Connected,
}

/// The kind of machine hosting axod.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum HostKind {
    #[serde(rename = "macos")]
    MacOS,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayStatus {
    pub state: RelayState,
    /// Set while `state` is `Connected`.
    pub connected_since_unix_millis: Option<u64>,
    pub host_name: String,
    pub host_kind: HostKind,
    pub last_error: Option<String>,
}
