//! Axo's cloud relay: pairs this host with an Axo account, then keeps an authenticated
//! WebSocket to the relay service so remote clients can list, create and drive sessions.

pub mod assets;
pub mod bash;
pub mod computer;
pub mod credential;
mod endpoint;
pub mod fragments;
mod host;
mod link;
mod outbound;
mod pairing;
pub mod peers;
mod relay;
pub mod signin;
mod sync;

pub use endpoint::{DEFAULT_RELAY_URL, RelayEndpoint};
pub use host::{CommandId, PiKey, RelayHost, TurnId};
pub use link::{AccountLink, HostLink, HostLinkStore, PendingRedemption, host_label, link_host};
pub use outbound::{Priority, RelayCallError, RelayChannel, ReplySender};
pub use relay::{RelayControl, RelayDependencies, RelayWorker, unavailable_status};
pub use sync::{SessionMetadata, StoredSyncState, SyncSession, WorkspaceState};
