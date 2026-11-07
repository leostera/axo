//! The questions extension (RFD0029, RFD0034): what agents on this Mac ask the person, waiting
//! for an answer. axod's elicitations.
//!
//! On `axod.sock`, `axo.elicitation.request` asks, as the agent, or as a tool only when the peer
//! is axod's own binary (`axod mcp`, by code signature). An answer comes through the relay
//! (`RelayHost::resolve_elicitation`), where the cloud takes it only from a signed-in person's
//! client, or as `axo.elicitation.resolve` on `axod.sock` from Axo.app alone, by code signature.
//! The first answer taken wins: it removes the elicitation, so any later one finds nothing.
//! Elicitations live in memory: when axod stops, the tool calls waiting on them end too.
//!
//! The rest of axod is a [`QuestionsHost`]: which Sessions are open, where events go, and this
//! Mac's input key. It passes itself to each call, so nothing here holds on to it.

use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axo_ipc::Extension;
use axo_ipc::peer::Signer;
use axo_ipc::{Only, TypedMethods};
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

/// What the questions need of the rest of axod.
pub trait QuestionsHost: Send + Sync {
    /// Whether `session` is open on this Mac.
    fn has_session(&self, session: SessionId) -> bool;
    /// Tells every client and the relay.
    fn publish(&self, event: Event);
    /// This Mac's input key, which forms are sealed to; made on first use.
    fn input_key(&self) -> Option<&axo_seal::InputKey>;
}

/// Error codes shared with `@axo/protocol`'s `ELICITATION_ERRORS`, and the limit of the relay's.
pub const TOO_MANY: i64 = -32006;

/// An input request's values by field id, wiped when dropped.
pub type Values = std::collections::BTreeMap<String, Zeroizing<String>>;

/// How one ended, and the values for an accepted input request.
struct Settled {
    action: ElicitationAction,
    values: Option<Values>,
}

/// What wakes a question's waiter: how it was settled, or its asker giving up.
enum Wake {
    Settled(Settled),
    /// The request that asked was cancelled (RFD0034): its connection closed.
    Cancelled,
}

struct Pending {
    elicitation: Elicitation,
    /// Holds two: an answer can race the asker giving up, and neither is lost.
    answer: SyncSender<Wake>,
}

/// The elicitations waiting for an answer, by id.
#[derive(Default)]
struct Elicitations {
    pending: Mutex<HashMap<String, Pending>>,
}

impl Elicitations {
    fn lock(&self) -> io::Result<std::sync::MutexGuard<'_, HashMap<String, Pending>>> {
        self.pending
            .lock()
            .map_err(|_| io::Error::other("elicitation lock was poisoned"))
    }

    /// Opens one; its waiter's receiver, and a sender to wake it when its asker gives up.
    fn open(
        &self,
        elicitation: Elicitation,
    ) -> io::Result<Option<(mpsc::Receiver<Wake>, SyncSender<Wake>)>> {
        let mut pending = self.lock()?;
        if pending.len() >= MAX_PENDING {
            return Ok(None);
        }
        let (answer, receiver) = mpsc::sync_channel(2);
        pending.insert(
            elicitation.id.clone(),
            Pending {
                elicitation,
                answer: answer.clone(),
            },
        );
        Ok(Some((receiver, answer)))
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
        let _ = pending.answer.try_send(Wake::Settled(settled));
        Ok(Some(pending.elicitation))
    }

    fn get(&self, id: &str) -> Option<Elicitation> {
        self.lock()
            .ok()?
            .get(id)
            .map(|pending| pending.elicitation.clone())
    }

    fn pending(&self) -> Vec<Elicitation> {
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

/// The questions waiting on this Mac.
#[derive(Default)]
pub struct Questions {
    pending: Elicitations,
}

impl Questions {
    /// Asks the person and waits for their answer, at most `timeout`. Ends as `Cancel` when nobody
    /// answers in time.
    pub fn request(
        &self,
        host: &dyn QuestionsHost,
        request: RequestElicitation,
        timeout: Duration,
    ) -> Result<ElicitationOutcome, RpcError> {
        if !host.has_session(request.session_id) {
            return Err(invalid(format!("no open Session {}", request.session_id)));
        }
        self.ask(
            host,
            request.session_id,
            &request.message,
            request.asked_by,
            timeout,
        )
    }

    /// Asks in `session_id`, which may run on another Mac: the gate asks in the Session of the
    /// script that called it (RFD0028). Clients place the card by Session id, and answer this Mac.
    pub fn ask(
        &self,
        host: &dyn QuestionsHost,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        timeout: Duration,
    ) -> Result<ElicitationOutcome, RpcError> {
        self.ask_with(host, session_id, message, asked_by, None, timeout)
            .map(|(outcome, _)| outcome)
    }

    /// Asks, for a form when `input` is given, and waits; an accepted form comes with its values.
    pub fn ask_with(
        &self,
        host: &dyn QuestionsHost,
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
        // The asker gave up before its question was asked: nobody sees it (RFD0034).
        let cancellation = axo_ipc::cancel::current();
        if cancellation.is_cancelled() {
            log::info!("event=elicitation.withdrawn id={id} reason=asker_gone before=asked");
            return Ok((
                ElicitationOutcome {
                    id,
                    action: ElicitationAction::Cancel,
                },
                None,
            ));
        }
        let Some((answer, waker)) = self.pending.open(elicitation.clone()).map_err(internal)?
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
        host.publish(Event::ElicitationRequested { elicitation });
        // When the asker gives up (its connection closes), the question is withdrawn.
        cancellation.on_cancel(move || {
            let _ = waker.try_send(Wake::Cancelled);
        });
        let cancelled = || Settled {
            action: ElicitationAction::Cancel,
            values: None,
        };
        enum Ended {
            Settled(Settled),
            /// Nobody answered in time, or the asker gave up: why, for the log.
            Withdrawn(&'static str),
        }
        let ended = match answer.recv_timeout(timeout) {
            Ok(Wake::Settled(settled)) => Ended::Settled(settled),
            Ok(Wake::Cancelled) => Ended::Withdrawn("asker_gone"),
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
                Ended::Withdrawn("expired")
            }
        };
        let settled = match ended {
            Ended::Settled(settled) => settled,
            Ended::Withdrawn(reason) => {
                match self
                    .pending
                    .settle(&id, ElicitationAction::Cancel)
                    .map_err(internal)?
                {
                    Some(elicitation) => {
                        log::info!("event=elicitation.withdrawn id={id} reason={reason}");
                        publish_resolved(host, &elicitation, ElicitationAction::Cancel);
                        cancelled()
                    }
                    // An answer won the race: it is already in the channel.
                    None => std::iter::from_fn(|| answer.try_recv().ok())
                        .find_map(|wake| match wake {
                            Wake::Settled(settled) => Some(settled),
                            Wake::Cancelled => None,
                        })
                        .unwrap_or_else(cancelled),
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
    pub fn resolve(
        &self,
        host: &dyn QuestionsHost,
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
        let asked = self.pending.get(id).ok_or_else(not_pending)?;
        let action = ElicitationAction::from(answer);
        let values = match (&asked.input, action, reply) {
            (Some(input), ElicitationAction::Accept, reply) => {
                Some(input_values(host, id, input, reply)?)
            }
            (None, _, Reply::Sealed(_) | Reply::Values(_)) => {
                return Err((BAD_INPUT, "a yes-or-no answer carries no values".into()));
            }
            // A Decline needs nothing, and what came with it is dropped unread.
            _ => None,
        };
        match self.pending.settle_with(id, Settled { action, values }) {
            Ok(Some(elicitation)) => {
                publish_resolved(host, &elicitation, action);
                Ok(())
            }
            _ => Err(not_pending()),
        }
    }

    /// The questions waiting, oldest first.
    pub fn pending(&self) -> Vec<Elicitation> {
        self.pending.pending()
    }
}

/// An accepted form's values: opened with this Mac's input key when sealed, and exactly one
/// for each field.
fn input_values(
    host: &dyn QuestionsHost,
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
            let key = host
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
            let opened: Opened =
                serde_json::from_slice(&opened).map_err(|_| bad("the values are not {values}"))?;
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

fn publish_resolved(
    host: &dyn QuestionsHost,
    elicitation: &Elicitation,
    action: ElicitationAction,
) {
    log::info!(
        "event=elicitation.resolved id={} outcome={}",
        elicitation.id,
        match action {
            ElicitationAction::Accept => "accept",
            ElicitationAction::Decline => "decline",
            ElicitationAction::Cancel => "cancel",
        }
    );
    host.publish(Event::ElicitationResolved {
        id: elicitation.id.clone(),
        session_id: elicitation.session_id,
        action,
    });
}

/// `axo.elicitation.request`, `.list`, and `.resolve` for Axo.app alone.
pub struct QuestionsExtension {
    questions: Arc<Questions>,
    host: Arc<dyn QuestionsHost>,
}

impl QuestionsExtension {
    pub fn new(questions: Arc<Questions>, host: Arc<dyn QuestionsHost>) -> Self {
        Self { questions, host }
    }
}

impl Extension for QuestionsExtension {
    fn name(&self) -> &'static str {
        "questions"
    }

    fn register(&self, handler: &mut IoHandler) {
        let (questions, host) = (Arc::clone(&self.questions), Arc::clone(&self.host));
        handler.add_typed(
            method::ELICITATION_REQUEST,
            "expected {sessionId, message, askedBy?}",
            move |request: RequestElicitation| {
                // Anyone may ask as the agent; only axod's own tools ask as a tool.
                if request.asked_by != Asker::Agent {
                    Only {
                        signer: Signer::ThisBinary,
                        code: NOT_A_TOOL,
                        message: "only Axo's own tools ask as a tool; ask as the agent",
                    }
                    .admit(method::ELICITATION_REQUEST)?;
                }
                questions.request(host.as_ref(), request, Duration::from_millis(TIMEOUT_MS))
            },
        );
        let listing = Arc::clone(&self.questions);
        handler.add_typed(
            method::ELICITATION_LIST,
            "expected no parameters",
            move |_: Value| {
                Ok(Listed {
                    elicitations: listing.pending(),
                })
            },
        );
        let (answering, host) = (Arc::clone(&self.questions), Arc::clone(&self.host));
        handler.add_typed_only(
            Only {
                signer: Signer::AxoApp,
                code: NOT_A_PERSON,
                message: "only the person answers: on this Mac, from Axo.app",
            },
            method::ELICITATION_RESOLVE,
            "expected {elicitationId, action}",
            move |request: ResolveElicitation| {
                let reply = request.values.map_or(Reply::Bare, Reply::Values);
                answering
                    .resolve(
                        host.as_ref(),
                        &request.elicitation_id,
                        request.action,
                        reply,
                    )
                    .map(|()| Resolved { resolved: true })
                    .map_err(|(code, message)| server_error(code, &message))
            },
        );
    }
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

    /// The rest of axod, as far as questions see it: every Session is open, events are kept,
    /// and the key is made once.
    #[derive(Default)]
    struct Host {
        key: std::sync::OnceLock<axo_seal::InputKey>,
        events: Mutex<Vec<Event>>,
    }

    impl QuestionsHost for Host {
        fn has_session(&self, _: SessionId) -> bool {
            true
        }
        fn publish(&self, event: Event) {
            self.events.lock().unwrap().push(event);
        }
        fn input_key(&self) -> Option<&axo_seal::InputKey> {
            Some(self.key.get_or_init(axo_seal::InputKey::generate))
        }
    }

    /// Questions and their host, shared with the thread that asks.
    fn asking() -> Arc<(Questions, Host)> {
        Arc::new((Questions::default(), Host::default()))
    }

    fn first_pending(questions: &Questions) -> String {
        loop {
            if let Some(pending) = questions.pending().first() {
                break pending.id.clone();
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

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
        let (answer, _waker) = elicitations.open(elicitation("a")).unwrap().unwrap();
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
        let Ok(Wake::Settled(settled)) = answer.try_recv() else {
            panic!("the first answer wakes the asker");
        };
        assert_eq!(settled.action, ElicitationAction::Decline);
        assert!(answer.try_recv().is_err());
        assert!(elicitations.pending().is_empty());
    }

    /// An accepted form's values reach the asker only when they open with this Mac's key, for
    /// that request and address, one per field; a bad answer leaves the question waiting.
    #[test]
    fn a_form_s_values_open_only_for_its_request_and_address() {
        use axo_protocol::elicitation::{InputField, InputFieldKind, Sealed};
        let shared = asking();
        let (questions, host) = (&shared.0, &shared.1);
        let key = host.input_key().unwrap().public_key();
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
        let asking = Arc::clone(&shared);
        let asked = std::thread::spawn(move || {
            asking.0.ask_with(
                &asking.1,
                SessionId::from_u128(9),
                "Fill Password in Safari.",
                Asker::ComputerUse,
                Some(input),
                Duration::from_secs(10),
            )
        });
        let id = first_pending(questions);
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
            code(questions.resolve(host, &id, ElicitationAnswer::Accept, Reply::Bare)),
            BAD_INPUT
        );
        assert_eq!(
            code(questions.resolve(
                host,
                &id,
                ElicitationAnswer::Accept,
                sealed("another", "https://github.com", good)
            )),
            BAD_INPUT
        );
        assert_eq!(
            code(questions.resolve(
                host,
                &id,
                ElicitationAnswer::Accept,
                sealed(&id, "https://github.co", good)
            )),
            BAD_INPUT
        );
        assert_eq!(
            code(questions.resolve(
                host,
                &id,
                ElicitationAnswer::Accept,
                sealed(&id, "https://github.com", r#"{"values":{"f1":"x"}}"#)
            )),
            BAD_INPUT
        );
        questions
            .resolve(
                host,
                &id,
                ElicitationAnswer::Accept,
                sealed(&id, "https://github.com", good),
            )
            .unwrap();
        let (outcome, values) = asked.join().unwrap().unwrap();
        assert_eq!(outcome.action, ElicitationAction::Accept);
        assert_eq!(values.unwrap()["f0"].as_str(), "hunter2");
        let events = host.events.lock().unwrap();
        assert!(
            matches!(
                events.last(),
                Some(Event::ElicitationResolved {
                    action: ElicitationAction::Accept,
                    ..
                })
            ),
            "every client is told it was answered"
        );
        drop(events);
        assert_eq!(
            code(questions.resolve(host, &id, ElicitationAnswer::Accept, Reply::Bare)),
            NOT_PENDING
        );
    }

    #[test]
    fn a_yes_or_no_carries_no_values() {
        let shared = asking();
        let (questions, host) = (&shared.0, &shared.1);
        let asking = Arc::clone(&shared);
        let asked = std::thread::spawn(move || {
            asking.0.ask(
                &asking.1,
                SessionId::from_u128(9),
                "Go?",
                Asker::Agent,
                Duration::from_secs(10),
            )
        });
        let id = first_pending(questions);
        let values = Reply::Values([("f0".to_owned(), "x".to_owned())].into());
        assert_eq!(
            questions
                .resolve(host, &id, ElicitationAnswer::Accept, values)
                .unwrap_err()
                .0,
            BAD_INPUT
        );
        questions
            .resolve(host, &id, ElicitationAnswer::Decline, Reply::Bare)
            .unwrap();
        assert_eq!(
            asked.join().unwrap().unwrap().action,
            ElicitationAction::Decline
        );
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
