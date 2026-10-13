//! Owner-only typed IPC to the public extension inside an already-owned Pi TUI.
//! No listener, agent engine, terminal parser, persistence writer or automatic replay.
#[cfg(test)]
mod snapshot_tests;
mod wire;
use crate::model::{ChildPid, RuntimeRef};
use std::{
    collections::BTreeMap,
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    sync::{Arc, Condvar, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};
pub use wire::{
    CanonicalDocument, ChatId, History, InteractionId, Mode, Model, OptionId, Question, QuestionId,
    State,
};
use wire::{
    Expected, InteractionTarget, Record, RemoteError, Request, RequestId, Response, Target,
};
const REQUEST_BYTES: usize = 65_536;
const RECORD_BYTES: usize = 4 * 1024 * 1024;
const DEADLINE: Duration = Duration::from_secs(5);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlError {
    NotReady,
    Capacity,
    Stale,
    Busy,
    Blocked,
    Invalid,
    RecoveryRequired,
    OutcomeUnknown,
}
/// Only extension dispatch acknowledgement, never execution/delivery/settlement proof.
#[derive(Clone, Copy, Debug)]
pub struct Dispatched;
struct Pending {
    expected: Expected,
    sender: mpsc::SyncSender<Result<Response, ControlError>>,
}
struct Observations {
    ready: Option<State>,
    current: Option<State>,
    gap: bool,
    calls: BTreeMap<RequestId, Pending>,
}
struct Shared {
    state: Mutex<Observations>,
    changed: Condvar,
}
pub struct Control {
    runtime: RuntimeRef,
    chat_id: ChatId,
    writer: Mutex<UnixStream>,
    shared: Arc<Shared>,
}
impl Control {
    pub fn admit(
        runtime: RuntimeRef,
        pid: ChildPid,
        directory: &Path,
        sessions: &Path,
        socket: UnixStream,
    ) -> Result<Self, ControlError> {
        socket
            .set_write_timeout(Some(Duration::from_millis(500)))
            .map_err(|_| ControlError::OutcomeUnknown)?;
        let reader = socket
            .try_clone()
            .map_err(|_| ControlError::OutcomeUnknown)?;
        let shared = Arc::new(Shared {
            state: Mutex::new(Observations {
                ready: None,
                current: None,
                gap: false,
                calls: BTreeMap::new(),
            }),
            changed: Condvar::new(),
        });
        let observer = shared.clone();
        thread::Builder::new()
            .name("axod-pi-control".into())
            .spawn(move || receive(reader, observer))
            .map_err(|_| ControlError::OutcomeUnknown)?;
        let ready = await_ready(&shared)?;
        validate_identity(&ready, pid, directory, sessions)?;
        let control = Self {
            runtime,
            chat_id: ready.chat_id,
            writer: Mutex::new(socket),
            shared,
        };
        let bound = control.snapshot_request(Request::Bind {
            id: RequestId::new(),
            runtime,
        })?;
        validate_identity(&bound, pid, directory, sessions)?;
        if bound.chat_id != ready.chat_id || bound.file != ready.file {
            return Err(ControlError::Stale);
        }
        Ok(control)
    }
    fn target(&self) -> Target {
        Target {
            runtime: self.runtime,
            chat_id: self.chat_id,
        }
    }
    fn interaction_target(&self, interaction_id: InteractionId) -> InteractionTarget {
        InteractionTarget {
            runtime: self.runtime,
            chat_id: self.chat_id,
            interaction_id,
        }
    }
    pub fn current(&self) -> Result<State, ControlError> {
        let state = self.shared.state.lock().unwrap();
        if state.gap {
            return Err(ControlError::OutcomeUnknown);
        }
        let current = state
            .current
            .as_ref()
            .or(state.ready.as_ref())
            .ok_or(ControlError::NotReady)?;
        let admitted = state.ready.as_ref().ok_or(ControlError::NotReady)?;
        if current.chat_id != self.chat_id || !same_identity(current, admitted) {
            return Err(ControlError::Stale);
        }
        Ok(current.clone())
    }
    pub fn get(&self) -> Result<State, ControlError> {
        self.snapshot_request(Request::Get {
            id: RequestId::new(),
            target: self.target(),
        })
    }
    pub fn history(&self) -> Result<History, ControlError> {
        match self.request(Request::History {
            id: RequestId::new(),
            target: self.target(),
        })? {
            Response::History(history) => Ok(history),
            _ => Err(ControlError::OutcomeUnknown),
        }
    }
    pub fn send(&self, text: &str) -> Result<Dispatched, ControlError> {
        self.dispatch_request(Request::Send {
            id: RequestId::new(),
            target: self.target(),
            text,
        })
    }
    pub fn steer(
        &self,
        interaction: InteractionId,
        text: &str,
    ) -> Result<Dispatched, ControlError> {
        self.dispatch_request(Request::Steer {
            id: RequestId::new(),
            target: self.interaction_target(interaction),
            text,
        })
    }
    pub fn cancel(&self, interaction: InteractionId) -> Result<Dispatched, ControlError> {
        self.dispatch_request(Request::Cancel {
            id: RequestId::new(),
            target: self.interaction_target(interaction),
        })
    }
    pub fn answer(
        &self,
        interaction: InteractionId,
        question_id: QuestionId,
        option_id: OptionId,
    ) -> Result<Dispatched, ControlError> {
        self.dispatch_request(Request::Answer {
            id: RequestId::new(),
            target: self.interaction_target(interaction),
            question_id,
            option_id,
        })
    }
    pub fn shutdown(&self) -> Result<Dispatched, ControlError> {
        self.dispatch_request(Request::Shutdown {
            id: RequestId::new(),
            target: self.target(),
        })
    }
    fn snapshot_request(&self, request: Request<'_>) -> Result<State, ControlError> {
        match self.request(request)? {
            Response::Snapshot(state) => Ok(*state),
            _ => Err(ControlError::OutcomeUnknown),
        }
    }
    fn dispatch_request(&self, request: Request<'_>) -> Result<Dispatched, ControlError> {
        match self.request(request)? {
            Response::Dispatched => Ok(Dispatched),
            _ => Err(ControlError::OutcomeUnknown),
        }
    }
    fn request(&self, request: Request<'_>) -> Result<Response, ControlError> {
        let id = request.id();
        let expected = request.expected();
        let mut bytes = serde_json::to_vec(&request).map_err(|_| ControlError::Invalid)?;
        bytes.push(b'\n');
        if bytes.len() > REQUEST_BYTES {
            return Err(ControlError::Capacity);
        }
        let (sender, receiver) = mpsc::sync_channel(1);
        {
            let mut state = self.shared.state.lock().unwrap();
            if state.gap {
                return Err(ControlError::OutcomeUnknown);
            }
            if state.calls.len() >= 16 {
                return Err(ControlError::Capacity);
            }
            state.calls.insert(id, Pending { expected, sender });
        }
        // Partial write/loss never proves that the extension did not dispatch.
        if self.writer.lock().unwrap().write_all(&bytes).is_err() {
            fence(&self.shared);
            return Err(ControlError::OutcomeUnknown);
        }
        match receiver.recv_timeout(DEADLINE) {
            Ok(response) => response,
            Err(_) => {
                fence(&self.shared);
                Err(ControlError::OutcomeUnknown)
            }
        }
    }
}
fn await_ready(shared: &Shared) -> Result<State, ControlError> {
    let deadline = Instant::now() + DEADLINE;
    let mut state = shared.state.lock().unwrap();
    while state.ready.is_none() && !state.gap {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(ControlError::NotReady)?;
        state = shared.changed.wait_timeout(state, remaining).unwrap().0;
    }
    state.ready.clone().ok_or(ControlError::NotReady)
}
fn validate_identity(
    state: &State,
    pid: ChildPid,
    directory: &Path,
    sessions: &Path,
) -> Result<(), ControlError> {
    if state.pid != pid
        || !state.stdin_tty
        || !state.stdout_tty
        || !state.stderr_tty
        || state.recovery
        || state.model.is_none()
    {
        return Err(ControlError::NotReady);
    }
    let actual = std::fs::canonicalize(&state.cwd).map_err(|_| ControlError::NotReady)?;
    let expected = std::fs::canonicalize(directory).map_err(|_| ControlError::NotReady)?;
    let file = state
        .file
        .as_ref()
        .filter(|file| file.is_absolute())
        .ok_or(ControlError::NotReady)?;
    let parent = file
        .parent()
        .and_then(|parent| std::fs::canonicalize(parent).ok())
        .ok_or(ControlError::NotReady)?;
    let expected_sessions = std::fs::canonicalize(sessions).map_err(|_| ControlError::NotReady)?;
    if actual != expected || parent != expected_sessions {
        return Err(ControlError::Stale);
    }
    Ok(())
}
fn fence(shared: &Shared) {
    let mut state = shared.state.lock().unwrap();
    state.gap = true;
    for (_, pending) in std::mem::take(&mut state.calls) {
        let _ = pending.sender.try_send(Err(ControlError::OutcomeUnknown));
    }
    shared.changed.notify_all();
}
fn receive(socket: UnixStream, shared: Arc<Shared>) {
    let mut reader = BufReader::new(socket);
    loop {
        let mut bytes = Vec::new();
        if reader
            .by_ref()
            .take((RECORD_BYTES + 1) as u64)
            .read_until(b'\n', &mut bytes)
            .is_err()
            || bytes.len() > RECORD_BYTES
            || bytes.last() != Some(&b'\n')
        {
            break;
        }
        let Ok(record) = serde_json::from_slice::<Record>(&bytes) else {
            break;
        };
        if !route(record, &shared) {
            break;
        }
    }
    fence(&shared);
}
fn route(record: Record, shared: &Shared) -> bool {
    let mut state = shared.state.lock().unwrap();
    if state.gap {
        return false;
    }
    match record {
        Record::Ready(value) => {
            if state.ready.is_some() {
                return false;
            }
            state.ready = Some(*value.clone());
            state.current = Some(*value);
            shared.changed.notify_all();
        }
        Record::Status(value) => {
            if state.ready.is_none() {
                return false;
            }
            state.current = Some(*value);
            shared.changed.notify_all();
        }
        Record::Reply(reply) => {
            let Some(id) = reply.id else {
                return false;
            };
            let Some(pending) = state.calls.remove(&id) else {
                return false;
            };
            if !reply.response.matches(pending.expected) {
                let _ = pending.sender.try_send(Err(ControlError::OutcomeUnknown));
                return false;
            }
            let response = match reply.response {
                Response::Rejected(code) => Err(rejection(code)),
                Response::Snapshot(snapshot) => {
                    if !state
                        .ready
                        .as_ref()
                        .is_some_and(|ready| same_identity(&snapshot, ready))
                    {
                        let _ = pending.sender.try_send(Err(ControlError::Stale));
                        return false;
                    }
                    // Publish at this reply's receive position, not in the waiting
                    // caller: that caller could otherwise overwrite a later status.
                    state.current = Some(*snapshot.clone());
                    Ok(Response::Snapshot(snapshot))
                }
                response => Ok(response),
            };
            let _ = pending.sender.try_send(response);
        }
    }
    true
}
fn same_identity(observed: &State, admitted: &State) -> bool {
    observed.chat_id == admitted.chat_id
        && observed.file == admitted.file
        && observed.cwd == admitted.cwd
        && observed.pid == admitted.pid
        && observed.mode == admitted.mode
}
fn rejection(error: RemoteError) -> ControlError {
    match error {
        RemoteError::Busy => ControlError::Busy,
        RemoteError::Blocked => ControlError::Blocked,
        RemoteError::Invalid => ControlError::Invalid,
        RemoteError::Stale | RemoteError::StaleInteraction => ControlError::Stale,
        RemoteError::NotReady | RemoteError::NotInteractive => ControlError::NotReady,
        RemoteError::Rejected => ControlError::Invalid,
        RemoteError::Recovery => ControlError::RecoveryRequired,
        RemoteError::Unknown => ControlError::OutcomeUnknown,
    }
}
