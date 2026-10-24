//! Events axod publishes to subscribers (`axo.session.subscribe`) and the relay.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{RelayStatus, SessionId, SessionRecord, ShellId};

/// What happened to a pane's process or its attachments.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ShellActivity {
    Started,
    Exited,
    /// The first client attached.
    Attached,
    /// The last client detached.
    Detached,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "type", rename_all_fields = "camelCase")]
pub enum Event {
    /// The session's current state; replaces any earlier snapshot.
    #[serde(rename = "session.snapshot")]
    SessionSnapshot { session: Box<SessionRecord> },
    /// The session was archived.
    #[serde(rename = "session.removed")]
    SessionRemoved { session_id: SessionId },
    /// Clients should select this session (after Pi's `/resume`).
    #[serde(rename = "session.focus")]
    SessionFocus { session_id: SessionId },
    #[serde(rename = "shell.activity")]
    ShellActivity {
        session_id: SessionId,
        shell_id: ShellId,
        activity: ShellActivity,
    },
    /// PTY output. `sequence` counts chunks per shell from zero; `data` is base64.
    #[serde(rename = "terminal.output")]
    TerminalOutput {
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        data: String,
    },
    /// An event from Pi's extension bridge. `data` is Pi's own payload, opaque to axod.
    #[serde(rename = "pi.event")]
    PiEvent {
        session_id: SessionId,
        pi_session_id: String,
        stream_id: String,
        sequence: u64,
        name: String,
        data: Value,
    },
    #[serde(rename = "workspace.changed")]
    WorkspaceChanged { workspace_id: String },
    #[serde(rename = "relay.status")]
    RelayStatus { status: RelayStatus },
    /// The subscriber fell behind and events were dropped; resynchronize from a fresh list.
    #[serde(rename = "subscription.lagged")]
    SubscriptionLagged,
}

impl Event {
    pub fn snapshot(session: SessionRecord) -> Event {
        Event::SessionSnapshot {
            session: Box::new(session),
        }
    }

    /// The session the event concerns, for per-session subscriptions.
    pub fn session_id(&self) -> Option<SessionId> {
        match self {
            Event::SessionSnapshot { session } => Some(session.id),
            Event::SessionRemoved { session_id }
            | Event::SessionFocus { session_id }
            | Event::ShellActivity { session_id, .. }
            | Event::TerminalOutput { session_id, .. }
            | Event::PiEvent { session_id, .. } => Some(*session_id),
            Event::WorkspaceChanged { .. }
            | Event::RelayStatus { .. }
            | Event::SubscriptionLagged => None,
        }
    }

    /// High-volume streams (terminal bytes, Pi token streams) versus everything else.
    pub fn scope(&self) -> EventScope {
        match self {
            Event::TerminalOutput { .. } | Event::PiEvent { .. } => EventScope::Streams,
            _ => EventScope::Catalog,
        }
    }
}

/// Which events a subscription receives. Catalog subscribers never pay for, or lag on,
/// terminal bytes or Pi token streams.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventScope {
    /// Catalog events only.
    Catalog,
    /// Catalog events and streams.
    Streams,
}

impl EventScope {
    pub fn accepts(self, event: EventScope) -> bool {
        match self {
            EventScope::Streams => true,
            EventScope::Catalog => event == EventScope::Catalog,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_use_their_wire_type_names_and_camel_case_fields() {
        let event = Event::ShellActivity {
            session_id: SessionId::new(1).unwrap(),
            shell_id: ShellId::new(2).unwrap(),
            activity: ShellActivity::Exited,
        };
        assert_eq!(
            serde_json::to_value(&event).unwrap(),
            json!({ "type": "shell.activity", "sessionId": 1, "shellId": 2, "activity": "exited" })
        );
        assert_eq!(
            serde_json::to_value(Event::SubscriptionLagged).unwrap(),
            json!({ "type": "subscription.lagged" })
        );
        let output: Event = serde_json::from_value(
            json!({ "type": "terminal.output", "sessionId": 1, "shellId": 2, "sequence": 0, "data": "aGk=" }),
        )
        .unwrap();
        assert_eq!(output.scope(), EventScope::Streams);
        assert_eq!(output.session_id(), SessionId::new(1));
    }

    #[test]
    fn catalog_subscribers_never_receive_streams() {
        assert!(EventScope::Catalog.accepts(EventScope::Catalog));
        assert!(!EventScope::Catalog.accepts(EventScope::Streams));
        assert!(EventScope::Streams.accepts(EventScope::Streams));
        assert!(EventScope::Streams.accepts(EventScope::Catalog));
    }
}
