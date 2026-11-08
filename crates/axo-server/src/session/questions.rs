//! The Session manager as the questions extension's host (`axo-questions`, RFD0029): which
//! Sessions are open, where events go, and this Mac's input key. The gate and forms ask through
//! the wrappers here.

use std::sync::Arc;
use std::time::Duration;

use axo_protocol::elicitation::{
    Asker, Elicitation, ElicitationAnswer, ElicitationOutcome, InputRequest, Reply,
};
use axo_protocol::{Event, SessionId};
use axo_questions::{Questions, QuestionsHost, Values};
use jsonrpc_core::Error as RpcError;

use super::SessionManager;

impl QuestionsHost for SessionManager {
    fn has_session(&self, session: SessionId) -> bool {
        self.lock_state().is_ok_and(|state| {
            super::catalog::session_metadata(
                &state,
                &self.lock_agents(),
                session,
                &self.attach_socket_path,
            )
            .is_ok()
        })
    }

    fn publish(&self, event: Event) {
        self.publish_event(event);
    }

    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        SessionManager::input_key(self)
    }
}

impl SessionManager {
    /// The questions waiting on this Mac, for the questions extension.
    pub(crate) fn questions(&self) -> Arc<Questions> {
        Arc::clone(&self.elicitations)
    }

    /// Asks for a form and waits; an accepted form comes with its values.
    pub(crate) fn ask_with(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<(ElicitationOutcome, Option<Values>), RpcError> {
        self.elicitations
            .ask_with(self, session_id, message, asked_by, input, timeout)
    }

    /// A person's answer, from the relay.
    pub(crate) fn resolve_elicitation(
        &self,
        id: &str,
        answer: ElicitationAnswer,
        reply: Reply,
    ) -> Result<(), (i64, String)> {
        self.elicitations.resolve(self, id, answer, reply)
    }

    pub(crate) fn pending_elicitations(&self) -> Vec<Elicitation> {
        self.elicitations.pending()
    }
}
