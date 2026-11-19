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
    #[serde(rename = "linux")]
    Linux,
    #[serde(rename = "windows")]
    Windows,
}

impl HostKind {
    #[cfg(target_os = "windows")]
    pub const fn current() -> Self {
        Self::Windows
    }

    #[cfg(target_os = "linux")]
    pub const fn current() -> Self {
        Self::Linux
    }

    #[cfg(target_os = "windows")]
    pub const fn current() -> Self {
        Self::Windows
    }

    #[cfg(target_os = "macos")]
    pub const fn current() -> Self {
        Self::MacOS
    }
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

#[cfg(test)]
mod tests {
    use super::HostKind;

    #[test]
    fn relay_schema_keeps_every_supported_host_kind() {
        let schema: serde_json::Value = serde_json::from_str(include_str!(
            "../../../schemas/axo.leostera.dev/v1/local-rpc.schema.json"
        ))
        .unwrap();
        let kinds = schema["$defs"]["RemoteAccessStatusResult"]["properties"]["hostKind"]["enum"]
            .as_array()
            .expect("host kinds are an explicit shared vocabulary");
        assert_eq!(kinds.len(), 3);
        for kind in [HostKind::MacOS, HostKind::Linux, HostKind::Windows] {
            let wire = serde_json::to_value(kind).unwrap();
            assert!(
                kinds.contains(&wire),
                "the shared schema must retain {wire}"
            );
            assert_eq!(serde_json::from_value::<HostKind>(wire).unwrap(), kind);
        }
    }

    #[test]
    fn host_platform_is_explicit_on_the_wire() {
        assert_eq!(
            serde_json::to_string(&HostKind::MacOS).unwrap(),
            "\"macos\""
        );
        assert_eq!(
            serde_json::to_string(&HostKind::Linux).unwrap(),
            "\"linux\""
        );
        assert_eq!(
            serde_json::from_str::<HostKind>("\"linux\"").unwrap(),
            HostKind::Linux
        );
        assert_eq!(
            serde_json::to_string(&HostKind::Windows).unwrap(),
            "\"windows\""
        );
        assert_eq!(
            serde_json::from_str::<HostKind>("\"windows\"").unwrap(),
            HostKind::Windows
        );
        #[cfg(target_os = "windows")]
        assert_eq!(HostKind::current(), HostKind::Windows);
        #[cfg(target_os = "linux")]
        assert_eq!(HostKind::current(), HostKind::Linux);
        #[cfg(target_os = "macos")]
        assert_eq!(HostKind::current(), HostKind::MacOS);
    }
}
