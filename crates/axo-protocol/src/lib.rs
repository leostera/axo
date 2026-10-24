//! Axo's wire protocol: the identifiers, records, events, and RPC parameters and results that
//! axod exchanges with local clients and the cloud relay.
//!
//! Every type here is parsed at the boundary: deserializing one establishes its invariants (for
//! example, IDs are positive and layouts are structurally valid), so code holding a value never
//! re-checks them. The JSON shapes are fixed by `schemas/axo.leostera.dev/v1`.

mod event;
mod ids;
mod layout;
mod model;
mod relay;
pub mod rpc;

#[cfg(test)]
mod conformance;

pub use event::{Event, EventScope, ShellActivity};
pub use ids::{InvalidId, SessionId, ShellId, new_uuid_v4};
pub use layout::{Layout, LayoutDirection, LayoutError, LayoutNode, is_uuid};
pub use model::{
    Availability, ConfigKey, PaneRole, RemoteSessionSnapshot, RemoteShell, SessionRecord,
    SessionStatus, ShellRecord, WorkspaceRecord, WorkspaceState,
};
pub use relay::{HostKind, RelayState, RelayStatus};
