//! The tool calls in flight and the `axo.*` calls they wait on, so that a call can be given up.
//!
//! Every tool call runs on its own thread, and each `axo.*` call it makes has its own
//! cancellation. Giving a call up (the client's `notifications/cancelled`, or its input ending
//! because Pi left) fires them: the methods give up what they waited on for it, such as a question
//! to the person, and the call stops waiting (RFD0034). An `axo.*` call made after that is refused.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Mutex;

use axo_ipc::cancel::Cancellation;

#[derive(Default)]
pub(crate) struct Calls {
    calls: Mutex<HashMap<String, Call>>,
}

#[derive(Default)]
struct Call {
    given_up: bool,
    waiting: HashMap<u64, Cancellation>,
    next: u64,
}

thread_local! {
    /// The call this thread runs: the MCP request's id, as JSON.
    static CURRENT: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// One of a call's `axo.*` calls, kept while it waits for its answer.
pub(crate) struct Attached<'a> {
    calls: &'a Calls,
    call: String,
    key: u64,
}

impl Drop for Attached<'_> {
    fn drop(&mut self) {
        if let Some(call) = self.calls.lock().get_mut(&self.call) {
            call.waiting.remove(&self.key);
        }
    }
}

impl Calls {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Call>> {
        self.calls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Runs `call` as the call `id` on this thread, then forgets it. Returns `None` if it was
    /// given up meanwhile: its answer is no longer wanted.
    pub(crate) fn run<R>(&self, id: String, call: impl FnOnce() -> R) -> Option<R> {
        self.lock().entry(id.clone()).or_default();
        let previous = CURRENT.with(|current| current.replace(Some(id.clone())));
        let result = call();
        CURRENT.with(|current| *current.borrow_mut() = previous);
        let given_up = self.lock().remove(&id).is_some_and(|call| call.given_up);
        (!given_up).then_some(result)
    }

    /// Keeps `cancellation` as one of the current call's until the guard drops. `Err` if the
    /// call was given up: nothing more is asked for it. Outside a call, nothing is kept.
    pub(crate) fn attach(
        &self,
        cancellation: &Cancellation,
    ) -> Result<Option<Attached<'_>>, GivenUp> {
        let Some(id) = CURRENT.with(|current| current.borrow().clone()) else {
            return Ok(None);
        };
        let mut calls = self.lock();
        let call = calls.entry(id.clone()).or_default();
        if call.given_up {
            return Err(GivenUp);
        }
        call.next += 1;
        let key = call.next;
        call.waiting.insert(key, cancellation.clone());
        Ok(Some(Attached {
            calls: self,
            call: id,
            key,
        }))
    }

    /// Gives up the call `id` (an MCP request id, as JSON), if it is running.
    pub(crate) fn give_up(&self, id: &str) -> bool {
        match self.lock().get_mut(id) {
            Some(call) => {
                call.give_up();
                true
            }
            None => false,
        }
    }

    /// Gives up every call: the client has gone.
    pub(crate) fn give_up_all(&self) -> usize {
        let mut calls = self.lock();
        calls.values_mut().for_each(Call::give_up);
        calls.len()
    }
}

impl Call {
    fn give_up(&mut self) {
        self.given_up = true;
        for cancellation in self.waiting.values() {
            cancellation.cancel();
        }
    }
}

/// The call was given up before this `axo.*` call was made.
#[derive(Debug)]
pub(crate) struct GivenUp;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn giving_up_a_call_cancels_what_it_waits_on_and_refuses_more() {
        let calls = Calls::default();
        let waiting = Cancellation::default();
        let answered = calls.run("1".into(), || {
            let attached = calls.attach(&waiting).unwrap();
            assert!(attached.is_some());
            assert!(calls.give_up("1"));
            assert!(waiting.is_cancelled(), "the method is told");
            assert!(
                calls.attach(&Cancellation::default()).is_err(),
                "nothing more is asked for it"
            );
        });
        assert!(answered.is_none(), "a given-up call's answer is not sent");
        assert!(!calls.give_up("1"), "it is forgotten once it ends");
    }

    #[test]
    fn a_call_that_is_not_given_up_answers_and_outside_calls_nothing_is_kept() {
        let calls = Calls::default();
        let waiting = Cancellation::default();
        assert!(calls.attach(&waiting).unwrap().is_none());
        assert_eq!(calls.run("2".into(), || 42), Some(42));
        assert_eq!(calls.give_up_all(), 0);
        assert!(!waiting.is_cancelled());
    }
}
