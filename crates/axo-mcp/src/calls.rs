//! The tool calls in flight and their connections to axod, so that a call can be given up.
//!
//! Every tool call runs on its own thread and reaches axod over connections of its own, one per
//! `axo.*` call. Giving a call up (the client's `notifications/cancelled`, or its stdin ending
//! because Pi left) closes those connections; axod then cancels what it was waiting on for them,
//! such as a question to the person (RFD0034). A connection opened after that is refused.

use std::cell::RefCell;
use std::collections::HashMap;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Mutex;

#[derive(Default)]
pub(crate) struct Calls {
    calls: Mutex<HashMap<String, Call>>,
}

#[derive(Default)]
struct Call {
    given_up: bool,
    connections: HashMap<u64, UnixStream>,
    next: u64,
}

thread_local! {
    /// The call this thread runs: the MCP request's id, as JSON.
    static CURRENT: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// One of a call's connections to axod, kept while it waits for its answer.
pub(crate) struct Attached<'a> {
    calls: &'a Calls,
    call: String,
    connection: u64,
}

impl Drop for Attached<'_> {
    fn drop(&mut self) {
        if let Some(call) = self.calls.lock().get_mut(&self.call) {
            call.connections.remove(&self.connection);
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

    /// Keeps `stream` as one of the current call's connections until the guard drops. `Err` if
    /// the call was given up: nothing more is asked for it. Outside a call, nothing is kept.
    pub(crate) fn attach(&self, stream: &UnixStream) -> Result<Option<Attached<'_>>, GivenUp> {
        let Some(id) = CURRENT.with(|current| current.borrow().clone()) else {
            return Ok(None);
        };
        let mut calls = self.lock();
        let call = calls.entry(id.clone()).or_default();
        if call.given_up {
            return Err(GivenUp);
        }
        let Ok(kept) = stream.try_clone() else {
            return Ok(None);
        };
        call.next += 1;
        let connection = call.next;
        call.connections.insert(connection, kept);
        Ok(Some(Attached {
            calls: self,
            call: id,
            connection,
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
        for connection in self.connections.values() {
            let _ = connection.shutdown(Shutdown::Both);
        }
    }
}

/// The call was given up before this connection was made.
#[derive(Debug)]
pub(crate) struct GivenUp;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn giving_up_a_call_closes_its_connections_and_refuses_new_ones() {
        let calls = Calls::default();
        let (ours, theirs) = UnixStream::pair().unwrap();
        let answered = calls.run("1".into(), || {
            let attached = calls.attach(&ours).unwrap();
            assert!(attached.is_some());
            assert!(calls.give_up("1"));
            // axod's side sees the connection end.
            let mut byte = [0u8; 1];
            assert_eq!((&theirs).read(&mut byte).unwrap(), 0);
            assert!(calls.attach(&ours).is_err(), "nothing more is asked for it");
        });
        assert!(answered.is_none(), "a given-up call's answer is not sent");
        assert!(!calls.give_up("1"), "it is forgotten once it ends");
    }

    #[test]
    fn a_call_that_is_not_given_up_answers_and_outside_calls_nothing_is_kept() {
        let calls = Calls::default();
        let (ours, _theirs) = UnixStream::pair().unwrap();
        assert!(calls.attach(&ours).unwrap().is_none());
        assert_eq!(calls.run("2".into(), || 42), Some(42));
        assert_eq!(calls.give_up_all(), 0);
    }
}
