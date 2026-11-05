//! The relay connection's status as Axo.app shows it, and the manual retry it offers.

use std::io;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use axo_protocol::{HostKind, RelayState, RelayStatus};

use super::session::unix_timestamp_millis;
use crate::link::host_label;

type RelayStatusObserver = Box<dyn Fn(&RelayStatus) + Send + Sync>;

pub struct RelayControl {
    status: Mutex<RelayStatus>,
    pub(super) reconnect_requested: AtomicBool,
    /// Told about every status change, outside the status lock (publishes `relay.status`).
    observer: Option<RelayStatusObserver>,
}

impl RelayControl {
    pub(super) fn new(host_name: String, host_kind: HostKind) -> Self {
        Self {
            status: Mutex::new(RelayStatus {
                state: RelayState::Disconnected,
                connected_since_unix_millis: None,
                host_name,
                host_kind,
                last_error: None,
            }),
            reconnect_requested: AtomicBool::new(false),
            observer: None,
        }
    }

    pub(super) fn with_observer(mut self, observer: RelayStatusObserver) -> Self {
        self.observer = Some(observer);
        self
    }

    /// Applies `change` and notifies the observer only when the status actually changed.
    fn update(&self, change: impl FnOnce(&mut RelayStatus)) -> io::Result<()> {
        let changed = {
            let mut status = self
                .status
                .lock()
                .map_err(|_| io::Error::other("relay status lock was poisoned"))?;
            let before = status.clone();
            change(&mut status);
            (*status != before).then(|| status.clone())
        };
        if let (Some(status), Some(observer)) = (changed, &self.observer) {
            observer(&status);
        }
        Ok(())
    }

    pub fn snapshot(&self) -> io::Result<RelayStatus> {
        self.status
            .lock()
            .map(|status| status.clone())
            .map_err(|_| io::Error::other("relay status lock was poisoned"))
    }

    pub fn request_connect(&self) -> io::Result<()> {
        self.reconnect_requested.store(true, Ordering::Relaxed);
        self.update(Self::connecting)
    }

    fn connecting(status: &mut RelayStatus) {
        status.state = RelayState::Connecting;
        status.connected_since_unix_millis = None;
        status.last_error = None;
    }

    pub(super) fn mark_connecting(&self) {
        let _ = self.update(Self::connecting);
    }

    pub(super) fn mark_connected(&self) {
        let _ = self.update(|status| {
            if status.state != RelayState::Connected {
                status.state = RelayState::Connected;
                status.connected_since_unix_millis = Some(unix_timestamp_millis());
            }
            status.last_error = None;
        });
    }

    pub(super) fn mark_disconnected(&self, error: impl std::fmt::Display) {
        let _ = self.update(|status| {
            status.state = RelayState::Disconnected;
            status.connected_since_unix_millis = None;
            status.last_error = Some(error.to_string().chars().take(512).collect());
        });
    }
}

pub fn unavailable_status() -> RelayStatus {
    RelayStatus {
        state: RelayState::Disconnected,
        connected_since_unix_millis: None,
        host_name: host_label(),
        host_kind: HostKind::MacOS,
        last_error: Some("Remote access is unavailable on this Mac.".to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn relay_status_tracks_connection_and_manual_retry_states() {
        let control = RelayControl::new("Test Mac".to_owned(), HostKind::MacOS);
        assert_eq!(control.snapshot().unwrap().state, RelayState::Disconnected);

        control.mark_connected();
        let connected = control.snapshot().unwrap();
        assert_eq!(connected.state, RelayState::Connected);
        assert!(connected.connected_since_unix_millis.is_some());
        assert_eq!(connected.host_name, "Test Mac");

        control.mark_disconnected("HTTP error: 302 Found");
        let disconnected = control.snapshot().unwrap();
        assert_eq!(disconnected.state, RelayState::Disconnected);
        assert_eq!(
            disconnected.last_error.as_deref(),
            Some("HTTP error: 302 Found")
        );

        control.request_connect().unwrap();
        let retrying = control.snapshot().unwrap();
        assert_eq!(retrying.state, RelayState::Connecting);
        assert_eq!(retrying.connected_since_unix_millis, None);
        assert_eq!(retrying.last_error, None);
        assert!(control.reconnect_requested.swap(false, Ordering::Relaxed));
    }

    #[test]
    fn relay_status_observer_sees_only_real_changes() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorder = Arc::clone(&seen);
        let control = RelayControl::new("Test Mac".to_owned(), HostKind::MacOS).with_observer(
            Box::new(move |status| recorder.lock().unwrap().push(status.state)),
        );
        control.mark_connecting();
        control.mark_connecting();
        control.mark_connected();
        let connected_since = control.snapshot().unwrap().connected_since_unix_millis;
        control.mark_connected();
        assert_eq!(
            control.snapshot().unwrap().connected_since_unix_millis,
            connected_since,
            "a repeated connected mark must not reset the connection time"
        );
        control.mark_disconnected("gone");
        assert_eq!(
            *seen.lock().unwrap(),
            [
                RelayState::Connecting,
                RelayState::Connected,
                RelayState::Disconnected
            ]
        );
    }
}
