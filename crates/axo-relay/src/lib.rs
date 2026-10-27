//! Axo's cloud relay: pairs this host with an Axo account, then keeps an authenticated
//! WebSocket to the relay service so remote clients can list, create and drive sessions.

pub mod credential;
mod endpoint;
mod host;
mod link;
mod pairing;
mod relay;

pub use endpoint::{DEFAULT_RELAY_URL, RelayEndpoint};
pub use host::{PiKey, RelayHost};
pub use link::{AccountLink, HostLink, HostLinkStore, PendingRedemption, host_label, link_host};
pub use relay::{RelayControl, RelayDependencies, RelayWorker, unavailable_status};
