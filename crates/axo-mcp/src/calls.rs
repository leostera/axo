//! The tool calls in flight, so that a call can be given up.
//!
//! Every tool call runs as a task with a cancellation of its own, which each `axo.*` call it
//! makes carries ([`current`]). Giving the call up (the client's `notifications/cancelled`, or
//! its input ending because Pi left) fires it: the methods give up what they waited on for it,
//! such as a question to the person, the call stops waiting at once, and an `axo.*` call made
//! after that is refused (RFD0034).

use std::collections::HashMap;
use std::future::Future;
use std::sync::Mutex;

use axo_ipc::cancel::Cancellation;

tokio::task_local! {
    /// The cancellation of the tool call this task runs.
    static CURRENT: Cancellation;
}

/// The cancellation of the tool call being run; one that never fires outside a call.
pub(crate) fn current() -> Cancellation {
    CURRENT.try_with(Clone::clone).unwrap_or_default()
}

#[derive(Default)]
pub(crate) struct Calls {
    calls: Mutex<HashMap<String, Cancellation>>,
}

impl Calls {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Cancellation>> {
        self.calls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Runs `call` as the call `id` (an MCP request id, as JSON), then forgets it. Returns `None`
    /// if it was given up meanwhile: its answer is no longer wanted.
    pub(crate) async fn run<F: Future>(&self, id: String, call: F) -> Option<F::Output> {
        let cancellation = Cancellation::default();
        self.lock().insert(id.clone(), cancellation.clone());
        let result = CURRENT.scope(cancellation.clone(), call).await;
        self.lock().remove(&id);
        (!cancellation.is_cancelled()).then_some(result)
    }

    /// Gives up the call `id`, if it is running.
    pub(crate) fn give_up(&self, id: &str) -> bool {
        match self.lock().get(id) {
            Some(cancellation) => {
                cancellation.cancel();
                true
            }
            None => false,
        }
    }

    /// Gives up every call: the client has gone.
    pub(crate) fn give_up_all(&self) -> usize {
        let calls = self.lock();
        calls.values().for_each(Cancellation::cancel);
        calls.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<F: Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(future)
    }

    #[test]
    fn giving_up_a_call_cancels_what_it_waits_on_and_drops_its_answer() {
        let calls = Calls::default();
        let answered = block_on(calls.run("1".into(), async {
            let waiting = current();
            assert!(!waiting.is_cancelled());
            assert!(calls.give_up("1"));
            assert!(waiting.is_cancelled(), "the methods are told");
            assert!(current().is_cancelled(), "anything asked after is refused");
        }));
        assert!(answered.is_none(), "a given-up call's answer is not sent");
        assert!(!calls.give_up("1"), "it is forgotten once it ends");
    }

    #[test]
    fn a_call_that_is_not_given_up_answers_and_outside_calls_nothing_fires() {
        let calls = Calls::default();
        assert!(!current().is_cancelled());
        assert_eq!(block_on(calls.run("2".into(), async { 42 })), Some(42));
        assert_eq!(calls.give_up_all(), 0);
    }
}
