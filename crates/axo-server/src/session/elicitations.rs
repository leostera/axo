//! Elicitations (RFD0029): what agents on this Mac ask the person, waiting for an answer.
//!
//! On `axod.sock`, `axo.elicitation.request` asks, as the agent, or as a tool only when the peer
//! is axod's own binary (`axod mcp`, by code signature). An answer comes through the relay
//! (`RelayHost::resolve_elicitation`), where the cloud takes it only from a signed-in person's
//! client, or as `axo.elicitation.resolve` on `axod.sock` from Axo.app alone, by code signature.
//! The first answer taken wins: it removes the elicitation, so any later one finds nothing.
//! Elicitations live in memory: when axod stops, the tool calls waiting on them end too.

use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axo_ipc::TypedMethods;
use axo_ipc::peer::{self, Signer};
use axo_protocol::elicitation::{
    Asker, BAD_INPUT, Elicitation, ElicitationAction, ElicitationAnswer, ElicitationKind,
    ElicitationOutcome, InputRequest, MAX_INPUT_CHARS, MAX_MESSAGE_CHARS, MAX_PENDING,
    NOT_A_PERSON, NOT_A_TOOL, NOT_PENDING, Pending as Listed, Reply, RequestElicitation,
    ResolveElicitation, Resolved, TIMEOUT_MS,
};
use axo_protocol::rpc::method;
use axo_protocol::{Event, SessionId, new_uuid_v4};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use serde_json::Value;
use std::sync::Arc;
use zeroize::Zeroizing;

use super::SessionManager;

/// Error codes shared with `@axo/protocol`'s `ELICITATION_ERRORS`, and the limit of the relay's.
pub const TOO_MANY: i64 = -32006;

/// An input request's values by field id, wiped when dropped.
pub(crate) type Values = std::collections::BTreeMap<String, Zeroizing<String>>;

/// How one ended, and the values for an accepted input request.
pub(crate) struct Settled {
    pub(crate) action: ElicitationAction,
    pub(crate) values: Option<Values>,
}

struct Pending {
    elicitation: Elicitation,
    answer: SyncSender<Settled>,
}

/// The elicitations waiting for an answer, by id.
#[derive(Default)]
pub(crate) struct Elicitations {
    pending: Mutex<HashMap<String, Pending>>,
}

impl Elicitations {
    fn lock(&self) -> io::Result<std::sync::MutexGuard<'_, HashMap<String, Pending>>> {
        self.pending
            .lock()
            .map_err(|_| io::Error::other("elicitation lock was poisoned"))
    }

    fn open(&self, elicitation: Elicitation) -> io::Result<Option<mpsc::Receiver<Settled>>> {
        let mut pending = self.lock()?;
        if pending.len() >= MAX_PENDING {
            return Ok(None);
        }
        let (answer, receiver) = mpsc::sync_channel(1);
        pending.insert(
            elicitation.id.clone(),
            Pending {
                elicitation,
                answer,
            },
        );
        Ok(Some(receiver))
    }

    /// Ends one with `action` if it still waits; whoever gets it first wins.
    fn settle(&self, id: &str, action: ElicitationAction) -> io::Result<Option<Elicitation>> {
        self.settle_with(
            id,
            Settled {
                action,
                values: None,
            },
        )
    }

    fn settle_with(&self, id: &str, settled: Settled) -> io::Result<Option<Elicitation>> {
        let Some(pending) = self.lock()?.remove(id) else {
            return Ok(None);
        };
        let _ = pending.answer.try_send(settled);
        Ok(Some(pending.elicitation))
    }

    fn get(&self, id: &str) -> Option<Elicitation> {
        self.lock()
            .ok()?
            .get(id)
            .map(|pending| pending.elicitation.clone())
    }

    pub(crate) fn pending(&self) -> Vec<Elicitation> {
        let Ok(pending) = self.lock() else {
            return Vec::new();
        };
        let mut listed: Vec<Elicitation> = pending
            .values()
            .map(|pending| pending.elicitation.clone())
            .collect();
        listed.sort_by_key(|elicitation| elicitation.created_at);
        listed
    }
}

impl SessionManager {
    /// Asks the person and waits for their answer, at most `timeout`. Ends as `Cancel` when nobody
    /// answers in time.
    pub(crate) fn request_elicitation(
        &self,
        request: RequestElicitation,
        timeout: Duration,
    ) -> Result<ElicitationOutcome, RpcError> {
        self.ensure_session(request.session_id)?;
        self.ask(
            request.session_id,
            &request.message,
            request.asked_by,
            timeout,
        )
    }

    /// Asks in `session_id`, which may run on another Mac: the gate asks in the Session of the
    /// script that called it (RFD0028). Clients place the card by Session id, and answer this Mac.
    pub(crate) fn ask(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        timeout: Duration,
    ) -> Result<ElicitationOutcome, RpcError> {
        self.ask_with(session_id, message, asked_by, None, timeout)
            .map(|(outcome, _)| outcome)
    }

    /// Asks, for a form when `input` is given, and waits; an accepted form comes with its values.
    pub(crate) fn ask_with(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<(ElicitationOutcome, Option<Values>), RpcError> {
        let message = message.trim();
        if message.is_empty() || message.chars().count() > MAX_MESSAGE_CHARS {
            return Err(invalid(format!(
                "message must be 1 to {MAX_MESSAGE_CHARS} characters"
            )));
        }
        let request = RequestElicitation {
            session_id,
            message: message.to_owned(),
            asked_by,
        };
        let now = unix_millis();
        let elicitation = Elicitation {
            id: new_uuid_v4().map_err(internal)?,
            session_id: request.session_id,
            kind: if input.is_some() {
                ElicitationKind::Input
            } else {
                ElicitationKind::Confirm
            },
            asked_by: request.asked_by,
            message: message.to_owned(),
            input,
            created_at: now,
            expires_at: now + timeout.as_millis() as u64,
        };
        let id = elicitation.id.clone();
        let Some(answer) = self
            .elicitations
            .open(elicitation.clone())
            .map_err(internal)?
        else {
            return Err(RpcError {
                code: ErrorCode::ServerError(TOO_MANY),
                message: format!(
                    "{MAX_PENDING} questions are already waiting for the person on this Mac"
                ),
                data: None,
            });
        };
        log::info!(
            "event=elicitation.requested id={id} kind={} asked_by={}",
            if elicitation.input.is_some() {
                "input"
            } else {
                "confirm"
            },
            match request.asked_by {
                Asker::Agent => "agent",
                Asker::ComputerUse => "computer_use",
            }
        );
        self.publish_event(Event::ElicitationRequested { elicitation });
        let cancelled = || Settled {
            action: ElicitationAction::Cancel,
            values: None,
        };
        let settled = match answer.recv_timeout(timeout) {
            Ok(settled) => settled,
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
                match self
                    .elicitations
                    .settle(&id, ElicitationAction::Cancel)
                    .map_err(internal)?
                {
                    Some(elicitation) => {
                        self.publish_resolved(&elicitation, ElicitationAction::Cancel);
                        cancelled()
                    }
                    // An answer won the race with the timeout: it is already sent.
                    None => answer.try_recv().unwrap_or_else(|_| cancelled()),
                }
            }
        };
        Ok((
            ElicitationOutcome {
                id,
                action: settled.action,
            },
            settled.values,
        ))
    }

    /// A person's answer, from the relay or Axo.app. `NOT_PENDING` when it no longer waits
    /// (answered already, expired, or never asked); `BAD_INPUT`, and it still waits, when an
    /// accepted form's values are missing, do not open, or do not fit its fields.
    pub(crate) fn resolve_elicitation(
        &self,
        id: &str,
        answer: ElicitationAnswer,
        reply: Reply,
    ) -> Result<(), (i64, String)> {
        let not_pending = || {
            (
                NOT_PENDING,
                "already answered, or no longer asked".to_owned(),
            )
        };
        let asked = self.elicitations.get(id).ok_or_else(not_pending)?;
        let action = ElicitationAction::from(answer);
        let values = match (&asked.input, action, reply) {
            (Some(input), ElicitationAction::Accept, reply) => {
                Some(self.input_values(id, input, reply)?)
            }
            (None, _, Reply::Sealed(_) | Reply::Values(_)) => {
                return Err((BAD_INPUT, "a yes-or-no answer carries no values".into()));
            }
            // A Decline needs nothing, and what came with it is dropped unread.
            _ => None,
        };
        match self
            .elicitations
            .settle_with(id, Settled { action, values })
        {
            Ok(Some(elicitation)) => {
                self.publish_resolved(&elicitation, action);
                Ok(())
            }
            _ => Err(not_pending()),
        }
    }

    /// An accepted form's values: opened with this Mac's input key when sealed, and exactly one
    /// for each field.
    fn input_values(
        &self,
        id: &str,
        input: &InputRequest,
        reply: Reply,
    ) -> Result<Values, (i64, String)> {
        let bad = |why: &str| (BAD_INPUT, why.to_owned());
        let values: Values = match reply {
            Reply::Bare => return Err(bad("an answer to a form carries its values")),
            Reply::Values(values) => values
                .into_iter()
                .map(|(field, value)| (field, Zeroizing::new(value)))
                .collect(),
            Reply::Sealed(sealed) => {
                let key = self
                    .input_key()
                    .ok_or_else(|| bad("this Mac has no input key"))?;
                let opened = key
                    .open(
                        &sealed.enc,
                        &sealed.ciphertext,
                        &axo_seal::aad(id, input.origin.as_deref()),
                    )
                    .map_err(|_| {
                        bad("the values did not open: sealed to another Mac, request or address")
                    })?;
                #[derive(serde::Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Opened {
                    values: std::collections::BTreeMap<String, String>,
                }
                let opened: Opened = serde_json::from_slice(&opened)
                    .map_err(|_| bad("the values are not {values}"))?;
                opened
                    .values
                    .into_iter()
                    .map(|(field, value)| (field, Zeroizing::new(value)))
                    .collect()
            }
        };
        let fits = values.len() == input.fields.len()
            && input
                .fields
                .iter()
                .all(|field| values.contains_key(&field.id))
            && values
                .values()
                .all(|value| value.chars().count() <= MAX_INPUT_CHARS);
        if fits {
            Ok(values)
        } else {
            Err(bad(
                "the values must be one per field, each at most 1000 characters",
            ))
        }
    }

    pub(crate) fn pending_elicitations(&self) -> Vec<Elicitation> {
        self.elicitations.pending()
    }

    fn publish_resolved(&self, elicitation: &Elicitation, action: ElicitationAction) {
        log::info!(
            "event=elicitation.resolved id={} outcome={}",
            elicitation.id,
            match action {
                ElicitationAction::Accept => "accept",
                ElicitationAction::Decline => "decline",
                ElicitationAction::Cancel => "cancel",
            }
        );
        self.publish_event(Event::ElicitationResolved {
            id: elicitation.id.clone(),
            session_id: elicitation.session_id,
            action,
        });
    }

    fn ensure_session(&self, session_id: SessionId) -> Result<(), RpcError> {
        let state = self.lock_state().map_err(internal)?;
        super::catalog::session_metadata(&state, session_id, &self.attach_socket_path)
            .map(drop)
            .map_err(|_| invalid(format!("no open Session {session_id}")))
    }
}

/// Registers `axo.elicitation.request`, and `axo.elicitation.resolve` for Axo.app alone.
pub(crate) fn add_methods(manager: &Arc<SessionManager>, handler: &mut IoHandler) {
    let asking = Arc::clone(manager);
    handler.add_typed(
        method::ELICITATION_REQUEST,
        "expected {sessionId, message, askedBy?}",
        move |request: RequestElicitation| {
            if request.asked_by != Asker::Agent && !peer::current().is(Signer::ThisBinary) {
                log::warn!("event=elicitation.refused reason=not_a_tool");
                return Err(server_error(
                    NOT_A_TOOL,
                    "only Axo's own tools ask as a tool; ask as the agent",
                ));
            }
            asking.request_elicitation(request, Duration::from_millis(TIMEOUT_MS))
        },
    );
    let listing = Arc::clone(manager);
    handler.add_typed(
        method::ELICITATION_LIST,
        "expected no parameters",
        move |_: Value| {
            Ok(Listed {
                elicitations: listing.pending_elicitations(),
            })
        },
    );
    let answering = Arc::clone(manager);
    handler.add_typed(
        method::ELICITATION_RESOLVE,
        "expected {elicitationId, action}",
        move |request: ResolveElicitation| {
            if !peer::current().is(Signer::AxoApp) {
                log::warn!("event=elicitation.refused reason=not_axo_app");
                return Err(server_error(
                    NOT_A_PERSON,
                    "only the person answers: on this Mac, from Axo.app",
                ));
            }
            let reply = request.values.map_or(Reply::Bare, Reply::Values);
            answering
                .resolve_elicitation(&request.elicitation_id, request.action, reply)
                .map(|()| Resolved { resolved: true })
                .map_err(|(code, message)| server_error(code, &message))
        },
    );
}

fn server_error(code: i64, message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::ServerError(code),
        message: message.to_owned(),
        data: None,
    }
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default()
}

fn invalid(message: String) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message,
        data: None,
    }
}

fn internal(error: io::Error) -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
        message: error.to_string(),
        data: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn elicitation(id: &str) -> Elicitation {
        Elicitation {
            id: id.into(),
            session_id: SessionId::from_u128(1),
            kind: ElicitationKind::Confirm,
            asked_by: Asker::Agent,
            message: "Go?".into(),
            input: None,
            created_at: 1,
            expires_at: 2,
        }
    }

    #[test]
    fn the_first_answer_wins_and_later_ones_find_nothing() {
        let elicitations = Elicitations::default();
        let answer = elicitations.open(elicitation("a")).unwrap().unwrap();
        assert_eq!(elicitations.pending().len(), 1);
        assert!(
            elicitations
                .settle("a", ElicitationAction::Decline)
                .unwrap()
                .is_some()
        );
        assert!(
            elicitations
                .settle("a", ElicitationAction::Accept)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            answer.try_recv().unwrap().action,
            ElicitationAction::Decline
        );
        assert!(answer.try_recv().is_err());
        assert!(elicitations.pending().is_empty());
    }

    /// An accepted form's values reach the asker only when they open with this Mac's key, for
    /// that request and address, one per field; a bad answer leaves the question waiting.
    #[test]
    fn a_form_s_values_open_only_for_its_request_and_address() {
        use axo_protocol::elicitation::{InputField, InputFieldKind, Sealed};
        let directory =
            std::path::PathBuf::from("/tmp").join(format!("axo-input-{}", new_uuid_v4().unwrap()));
        std::fs::create_dir_all(&directory).unwrap();
        let manager = super::super::test_support::open_with_silent_shell(&directory);
        manager.keep_input_key_in(Arc::new(axo_relay::credential::FileCredentialStore::new(
            directory.join("keys"),
        )));
        let key = manager.input_key().unwrap().public_key();
        assert_eq!(
            manager.input_key().unwrap().public_key(),
            key,
            "the key is made once"
        );
        let input = InputRequest {
            app: "Safari".into(),
            window: "Sign in".into(),
            origin: Some("https://github.com".into()),
            fields: vec![InputField {
                id: "f0".into(),
                label: "Password".into(),
                kind: InputFieldKind::Password,
            }],
            submit: None,
            key: key.clone(),
        };
        let asking = Arc::clone(&manager);
        let asked = std::thread::spawn(move || {
            asking.ask_with(
                SessionId::from_u128(9),
                "Fill Password in Safari.",
                Asker::ComputerUse,
                Some(input),
                Duration::from_secs(10),
            )
        });
        let id = loop {
            if let Some(pending) = manager.pending_elicitations().first() {
                break pending.id.clone();
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let sealed = |request: &str, origin: &str, plaintext: &str| {
            let (enc, ciphertext) = axo_seal::seal(
                &key,
                plaintext.as_bytes(),
                &axo_seal::aad(request, Some(origin)),
            )
            .unwrap();
            Reply::Sealed(Sealed { enc, ciphertext })
        };
        let good = r#"{"values":{"f0":"hunter2"}}"#;
        let code = |result: Result<(), (i64, String)>| result.unwrap_err().0;
        assert_eq!(
            code(manager.resolve_elicitation(&id, ElicitationAnswer::Accept, Reply::Bare)),
            BAD_INPUT
        );
        assert_eq!(
            code(manager.resolve_elicitation(
                &id,
                ElicitationAnswer::Accept,
                sealed("another", "https://github.com", good)
            )),
            BAD_INPUT
        );
        assert_eq!(
            code(manager.resolve_elicitation(
                &id,
                ElicitationAnswer::Accept,
                sealed(&id, "https://github.co", good)
            )),
            BAD_INPUT
        );
        assert_eq!(
            code(manager.resolve_elicitation(
                &id,
                ElicitationAnswer::Accept,
                sealed(&id, "https://github.com", r#"{"values":{"f1":"x"}}"#)
            )),
            BAD_INPUT
        );
        manager
            .resolve_elicitation(
                &id,
                ElicitationAnswer::Accept,
                sealed(&id, "https://github.com", good),
            )
            .unwrap();
        let (outcome, values) = asked.join().unwrap().unwrap();
        assert_eq!(outcome.action, ElicitationAction::Accept);
        assert_eq!(values.unwrap()["f0"].as_str(), "hunter2");
        assert_eq!(
            code(manager.resolve_elicitation(&id, ElicitationAnswer::Accept, Reply::Bare)),
            NOT_PENDING
        );
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_yes_or_no_carries_no_values() {
        let directory = std::path::PathBuf::from("/tmp")
            .join(format!("axo-confirm-{}", new_uuid_v4().unwrap()));
        std::fs::create_dir_all(&directory).unwrap();
        let manager = super::super::test_support::open_with_silent_shell(&directory);
        let asking = Arc::clone(&manager);
        let asked = std::thread::spawn(move || {
            asking.ask(
                SessionId::from_u128(9),
                "Go?",
                Asker::Agent,
                Duration::from_secs(10),
            )
        });
        let id = loop {
            if let Some(pending) = manager.pending_elicitations().first() {
                break pending.id.clone();
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let values = Reply::Values([("f0".to_owned(), "x".to_owned())].into());
        assert_eq!(
            manager
                .resolve_elicitation(&id, ElicitationAnswer::Accept, values)
                .unwrap_err()
                .0,
            BAD_INPUT
        );
        manager
            .resolve_elicitation(&id, ElicitationAnswer::Decline, Reply::Bare)
            .unwrap();
        assert_eq!(
            asked.join().unwrap().unwrap().action,
            ElicitationAction::Decline
        );
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn only_so_many_wait_at_once() {
        let elicitations = Elicitations::default();
        let mut waiting = Vec::new();
        for index in 0..MAX_PENDING {
            waiting.push(
                elicitations
                    .open(elicitation(&index.to_string()))
                    .unwrap()
                    .unwrap(),
            );
        }
        assert!(
            elicitations
                .open(elicitation("one more"))
                .unwrap()
                .is_none()
        );
    }
}
