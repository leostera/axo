//! What the relay needs from the daemon that hosts it.

use std::io;
use std::time::Duration;

use serde_json::Value;

use crate::relay::RelayStatus;

/// The daemon's sessions, as seen by the cloud relay. Implemented by Axod's session manager.
///
/// Remote callers are untrusted: implementations validate every identifier and payload.
pub trait RelayHost: Send + Sync {
    /// Stable identity of this host.
    fn host_id(&self) -> &str;
    /// Changes every daemon start; lets the cloud discard stale state.
    fn host_generation(&self) -> &str;
    fn publish_relay_status(&self, status: &RelayStatus);

    /// Every open session in the host-relay snapshot shape.
    fn remote_session_snapshots(&self, updated_at: &str) -> io::Result<Vec<Value>>;
    /// Subscribes to local events (including terminal output); returns the subscription ID.
    fn subscribe_remote_events(&self) -> io::Result<String>;
    fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Value>>;
    /// Current snapshots as local events, for resynchronizing after the stream lagged.
    fn remote_resync_events(&self) -> io::Result<Vec<Value>>;
    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()>;

    fn remote_create_session(&self, updated_at: &str) -> io::Result<Value>;
    fn remote_create_workspace_session(
        &self,
        workspace_id: &str,
        updated_at: &str,
    ) -> io::Result<Value>;
    /// Returns the replacement session, if closing the last one created it.
    fn remote_close_session(&self, session_id: i64, updated_at: &str) -> io::Result<Option<Value>>;
    fn remote_create_shell(&self, session_id: i64) -> io::Result<i64>;
    fn remote_close_shell(&self, session_id: i64, shell_id: i64) -> io::Result<()>;
    fn remote_set_layout(&self, session_id: i64, layout: Value) -> io::Result<()>;
    fn remote_terminal_input(
        &self,
        session_id: i64,
        shell_id: i64,
        sequence: u64,
        data: &str,
    ) -> io::Result<()>;
    fn remote_terminal_resize(
        &self,
        session_id: i64,
        shell_id: i64,
        rows: u32,
        columns: u32,
    ) -> io::Result<()>;
}
