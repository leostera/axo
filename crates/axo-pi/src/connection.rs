//! The bridge connection as a state machine: what each record means in each phase.
//!
//! A connection authenticates, then binds to the exact pane Axod launched (every identity field
//! must match), then carries one event stream whose sequence only increases. Any other record,
//! or a record that breaks these rules, rejects the connection; the caller drops it.

use std::path::Path;

use axo_protocol::is_uuid;
use serde_json::Value;

use crate::protocol::{Identity, Record};

/// JavaScript's largest exact integer: sequences beyond it cannot round-trip through clients.
pub const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
/// Pi events are forwarded to clients; a larger one is skipped (the connection stays).
pub const MAX_EVENT_DATA_BYTES: usize = 60_000;
const MAX_NAME_BYTES: usize = 128;
const MAX_PI_SESSION_ID_BYTES: usize = 128;
/// The event the extension sends when Pi's `/resume` picked a saved Session.
const RESUME_REQUESTED: &str = "session.resume.requested";

/// The pane a connection must prove it serves.
#[derive(Clone, Debug)]
pub struct ExpectedPane<'a> {
    pub session_uuid: &'a str,
    pub pane_id: &'a str,
    pub session_file: &'a Path,
    pub cwd: &'a Path,
    pub process_id: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Phase {
    AwaitingAuthentication,
    AwaitingHello,
    Bound {
        pi_session_id: String,
        stream: Option<StreamCursor>,
    },
}

/// The current event stream and its last sequence.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StreamCursor {
    pub stream_id: String,
    pub sequence: u64,
}

/// What an accepted record means for the caller.
#[derive(Debug, PartialEq)]
pub enum Step {
    Authenticated,
    /// The pane is verified; `pi_session_id` is Pi's own transcript ID.
    Bound {
        pi_session_id: String,
    },
    /// Pi's `/resume` asked for a saved Session; `None` when the request was malformed (the
    /// connection stays valid).
    ResumeRequested {
        target_session_file: Option<String>,
    },
    Event {
        pi_session_id: String,
        stream_id: String,
        sequence: u64,
        name: String,
        data: Value,
    },
    /// An event too large to forward. Its sequence still counts, so the stream stays in order;
    /// Pi's transcript on the Mac keeps it.
    Oversized {
        name: String,
        bytes: usize,
    },
}

/// Why a connection was rejected.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Rejection {
    /// A record that is not valid in this phase.
    Unexpected {
        phase: &'static str,
        record: &'static str,
    },
    IdentityMismatch(IdentityMatch),
    InvalidPiSessionId,
    InvalidStreamId,
    /// A second stream on one connection.
    StreamChanged,
    /// Not above the previous sequence, or beyond `MAX_SEQUENCE`.
    InvalidSequence,
    InvalidEventName,
}

/// Which identity fields matched; any `false` rejects the binding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IdentityMatch {
    pub session: bool,
    pub pane: bool,
    pub file: bool,
    pub process: bool,
    pub cwd: bool,
}

impl IdentityMatch {
    fn exact(self) -> bool {
        self.session && self.pane && self.file && self.process && self.cwd
    }
}

impl Phase {
    fn name(&self) -> &'static str {
        match self {
            Phase::AwaitingAuthentication => "awaiting_authentication",
            Phase::AwaitingHello => "awaiting_hello",
            Phase::Bound { .. } => "bound",
        }
    }
}

fn record_name(record: &Record) -> &'static str {
    match record {
        Record::Authenticated { .. } => "authenticated",
        Record::Hello { .. } => "hello",
        Record::Event { .. } => "event",
        Record::CommandResult { .. } => "commandResult",
        Record::ProtocolError { .. } => "protocolError",
    }
}

pub struct Connection<'a> {
    expected: ExpectedPane<'a>,
    phase: Phase,
}

impl<'a> Connection<'a> {
    pub fn new(expected: ExpectedPane<'a>) -> Self {
        Connection {
            expected,
            phase: Phase::AwaitingAuthentication,
        }
    }

    pub fn phase(&self) -> &Phase {
        &self.phase
    }

    pub fn is_bound(&self) -> bool {
        matches!(self.phase, Phase::Bound { .. })
    }

    /// Applies one record. On `Err` the connection must be dropped; its phase is unchanged.
    pub fn receive(&mut self, record: Record) -> Result<Step, Rejection> {
        match (&mut self.phase, record) {
            (Phase::AwaitingAuthentication, Record::Authenticated { .. }) => {
                self.phase = Phase::AwaitingHello;
                Ok(Step::Authenticated)
            }
            (Phase::AwaitingHello, Record::Hello { identity, .. }) => {
                let pi_session_id = self.verify(identity)?;
                self.phase = Phase::Bound {
                    pi_session_id: pi_session_id.clone(),
                    stream: None,
                };
                Ok(Step::Bound { pi_session_id })
            }
            (
                Phase::Bound {
                    pi_session_id,
                    stream,
                },
                Record::Event {
                    stream_id,
                    sequence,
                    name,
                    data,
                },
            ) => {
                let cursor = accept_event(stream.as_ref(), &stream_id, sequence, &name)?;
                *stream = Some(cursor);
                let bytes = serde_json::to_vec(&data).map_or(usize::MAX, |encoded| encoded.len());
                if bytes > MAX_EVENT_DATA_BYTES {
                    return Ok(Step::Oversized { name, bytes });
                }
                if name == RESUME_REQUESTED {
                    return Ok(Step::ResumeRequested {
                        target_session_file: resume_target(&data),
                    });
                }
                Ok(Step::Event {
                    pi_session_id: pi_session_id.clone(),
                    stream_id,
                    sequence,
                    name,
                    data,
                })
            }
            (phase, record) => Err(Rejection::Unexpected {
                phase: phase.name(),
                record: record_name(&record),
            }),
        }
    }

    fn verify(&self, identity: Identity) -> Result<String, Rejection> {
        let expected = &self.expected;
        let matched = IdentityMatch {
            session: identity.axo_session_id == expected.session_uuid,
            pane: identity.axo_pane_id == expected.pane_id,
            file: identity.session_file.as_deref() == Some(expected.session_file),
            process: identity.process_id == u64::from(expected.process_id),
            cwd: identity.cwd == expected.cwd,
        };
        let id = identity.pi_session_id;
        if id.is_empty() || id.len() > MAX_PI_SESSION_ID_BYTES {
            return Err(Rejection::InvalidPiSessionId);
        }
        if !matched.exact() {
            return Err(Rejection::IdentityMismatch(matched));
        }
        Ok(id)
    }
}

fn accept_event(
    stream: Option<&StreamCursor>,
    stream_id: &str,
    sequence: u64,
    name: &str,
) -> Result<StreamCursor, Rejection> {
    if !is_uuid(stream_id) {
        return Err(Rejection::InvalidStreamId);
    }
    if stream.is_some_and(|current| current.stream_id != stream_id) {
        return Err(Rejection::StreamChanged);
    }
    let previous = stream.map_or(0, |current| current.sequence);
    if sequence <= previous || sequence > MAX_SEQUENCE {
        return Err(Rejection::InvalidSequence);
    }
    if name.is_empty() || name.len() > MAX_NAME_BYTES || name.chars().any(char::is_control) {
        return Err(Rejection::InvalidEventName);
    }
    Ok(StreamCursor {
        stream_id: stream_id.to_owned(),
        sequence,
    })
}

/// `{targetSessionFile}` and nothing else.
fn resume_target(data: &Value) -> Option<String> {
    let object = data.as_object().filter(|object| object.len() == 1)?;
    object.get("targetSessionFile")?.as_str().map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{CommandResult, ProtocolVersion};
    use serde_json::json;
    use std::path::PathBuf;

    const SESSION: &str = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
    const PANE: &str = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f";
    const STREAM: &str = "0f00f22d-a24c-4cbc-9196-74dbed95ca80";
    const OTHER_STREAM: &str = "70fa4f38-71d9-42f8-9013-43b4fd688693";

    fn connection() -> Connection<'static> {
        Connection::new(ExpectedPane {
            session_uuid: SESSION,
            pane_id: PANE,
            session_file: Path::new("/sessions/a.jsonl"),
            cwd: Path::new("/work"),
            process_id: 42,
        })
    }

    fn identity() -> Identity {
        Identity {
            axo_session_id: SESSION.to_owned(),
            axo_pane_id: PANE.to_owned(),
            pi_session_id: "pi-1".to_owned(),
            session_file: Some(PathBuf::from("/sessions/a.jsonl")),
            cwd: PathBuf::from("/work"),
            process_id: 42,
        }
    }

    fn authenticated() -> Record {
        Record::Authenticated {
            protocol_version: ProtocolVersion,
        }
    }

    fn hello(identity: Identity) -> Record {
        Record::Hello {
            protocol_version: ProtocolVersion,
            identity,
        }
    }

    fn event(stream_id: &str, sequence: u64, name: &str, data: Value) -> Record {
        Record::Event {
            stream_id: stream_id.to_owned(),
            sequence,
            name: name.to_owned(),
            data,
        }
    }

    fn bound() -> Connection<'static> {
        let mut connection = connection();
        connection.receive(authenticated()).unwrap();
        connection.receive(hello(identity())).unwrap();
        connection
    }

    /// One record of every kind, to drive each phase through every input.
    fn every_record() -> Vec<Record> {
        vec![
            authenticated(),
            hello(identity()),
            event(STREAM, 1, "agent.start", Value::Null),
            Record::CommandResult {
                request_id: "r".to_owned(),
                result: CommandResult::Accepted,
            },
            Record::ProtocolError {
                message: "no".to_owned(),
            },
        ]
    }

    #[test]
    fn every_phase_accepts_exactly_its_record() {
        let accepted_by = |connection: fn() -> Connection<'static>| {
            every_record()
                .into_iter()
                .map(|record| {
                    let mut connection = connection();
                    let before = connection.phase().clone();
                    let result = connection.receive(record);
                    if result.is_err() {
                        assert_eq!(
                            connection.phase(),
                            &before,
                            "a rejection must not change the phase"
                        );
                    }
                    result.is_ok()
                })
                .collect::<Vec<_>>()
        };
        let awaiting_hello = || {
            let mut connection = connection();
            connection.receive(authenticated()).unwrap();
            connection
        };
        assert_eq!(accepted_by(connection), [true, false, false, false, false]);
        assert_eq!(
            accepted_by(awaiting_hello),
            [false, true, false, false, false]
        );
        assert_eq!(accepted_by(bound), [false, false, true, false, false]);
    }

    #[test]
    fn binding_requires_every_identity_field() {
        let mismatches: [fn(&mut Identity); 5] = [
            |identity| identity.axo_session_id = OTHER_STREAM.to_owned(),
            |identity| identity.axo_pane_id = OTHER_STREAM.to_owned(),
            |identity| identity.session_file = None,
            |identity| identity.process_id = 43,
            |identity| identity.cwd = PathBuf::from("/elsewhere"),
        ];
        for mismatch in mismatches {
            let mut connection = connection();
            connection.receive(authenticated()).unwrap();
            let mut identity = identity();
            mismatch(&mut identity);
            assert!(matches!(
                connection.receive(hello(identity)),
                Err(Rejection::IdentityMismatch(_))
            ));
        }
        for pi_session_id in [String::new(), "x".repeat(129)] {
            let mut connection = connection();
            connection.receive(authenticated()).unwrap();
            let identity = Identity {
                pi_session_id,
                ..identity()
            };
            assert_eq!(
                connection.receive(hello(identity)),
                Err(Rejection::InvalidPiSessionId)
            );
        }
        let mut connection = connection();
        connection.receive(authenticated()).unwrap();
        assert_eq!(
            connection.receive(hello(identity())),
            Ok(Step::Bound {
                pi_session_id: "pi-1".to_owned()
            })
        );
        assert!(connection.is_bound());
    }

    #[test]
    fn events_form_one_increasing_stream() {
        let mut connection = bound();
        assert!(matches!(
            connection.receive(event(STREAM, 1, "agent.start", json!({}))),
            Ok(Step::Event { sequence: 1, .. })
        ));
        assert_eq!(
            connection.receive(event(STREAM, 1, "agent.start", Value::Null)),
            Err(Rejection::InvalidSequence)
        );
        assert!(
            connection
                .receive(event(STREAM, 5, "agent.settled", Value::Null))
                .is_ok()
        );
        assert_eq!(
            connection.receive(event(OTHER_STREAM, 6, "agent.start", Value::Null)),
            Err(Rejection::StreamChanged)
        );
        assert_eq!(
            connection.receive(event(STREAM, MAX_SEQUENCE + 1, "agent.start", Value::Null)),
            Err(Rejection::InvalidSequence)
        );
        assert_eq!(
            connection.phase(),
            &Phase::Bound {
                pi_session_id: "pi-1".to_owned(),
                stream: Some(StreamCursor {
                    stream_id: STREAM.to_owned(),
                    sequence: 5
                })
            }
        );
    }

    #[test]
    fn events_are_bounded() {
        let mut connection = bound();
        assert_eq!(
            connection.receive(event("not-a-uuid", 1, "n", Value::Null)),
            Err(Rejection::InvalidStreamId)
        );
        for name in [String::new(), "n".repeat(129), "bad\nname".to_owned()] {
            assert_eq!(
                connection.receive(event(STREAM, 1, &name, Value::Null)),
                Err(Rejection::InvalidEventName)
            );
        }
        // Too large to forward: skipped, but the connection and the stream's order stay.
        assert_eq!(
            connection.receive(event(
                STREAM,
                1,
                "n",
                json!("x".repeat(MAX_EVENT_DATA_BYTES))
            )),
            Ok(Step::Oversized {
                name: "n".to_owned(),
                bytes: MAX_EVENT_DATA_BYTES + 2
            })
        );
        assert_eq!(
            connection.receive(event(STREAM, 1, "n", Value::Null)),
            Err(Rejection::InvalidSequence)
        );
        assert!(matches!(
            connection.receive(event(STREAM, 2, "n", Value::Null)),
            Ok(Step::Event { sequence: 2, .. })
        ));
    }

    #[test]
    fn resume_requests_are_separated_and_malformed_ones_keep_the_connection() {
        let mut connection = bound();
        assert_eq!(
            connection.receive(event(
                STREAM,
                1,
                RESUME_REQUESTED,
                json!({ "targetSessionFile": "/s/b.jsonl" })
            )),
            Ok(Step::ResumeRequested {
                target_session_file: Some("/s/b.jsonl".to_owned())
            })
        );
        for data in [
            json!({}),
            json!({ "targetSessionFile": 1 }),
            json!({ "targetSessionFile": "/x", "extra": 1 }),
        ] {
            assert_eq!(
                connection.receive(event(STREAM, 2, RESUME_REQUESTED, data)),
                Ok(Step::ResumeRequested {
                    target_session_file: None
                })
            );
            // Each accepted record advances the stream, malformed or not.
            connection = bound();
        }
    }
}
