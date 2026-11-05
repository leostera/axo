//! Elicitations (RFD0029): what agents on this Mac ask the person, waiting for an answer.
//!
//! `axo.elicitation.request` is the only way in on `axod.sock`, and it only asks. An answer comes
//! through the relay alone (`RelayHost::resolve_elicitation`), where the cloud takes it only from
//! a signed-in person's client. The first answer taken wins: it removes the elicitation, so any
//! later one finds nothing. Elicitations live in memory: when axod stops, the tool calls waiting
//! on them end too.

use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axo_ipc::TypedMethods;
use axo_protocol::elicitation::{
    Elicitation, ElicitationAction, ElicitationAnswer, ElicitationKind, ElicitationOutcome,
    MAX_MESSAGE_CHARS, MAX_PENDING, RequestElicitation, TIMEOUT_MS,
};
use axo_protocol::rpc::method;
use axo_protocol::{Event, SessionId, new_uuid_v4};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use std::sync::Arc;

use super::SessionManager;

/// Error codes shared with `@axo/protocol`'s `ELICITATION_ERRORS`, and the limit of the relay's.
pub const TOO_MANY: i64 = -32006;

struct Pending {
    elicitation: Elicitation,
    answer: SyncSender<ElicitationAction>,
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

    fn open(
        &self,
        elicitation: Elicitation,
    ) -> io::Result<Option<mpsc::Receiver<ElicitationAction>>> {
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
        let Some(pending) = self.lock()?.remove(id) else {
            return Ok(None);
        };
        let _ = pending.answer.try_send(action);
        Ok(Some(pending.elicitation))
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
        let message = request.message.trim();
        if message.is_empty() || message.chars().count() > MAX_MESSAGE_CHARS {
            return Err(invalid(format!(
                "message must be 1 to {MAX_MESSAGE_CHARS} characters"
            )));
        }
        self.ensure_session(request.session_id)?;
        let now = unix_millis();
        let elicitation = Elicitation {
            id: new_uuid_v4().map_err(internal)?,
            session_id: request.session_id,
            kind: ElicitationKind::Confirm,
            message: message.to_owned(),
            created_at: now,
            expires_at: now + timeout.as_millis() as u64,
        };
        let id = elicitation.id.clone();
        let Some(answer) = self.elicitations.open(elicitation.clone()).map_err(internal)? else {
            return Err(RpcError {
                code: ErrorCode::ServerError(TOO_MANY),
                message: format!(
                    "{MAX_PENDING} questions are already waiting for the person on this Mac"
                ),
                data: None,
            });
        };
        log::info!("event=elicitation.requested id={id} kind=confirm");
        self.publish_event(Event::ElicitationRequested { elicitation });
        let action = match answer.recv_timeout(timeout) {
            Ok(action) => action,
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
                match self
                    .elicitations
                    .settle(&id, ElicitationAction::Cancel)
                    .map_err(internal)?
                {
                    Some(elicitation) => {
                        self.publish_resolved(&elicitation, ElicitationAction::Cancel);
                        ElicitationAction::Cancel
                    }
                    // An answer won the race with the timeout: it is already sent.
                    None => answer.try_recv().unwrap_or(ElicitationAction::Cancel),
                }
            }
        };
        Ok(ElicitationOutcome { id, action })
    }

    /// A person's answer, from the relay. False when it no longer waits: answered already,
    /// expired, or never asked.
    pub(crate) fn resolve_elicitation(&self, id: &str, answer: ElicitationAnswer) -> bool {
        let action = ElicitationAction::from(answer);
        match self.elicitations.settle(id, action) {
            Ok(Some(elicitation)) => {
                self.publish_resolved(&elicitation, action);
                true
            }
            _ => false,
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

/// Registers `axo.elicitation.request`. Nothing here answers one.
pub(crate) fn add_methods(manager: &Arc<SessionManager>, handler: &mut IoHandler) {
    let manager = Arc::clone(manager);
    handler.add_typed(
        method::ELICITATION_REQUEST,
        "expected {sessionId, message}",
        move |request: RequestElicitation| {
            manager.request_elicitation(request, Duration::from_millis(TIMEOUT_MS))
        },
    );
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
            message: "Go?".into(),
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
        assert_eq!(answer.try_recv().unwrap(), ElicitationAction::Decline);
        assert!(answer.try_recv().is_err());
        assert!(elicitations.pending().is_empty());
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
        assert!(elicitations.open(elicitation("one more")).unwrap().is_none());
    }
}
