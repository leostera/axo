//! What the relay needs from the daemon that hosts it.

use std::io;
use std::time::Duration;

use axo_protocol::{Event, LayoutNode, RelayStatus, RemoteSessionSnapshot, SessionId, ShellId};

/// The daemon's sessions, as seen by the cloud relay. Implemented by Axod's session manager.
///
/// Identifiers arrive already parsed (positive); implementations still check that they name
/// open sessions and panes, because remote callers are untrusted.
pub trait RelayHost: Send + Sync {
    /// Stable identity of this host.
    fn host_id(&self) -> &str;
    /// Changes every daemon start; lets the cloud discard stale state.
    fn host_generation(&self) -> &str;
    fn publish_relay_status(&self, status: &RelayStatus);

    /// Every open session, terminal panes only.
    fn remote_session_snapshots(&self, updated_at: &str) -> io::Result<Vec<RemoteSessionSnapshot>>;
    /// Subscribes to local events (including terminal output); returns the subscription ID.
    fn subscribe_remote_events(&self) -> io::Result<String>;
    fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Event>>;
    /// Current snapshots as events, for resynchronizing after the stream lagged.
    fn remote_resync_events(&self) -> io::Result<Vec<Event>>;
    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()>;

    fn remote_create_session(&self, updated_at: &str) -> io::Result<RemoteSessionSnapshot>;
    fn remote_create_workspace_session(
        &self,
        workspace_id: &str,
        updated_at: &str,
    ) -> io::Result<RemoteSessionSnapshot>;
    /// Returns the replacement session, if closing the last one created it.
    fn remote_close_session(
        &self,
        session_id: SessionId,
        updated_at: &str,
    ) -> io::Result<Option<RemoteSessionSnapshot>>;
    fn remote_create_shell(&self, session_id: SessionId) -> io::Result<ShellId>;
    fn remote_close_shell(&self, session_id: SessionId, shell_id: ShellId) -> io::Result<()>;
    /// Fails with `InvalidInput` if the layout is malformed or does not match the open panes.
    fn remote_set_layout(&self, session_id: SessionId, layout: LayoutNode) -> io::Result<()>;
    fn remote_terminal_input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        data: &str,
    ) -> io::Result<()>;
    fn remote_terminal_resize(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        rows: u32,
        columns: u32,
    ) -> io::Result<()>;
}
