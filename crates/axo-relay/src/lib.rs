//! Axo's cloud relay: pairs this host with an Axo account, then keeps an authenticated
//! WebSocket to the relay service so remote clients can list, create and drive sessions.

pub mod credential;
mod host;
mod pairing;
mod relay;

pub use host::RelayHost;
pub use relay::{
    CONFIG_FILE, ConfigureRelayRequest, RelayControl, RelayStatus, RelayWorker, configure, disable,
    link_host, settings, unavailable_status,
};
