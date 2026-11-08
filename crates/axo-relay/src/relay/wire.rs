//! The relay's own JSON-RPC messages: the host's requests, its registration and capabilities.
//! The account's calls are the host's (`forward`).

use axo_protocol::HostKind;
use serde::Serialize;

pub(super) const JSONRPC: &str = "2.0";

#[derive(Serialize)]
pub(super) struct OutgoingRequest<'a, P> {
    pub(super) jsonrpc: &'static str,
    pub(super) id: &'a str,
    pub(super) method: &'a str,
    pub(super) params: P,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct NegotiateParams {
    pub(super) protocol_version: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct HostIdentity<'a> {
    pub(super) host_id: &'a str,
    pub(super) host_generation: &'a str,
}

#[derive(Serialize)]
pub(super) struct Capability {
    id: &'static str,
    version: u32,
}

#[cfg(not(windows))]
pub(super) const HOST_CAPABILITIES: &[Capability] = &[
    Capability {
        id: "agent.pi",
        version: 1,
    },
    Capability {
        id: "terminal.pty",
        version: 1,
    },
    Capability {
        id: "workspace.filesystem",
        version: 1,
    },
];

#[cfg(windows)]
pub(super) const HOST_CAPABILITIES: &[Capability] = &[
    // The production v2 service validates a closed capability vocabulary. Codex uses
    // the existing agent-neutral session commands, but must not claim agent.pi or
    // send an unrecognised agent.codex capability that would reject registration.
    Capability {
        id: "workspace.filesystem",
        version: 1,
    },
];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct HostRegistration<'a> {
    pub(super) protocol_version: u32,
    pub(super) host_id: &'a str,
    pub(super) host_generation: &'a str,
    pub(super) label: &'a str,
    pub(super) host_kind: HostKind,
    pub(super) capabilities: &'static [Capability],
    /// Sessions are synced with `axo.host.sync` after registering (RFD0018).
    pub(super) sessions: [(); 0],
}
