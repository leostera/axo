use crate::{journal::Journal, model::*, protocol::*, pty};
use std::collections::{BTreeMap, VecDeque};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::{fd::AsRawFd, unix::net::UnixStream};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
    mpsc::SyncSender,
};
use std::thread;
use std::time::Duration;

#[derive(Clone)]
pub struct Sink {
    pub sender: SyncSender<Frame>,
    pub socket: Arc<UnixStream>,
}
impl Sink {
    pub fn send(&self, frame: Frame) -> bool {
        if self.sender.try_send(frame).is_err() {
            let _ = self.socket.shutdown(std::net::Shutdown::Both);
            return false;
        }
        true
    }
}
struct Attachment {
    owner: u64,
    reference: AttachmentRef,
    sink: Sink,
}
struct State {
    process: ProcessState,
    attachment: Option<Attachment>,
    backlog: VecDeque<u8>,
    next_offset: u64,
    output_finished: bool,
    journal_finished: bool,
}
struct Terminal {
    reference: RuntimeRef,
    controller: Mutex<Option<Arc<File>>>,
    state: Mutex<State>,
    journal: Arc<Mutex<Journal>>,
}
impl Terminal {
    fn owns_live_resources(&self) -> bool {
        let state = self.state.lock().unwrap();
        !state.output_finished
            || matches!(
                state.process,
                ProcessState::Running { .. } | ProcessState::Stopping { .. }
            )
    }
    fn snapshot(&self) -> TerminalSnapshot {
        let state = self.state.lock().unwrap();
        TerminalSnapshot {
            runtime: self.reference,
            process: state.process.clone(),
            attached: state.attachment.is_some(),
            backlog_bytes: state.backlog.len(),
        }
    }
    fn stop(&self, signal: i32) -> Result<bool, ErrorCode> {
        let mut state = self.state.lock().unwrap();
        let pid = match state.process {
            ProcessState::Running { pid } => pid,
            ProcessState::Stopping { pid } if signal != libc::SIGTERM => pid,
            _ => return Ok(false),
        };
        // The same state lock protects waitpid and signaling; never signal a reaped/reused PID.
        if unsafe { libc::kill(-pid, signal) } < 0
            && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
        {
            return Err(ErrorCode::NotRunning);
        }
        state.process = ProcessState::Stopping { pid };
        Ok(true)
    }
    fn require_attachment(
        &self,
        state: &State,
        owner: u64,
        reference: AttachmentRef,
    ) -> Result<(), ErrorCode> {
        if !matches!(state.process, ProcessState::Running { .. }) {
            return Err(ErrorCode::NotRunning);
        }
        if !state
            .attachment
            .as_ref()
            .is_some_and(|value| value.owner == owner && value.reference == reference)
        {
            return Err(ErrorCode::StaleAttachment);
        }
        Ok(())
    }
}

pub struct Manager {
    pub generation: HostGeneration,
    journal: Arc<Mutex<Journal>>,
    terminals: Mutex<BTreeMap<PaneId, Arc<Terminal>>>,
    stopping: AtomicBool,
}
impl Manager {
    pub fn new(journal: Journal) -> Self {
        Self {
            generation: HostGeneration::new(),
            journal: Arc::new(Mutex::new(journal)),
            terminals: Mutex::new(BTreeMap::new()),
            stopping: AtomicBool::new(false),
        }
    }
    pub fn list(&self) -> Vec<TerminalSnapshot> {
        let mut records: BTreeMap<_, _> = self
            .journal
            .lock()
            .unwrap()
            .snapshots()
            .into_iter()
            .map(|snapshot| (snapshot.runtime.target.pane_id, snapshot))
            .collect();
        for (id, terminal) in self.terminals.lock().unwrap().iter() {
            records.insert(*id, terminal.snapshot());
        }
        records.into_values().collect()
    }
    pub fn start(
        &self,
        command: CommandId,
        target: TerminalTarget,
        launch: &TerminalLaunch,
    ) -> Result<TerminalSnapshot, ErrorCode> {
        let mut terminals = self.terminals.lock().unwrap();
        if self.stopping.load(Ordering::SeqCst) {
            return Err(ErrorCode::NotRunning);
        }
        let previous = self
            .journal
            .lock()
            .unwrap()
            .lookup(command, target, launch)?;
        if let Some(previous) = previous {
            let snapshot = terminals
                .get(&target.pane_id)
                .filter(|value| value.reference == previous)
                .map(|value| value.snapshot())
                .or_else(|| {
                    self.journal
                        .lock()
                        .unwrap()
                        .snapshots()
                        .into_iter()
                        .find(|value| value.runtime == previous)
                })
                .ok_or(ErrorCode::StaleRuntime)?;
            return match snapshot.process {
                ProcessState::Failed { .. } => Err(ErrorCode::LaunchFailed),
                ProcessState::RecoveryRequired { .. } | ProcessState::Starting { .. } => {
                    Err(ErrorCode::RecoveryRequired)
                }
                _ => Ok(snapshot),
            };
        }
        if terminals
            .values()
            .filter(|value| value.owns_live_resources())
            .count()
            >= MAX_TERMINALS
        {
            return Err(ErrorCode::Capacity);
        }
        if terminals
            .get(&target.pane_id)
            .is_some_and(|value| value.owns_live_resources())
        {
            return Err(ErrorCode::Conflict);
        }
        let reference = RuntimeRef {
            host_generation: self.generation,
            target,
            runtime_generation: RuntimeGeneration::new(),
        };
        self.journal
            .lock()
            .unwrap()
            .prepare(command, reference, launch)?;
        // The durable intent is committed before fork; no disk transaction spans process launch.
        let child = match pty::spawn(&launch.directory, &launch.argv) {
            Ok(child) => child,
            Err(_) => {
                self.journal
                    .lock()
                    .unwrap()
                    .update(reference, ProcessState::Failed {})?;
                return Err(ErrorCode::LaunchFailed);
            }
        };
        let terminal = Arc::new(Terminal {
            reference,
            controller: Mutex::new(Some(Arc::new(child.controller))),
            journal: self.journal.clone(),
            state: Mutex::new(State {
                process: ProcessState::Running { pid: child.pid },
                attachment: None,
                backlog: VecDeque::with_capacity(BACKLOG_BYTES),
                next_offset: 0,
                output_finished: false,
                journal_finished: false,
            }),
        });
        terminals.insert(target.pane_id, terminal.clone());
        let persisted = self
            .journal
            .lock()
            .unwrap()
            .update(reference, ProcessState::Running { pid: child.pid });
        let drain_owner = terminal.clone();
        let reader = terminal
            .controller
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .clone();
        thread::spawn(move || drain(drain_owner, reader));
        let reap_owner = terminal.clone();
        thread::spawn(move || reap(reap_owner, child.pid));
        persisted?;
        Ok(terminal.snapshot())
    }
    fn find(&self, reference: RuntimeRef) -> Result<Arc<Terminal>, ErrorCode> {
        if self.stopping.load(Ordering::SeqCst) {
            return Err(ErrorCode::NotRunning);
        }
        if reference.host_generation != self.generation {
            return Err(ErrorCode::StaleHost);
        }
        let terminal = self
            .terminals
            .lock()
            .unwrap()
            .get(&reference.target.pane_id)
            .cloned()
            .ok_or(ErrorCode::NotFound)?;
        if terminal.reference != reference {
            return Err(ErrorCode::StaleRuntime);
        }
        Ok(terminal)
    }
    pub fn attach(
        &self,
        reference: RuntimeRef,
        owner: u64,
        sink: Sink,
        request_id: u64,
    ) -> Result<(AttachmentRef, Response), ErrorCode> {
        let terminal = self.find(reference)?;
        let mut state = terminal.state.lock().unwrap();
        if !matches!(state.process, ProcessState::Running { .. }) {
            return Err(ErrorCode::NotRunning);
        }
        if state.attachment.is_some() {
            return Err(ErrorCode::AlreadyAttached);
        }
        let attachment = AttachmentRef {
            runtime: reference,
            attachment_id: AttachmentId::new(),
        };
        let snapshot = TerminalSnapshot {
            runtime: reference,
            process: state.process.clone(),
            attached: true,
            backlog_bytes: state.backlog.len(),
        };
        let backlog = RawBacklog {
            start_offset: state.next_offset - state.backlog.len() as u64,
            next_offset: state.next_offset,
            truncated: state.next_offset > state.backlog.len() as u64,
            data: state.backlog.iter().copied().collect(),
        };
        // Publish attachment/backlog under the same lock as output; no gap or duplicate live bytes.
        let response = Response::Attached {
            attachment,
            terminal: snapshot,
            backlog,
        };
        if !sink.send(Frame::Response {
            request_id,
            response: response.clone(),
        }) {
            return Err(ErrorCode::Capacity);
        }
        state.attachment = Some(Attachment {
            owner,
            reference: attachment,
            sink,
        });
        Ok((attachment, response))
    }
    pub fn input(
        &self,
        attachment: AttachmentRef,
        owner: u64,
        data: &[u8],
    ) -> Result<usize, ErrorCode> {
        if data.len() > 4096 {
            return Err(ErrorCode::InvalidRequest);
        }
        let terminal = self.find(attachment.runtime)?;
        let state = terminal.state.lock().unwrap();
        terminal.require_attachment(&state, owner, attachment)?;
        let controller = terminal.controller.lock().unwrap();
        let controller = controller.as_ref().ok_or(ErrorCode::NotRunning)?;
        (&**controller)
            .write(data)
            .map_err(|_| ErrorCode::InputBlocked)
    }
    pub fn resize(
        &self,
        attachment: AttachmentRef,
        owner: u64,
        rows: u16,
        columns: u16,
    ) -> Result<(), ErrorCode> {
        let terminal = self.find(attachment.runtime)?;
        let state = terminal.state.lock().unwrap();
        terminal.require_attachment(&state, owner, attachment)?;
        let controller = terminal.controller.lock().unwrap();
        pty::resize(
            controller.as_ref().ok_or(ErrorCode::NotRunning)?,
            rows,
            columns,
        )
        .map_err(|_| ErrorCode::InvalidSize)
    }
    pub fn detach(&self, attachment: AttachmentRef, owner: u64) -> Result<(), ErrorCode> {
        let terminal = self.find(attachment.runtime)?;
        let mut state = terminal.state.lock().unwrap();
        if !state
            .attachment
            .as_ref()
            .is_some_and(|value| value.owner == owner && value.reference == attachment)
        {
            return Err(ErrorCode::StaleAttachment);
        }
        state.attachment = None;
        Ok(())
    }
    pub fn disconnect(&self, owner: u64) {
        for terminal in self.terminals.lock().unwrap().values() {
            let mut state = terminal.state.lock().unwrap();
            if state
                .attachment
                .as_ref()
                .is_some_and(|value| value.owner == owner)
            {
                state.attachment = None;
            }
        }
    }
    pub fn stop(&self, reference: RuntimeRef) -> Result<(), ErrorCode> {
        let terminal = self.find(reference)?;
        if !terminal.stop(libc::SIGTERM)? {
            return Ok(());
        }
        // Only the first stop transition gets an escalation worker; repeated requests stay bounded.
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(1));
            let _ = terminal.stop(libc::SIGKILL);
        });
        Ok(())
    }
    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        let owned: Vec<_> = self.terminals.lock().unwrap().values().cloned().collect();
        if owned.is_empty() {
            return;
        }
        for terminal in &owned {
            let _ = terminal.stop(libc::SIGTERM);
        }
        thread::sleep(Duration::from_secs(1));
        for terminal in &owned {
            let _ = terminal.stop(libc::SIGKILL);
        }
        for _ in 0..80 {
            if owned
                .iter()
                .all(|value| value.state.lock().unwrap().journal_finished)
            {
                break;
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
}

fn drain(terminal: Arc<Terminal>, controller: Arc<File>) {
    let mut reader = &*controller;
    let mut buffer = [0u8; OUTPUT_CHUNK];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                let mut state = terminal.state.lock().unwrap();
                let offset = state.next_offset;
                let Some(next) = offset.checked_add(count as u64) else {
                    break;
                };
                state.next_offset = next;
                for byte in &buffer[..count] {
                    if state.backlog.len() == BACKLOG_BYTES {
                        state.backlog.pop_front();
                    }
                    state.backlog.push_back(*byte);
                }
                if let Some(attachment) = &state.attachment
                    && !attachment.sink.send(Frame::Output {
                        attachment: attachment.reference,
                        offset,
                        data: buffer[..count].to_vec(),
                    })
                {
                    state.attachment = None;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut fd = libc::pollfd {
                    fd: controller.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                unsafe {
                    libc::poll(&mut fd, 1, 100);
                }
            }
            Err(_) => break,
        }
    }
    let mut state = terminal.state.lock().unwrap();
    state.output_finished = true;
    terminal.controller.lock().unwrap().take();
    if let ProcessState::Exited { wait_status } = state.process {
        send_exit(&state, wait_status);
    }
}
fn send_exit(state: &State, wait_status: i32) {
    if let Some(attachment) = &state.attachment {
        attachment.sink.send(Frame::Exited {
            attachment: attachment.reference,
            wait_status,
        });
    }
}
fn reap(terminal: Arc<Terminal>, pid: i32) {
    loop {
        let ended = {
            let mut state = terminal.state.lock().unwrap();
            let mut wait_status = 0;
            let result = unsafe { libc::waitpid(pid, &mut wait_status, libc::WNOHANG) };
            if result == pid {
                state.process = ProcessState::Exited { wait_status };
                if state.output_finished {
                    send_exit(&state, wait_status);
                }
                Some(state.process.clone())
            } else if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
            {
                state.process = ProcessState::RecoveryRequired {};
                Some(state.process.clone())
            } else {
                None
            }
        };
        if let Some(process) = ended {
            // No runtime lock is held while committing; a stale generation cannot overwrite its successor.
            let _ = terminal
                .journal
                .lock()
                .unwrap()
                .update(terminal.reference, process);
            terminal.state.lock().unwrap().journal_finished = true;
            return;
        }
        thread::sleep(Duration::from_millis(25));
    }
}
