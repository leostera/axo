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
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axo_ipc::Extension;
use axo_ipc::peer::{Caller, Signer};
use axo_ipc::{Only, TypedMethods};
use axo_protocol::elicitation::{
    Asker, BAD_INPUT, Elicitation, ElicitationAction, ElicitationAnswer, ElicitationKind,
    ElicitationOutcome, InputRequest, MAX_INPUT_CHARS, MAX_MESSAGE_CHARS, MAX_PENDING,
    NOT_A_PERSON, NOT_A_TOOL, NOT_PENDING, Pending as Listed, Reply, RequestElicitation,
    ResolveElicitation, Resolved, TIMEOUT_MS,
};
use axo_protocol::rpc::{MethodError, method};
use axo_protocol::{Event, SessionId, new_uuid_v4};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::oneshot;
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

impl Settled {
    fn cancelled() -> Self {
        Self {
            action: ElicitationAction::Cancel,
            values: None,
        }
    }
}

/// The person's answer to a question: how it ended, and an accepted form's values.
pub struct Answer {
    pub outcome: ElicitationOutcome,
    pub values: Option<Values>,
}

struct Pending {
    elicitation: Elicitation,
    /// Wakes the asker with how it was settled; whoever settles it first sends it.
    answer: oneshot::Sender<Settled>,
}

/// The elicitations waiting for an answer, by id. Each change is one insert or remove, so the
/// map is never half-written: a panic elsewhere while it was locked leaves it usable, and
/// questions keep being asked, answered and withdrawn.
#[derive(Default)]
struct Elicitations {
    pending: Mutex<HashMap<String, Pending>>,
}

impl Elicitations {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Pending>> {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Opens one, and what its asker waits on; `None` when too many wait already.
    fn open(&self, elicitation: Elicitation) -> Option<oneshot::Receiver<Settled>> {
        let mut pending = self.lock();
        if pending.len() >= MAX_PENDING {
            return None;
        }
        let (answer, settled) = oneshot::channel();
        pending.insert(
            elicitation.id.clone(),
            Pending {
                elicitation,
                answer,
            },
        );
        Some(settled)
    }

    /// Ends one with `action` if it still waits; whoever gets it first wins.
    fn settle(&self, id: &str, action: ElicitationAction) -> Option<Elicitation> {
        self.settle_with(
            id,
            Settled {
                action,
                values: None,
            },
        )
    }

    fn settle_with(&self, id: &str, settled: Settled) -> Option<Elicitation> {
        let pending = self.lock().remove(id)?;
        let _ = pending.answer.send(settled);
        Some(pending.elicitation)
    }

    fn get(&self, id: &str) -> Option<Elicitation> {
        self.lock()
            .get(id)
            .map(|pending| pending.elicitation.clone())
    }

    fn pending(&self) -> Vec<Elicitation> {
        let pending = self.lock();
        let mut listed: Vec<Elicitation> = pending
            .values()
            .map(|pending| pending.elicitation.clone())
            .collect();
        listed.sort_by_key(|elicitation| elicitation.created_at);
        listed
    }
}

impl Answer {
    fn to(id: String, settled: Settled) -> Self {
        Self {
            outcome: ElicitationOutcome {
                id,
                action: settled.action,
            },
            values: settled.values,
        }
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
    pub async fn request(
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
        .await
    }

    /// Asks in `session_id`, which may run on another Mac: the gate asks in the Session of the
    /// script that called it (RFD0028). Clients place the card by Session id, and answer this Mac.
    pub async fn ask(
        &self,
        host: &dyn QuestionsHost,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        timeout: Duration,
    ) -> Result<ElicitationOutcome, RpcError> {
        self.ask_with(host, session_id, message, asked_by, None, timeout)
            .await
            .map(|answer| answer.outcome)
    }

    /// Asks, for a form when `input` is given, and waits; an accepted form comes with its values.
    pub async fn ask_with(
        &self,
        host: &dyn QuestionsHost,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<Answer, RpcError> {
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
            return Ok(Answer::to(id, Settled::cancelled()));
        }
        let Some(mut answer) = self.pending.open(elicitation.clone()) else {
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
        let _withdraw_on_drop = PendingQuestion {
            pending: &self.pending,
            host,
            id: id.clone(),
        };
        host.publish(Event::ElicitationRequested { elicitation });
        // Nobody answered in time, or the asker gave up (its connection closed): withdrawn.
        let withdrawn = tokio::select! {
            settled = &mut answer => match settled {
                Ok(settled) => return Ok(Answer::to(id, settled)),
                Err(_) => "expired",
            },
            () = tokio::time::sleep(timeout) => "expired",
            () = cancellation.cancelled() => "asker_gone",
        };
        let settled = match self.pending.settle(&id, ElicitationAction::Cancel) {
            Some(elicitation) => {
                log::info!("event=elicitation.withdrawn id={id} reason={withdrawn}");
                publish_resolved(host, &elicitation, ElicitationAction::Cancel);
                Settled::cancelled()
            }
            // An answer won the race: it is already sent.
            None => answer.try_recv().unwrap_or_else(|_| Settled::cancelled()),
        };
        Ok(Answer::to(id, settled))
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
    ) -> Result<(), MethodError> {
        let not_pending = || MethodError::new(NOT_PENDING, "already answered, or no longer asked");
        let asked = self.pending.get(id).ok_or_else(not_pending)?;
        let action = ElicitationAction::from(answer);
        let values = match (&asked.input, action, reply) {
            (Some(input), ElicitationAction::Accept, reply) => {
                Some(input_values(host, id, input, reply)?)
            }
            (None, _, Reply::Sealed(_) | Reply::Values(_)) => {
                return Err(MethodError::new(
                    BAD_INPUT,
                    "a yes-or-no answer carries no values",
                ));
            }
            // A Decline needs nothing, and what came with it is dropped unread.
            _ => None,
        };
        let elicitation = self
            .pending
            .settle_with(id, Settled { action, values })
            .ok_or_else(not_pending)?;
        publish_resolved(host, &elicitation, action);
        Ok(())
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
) -> Result<Values, MethodError> {
    let bad = |why: &str| MethodError::new(BAD_INPUT, why);
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
                .open(&sealed, &axo_seal::aad(id, input.origin.as_deref()))
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

/// A question belongs to its waiting future. Dropping that future (for example when an MCP
/// agent exits) withdraws it even if it never gets polled to observe cancellation. Settlement
/// removes it first, so an answered or expired question is never published twice.
struct PendingQuestion<'a> {
    pending: &'a Elicitations,
    host: &'a dyn QuestionsHost,
    id: String,
}

impl Drop for PendingQuestion<'_> {
    fn drop(&mut self) {
        if let Some(elicitation) = self.pending.settle(&self.id, ElicitationAction::Cancel) {
            publish_resolved(self.host, &elicitation, ElicitationAction::Cancel);
        }
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
                let (questions, host) = (Arc::clone(&questions), Arc::clone(&host));
                async move {
                    // Anyone may ask as the agent; only axod's own tools ask as a tool.
                    if request.asked_by != Asker::Agent {
                        Only {
                            caller: Caller::Signed(Signer::ThisBinary),
                            code: NOT_A_TOOL,
                            message: "only Axo's own tools ask as a tool; ask as the agent",
                        }
                        .admit(method::ELICITATION_REQUEST)?;
                    }
                    questions
                        .request(host.as_ref(), request, Duration::from_millis(TIMEOUT_MS))
                        .await
                }
            },
        );
        let listing = Arc::clone(&self.questions);
        handler.add_typed(
            method::ELICITATION_LIST,
            "expected no parameters",
            move |_: Value| {
                std::future::ready(Ok(Listed {
                    elicitations: listing.pending(),
                }))
            },
        );
        let (answering, host) = (Arc::clone(&self.questions), Arc::clone(&self.host));
        handler.add_typed_only(
            Only {
                caller: Caller::Signed(Signer::AxoApp),
                code: NOT_A_PERSON,
                message: "only the person answers: on this Mac, from Axo.app",
            },
            method::ELICITATION_RESOLVE,
            "expected {elicitationId, action}",
            move |request: ResolveElicitation| {
                let answering = Arc::clone(&answering);
                let host = Arc::clone(&host);
                async move {
                    let reply = request.values.map_or(Reply::Bare, Reply::Values);
                    answering
                        .resolve(
                            host.as_ref(),
                            &request.elicitation_id,
                            request.action,
                            reply,
                        )
                        .map(|()| Resolved { resolved: true })
                        .map_err(axo_ipc::rpc_error)
                }
            },
        );
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

    async fn first_pending(questions: &Questions) -> String {
        loop {
            if let Some(pending) = questions.pending().first() {
                break pending.id.clone();
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
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
    fn a_panic_while_the_questions_were_locked_does_not_stop_them() {
        let elicitations = std::sync::Arc::new(Elicitations::default());
        let mut answer = elicitations.open(elicitation("a")).unwrap();
        let poisoning = std::sync::Arc::clone(&elicitations);
        let _ = std::thread::spawn(move || {
            let _held = poisoning.pending.lock().unwrap();
            panic!("poisons the lock");
        })
        .join();
        assert!(elicitations.pending.is_poisoned());
        assert_eq!(elicitations.pending().len(), 1, "still listed");
        assert!(
            elicitations
                .settle("a", ElicitationAction::Accept)
                .is_some()
        );
        assert!(answer.try_recv().is_ok(), "and still answered");
    }

    #[test]
    fn the_first_answer_wins_and_later_ones_find_nothing() {
        let elicitations = Elicitations::default();
        let mut answer = elicitations.open(elicitation("a")).unwrap();
        assert_eq!(elicitations.pending().len(), 1);
        assert!(
            elicitations
                .settle("a", ElicitationAction::Decline)
                .is_some()
        );
        assert!(
            elicitations
                .settle("a", ElicitationAction::Accept)
                .is_none()
        );
        let Ok(settled) = answer.try_recv() else {
            panic!("the first answer wakes the asker");
        };
        assert_eq!(settled.action, ElicitationAction::Decline);
        assert!(elicitations.pending().is_empty());
    }

    /// An accepted form's values reach the asker only when they open with this Mac's key, for
    /// that request and address, one per field; a bad answer leaves the question waiting.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_form_s_values_open_only_for_its_request_and_address() {
        use axo_protocol::elicitation::{InputField, InputFieldKind};
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
        let asked = tokio::spawn(async move {
            asking
                .0
                .ask_with(
                    &asking.1,
                    SessionId::from_u128(9),
                    "Fill Password in Safari.",
                    Asker::ComputerUse,
                    Some(input),
                    Duration::from_secs(10),
                )
                .await
        });
        let id = first_pending(questions).await;
        let sealed = |request: &str, origin: &str, plaintext: &str| {
            Reply::Sealed(
                axo_seal::seal(
                    &key,
                    plaintext.as_bytes(),
                    &axo_seal::aad(request, Some(origin)),
                )
                .unwrap(),
            )
        };
        let good = r#"{"values":{"f0":"hunter2"}}"#;
        let code = |result: Result<(), MethodError>| result.unwrap_err().code;
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
        let answer = asked.await.unwrap().unwrap();
        assert_eq!(answer.outcome.action, ElicitationAction::Accept);
        assert_eq!(answer.values.unwrap()["f0"].as_str(), "hunter2");
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

    #[tokio::test(flavor = "multi_thread")]
    async fn a_yes_or_no_carries_no_values() {
        let shared = asking();
        let (questions, host) = (&shared.0, &shared.1);
        let asking = Arc::clone(&shared);
        let asked = tokio::spawn(async move {
            asking
                .0
                .ask(
                    &asking.1,
                    SessionId::from_u128(9),
                    "Go?",
                    Asker::Agent,
                    Duration::from_secs(10),
                )
                .await
        });
        let id = first_pending(questions).await;
        let values = Reply::Values([("f0".to_owned(), "x".to_owned())].into());
        assert_eq!(
            questions
                .resolve(host, &id, ElicitationAnswer::Accept, values)
                .unwrap_err()
                .code,
            BAD_INPUT
        );
        questions
            .resolve(host, &id, ElicitationAnswer::Decline, Reply::Bare)
            .unwrap();
        assert_eq!(
            asked.await.unwrap().unwrap().action,
            ElicitationAction::Decline
        );
    }

    /// Waiting for the person holds no thread: many questions at once add none.
    #[tokio::test(flavor = "current_thread")]
    async fn waiting_questions_hold_no_thread() {
        let shared = asking();
        let mut asked = Vec::new();
        for _ in 0..MAX_PENDING {
            let asking = Arc::clone(&shared);
            asked.push(tokio::spawn(async move {
                asking
                    .0
                    .ask(
                        &asking.1,
                        SessionId::from_u128(9),
                        "Go?",
                        Asker::Agent,
                        Duration::from_secs(30),
                    )
                    .await
            }));
        }
        // One thread runs this test and every question: they all wait on it at once.
        while shared.0.pending().len() < MAX_PENDING {
            tokio::task::yield_now().await;
        }
        for elicitation in shared.0.pending() {
            shared
                .0
                .resolve(
                    &shared.1,
                    &elicitation.id,
                    ElicitationAnswer::Decline,
                    Reply::Bare,
                )
                .unwrap();
        }
        for question in asked {
            assert_eq!(
                question.await.unwrap().unwrap().action,
                ElicitationAction::Decline
            );
        }
    }

    #[tokio::test]
    async fn dropping_the_waiting_future_withdraws_the_question() {
        let shared = asking();
        let asking = Arc::clone(&shared);
        let asked = tokio::spawn(async move {
            asking
                .0
                .ask(
                    &asking.1,
                    SessionId::from_u128(9),
                    "Go?",
                    Asker::Agent,
                    Duration::from_secs(30),
                )
                .await
        });
        let id = first_pending(&shared.0).await;
        asked.abort();
        assert!(asked.await.unwrap_err().is_cancelled());
        assert!(shared.0.pending().is_empty());
        let events = shared.1.events.lock().unwrap();
        let resolved = events.iter().filter(|event| matches!(event,
            Event::ElicitationResolved { id: resolved_id, action: ElicitationAction::Cancel, .. } if resolved_id == &id
        )).count();
        assert_eq!(resolved, 1);
    }

    /// An asker that gives up withdraws its question at once, and every client is told.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_asker_that_gives_up_withdraws_its_question_at_once() {
        let shared = asking();
        let cancellation = axo_ipc::cancel::Cancellation::default();
        let asking = Arc::clone(&shared);
        let asked = tokio::spawn(axo_ipc::cancel::scope(cancellation.clone(), async move {
            asking
                .0
                .ask(
                    &asking.1,
                    SessionId::from_u128(9),
                    "Go?",
                    Asker::Agent,
                    Duration::from_secs(30),
                )
                .await
        }));
        first_pending(&shared.0).await;
        cancellation.cancel();
        let outcome = tokio::time::timeout(Duration::from_secs(1), asked)
            .await
            .expect("withdrawn at once")
            .unwrap()
            .unwrap();
        assert_eq!(outcome.action, ElicitationAction::Cancel);
        assert!(shared.0.pending().is_empty());
        assert!(matches!(
            shared.1.events.lock().unwrap().last(),
            Some(Event::ElicitationResolved {
                action: ElicitationAction::Cancel,
                ..
            })
        ));
    }

    #[test]
    fn only_so_many_wait_at_once() {
        let elicitations = Elicitations::default();
        let mut waiting = Vec::new();
        for index in 0..MAX_PENDING {
            waiting.push(elicitations.open(elicitation(&index.to_string())).unwrap());
        }
        assert!(elicitations.open(elicitation("one more")).is_none());
    }
}
