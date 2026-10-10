use crate::{journal::Journal, model::*, pty, terminal::*};
use std::collections::{BTreeMap, VecDeque};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
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
    pub disconnected: Arc<AtomicBool>,
}
impl Sink {
    pub fn send(&self, frame: Frame) -> bool {
        if self.sender.try_send(frame).is_err() {
            self.disconnected.store(true, Ordering::SeqCst);
            return false;
        }
        true
    }
}
pub struct AttachedTerminal {
    pub attachment: AttachmentRef,
    pub initial: Frame,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OutputState {
    Draining,
    Closed,
    Failed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProcessGroupState {
    Unobserved,
    Empty,
    Uncertain,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CompletionPersistence {
    Pending,
    Recorded,
    Failed,
}
enum StopTransition {
    Signaled,
    AlreadyStopped,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum ProcessSignal {
    Terminate,
    Kill,
}
impl ProcessSignal {
    fn as_raw(self) -> i32 {
        match self {
            Self::Terminate => libc::SIGTERM,
            Self::Kill => libc::SIGKILL,
        }
    }
}

struct Attachment {
    owner: ClientId,
    reference: AttachmentRef,
    sink: Sink,
}
struct CompletionRecord {
    process: ProcessState,
    persistence: CompletionPersistence,
}

struct State {
    process: ProcessState,
    attachment: Option<Attachment>,
    backlog: VecDeque<u8>,
    next_offset: u64,
    output: OutputState,
    process_group: ProcessGroupState,
    completion: CompletionPersistence,
}
impl State {
    fn visible_process(&self) -> ProcessState {
        if matches!(self.process, ProcessState::Exited { .. })
            && (self.process_group != ProcessGroupState::Empty
                || self.output == OutputState::Failed)
        {
            return ProcessState::RecoveryRequired {};
        }
        self.process.clone()
    }
    fn completion_record(&self) -> Option<CompletionRecord> {
        let process = match (&self.process, self.output) {
            (ProcessState::Exited { .. }, OutputState::Closed)
                if self.process_group == ProcessGroupState::Empty =>
            {
                self.process.clone()
            }
            (ProcessState::Exited { .. } | ProcessState::RecoveryRequired {}, _) => {
                ProcessState::RecoveryRequired {}
            }
            _ => return None,
        };
        let persistence = if self.output == OutputState::Draining {
            CompletionPersistence::Pending
        } else {
            CompletionPersistence::Recorded
        };
        Some(CompletionRecord {
            process,
            persistence,
        })
    }
}

struct Terminal {
    reference: RuntimeRef,
    controller: Mutex<Option<Arc<File>>>,
    state: Mutex<State>,
    journal: Arc<Mutex<Journal>>,
    completion_writer: Mutex<()>,
}
impl Terminal {
    fn owns_live_resources(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.output == OutputState::Draining
            || state.process_group == ProcessGroupState::Uncertain
            || state.completion == CompletionPersistence::Pending
            || matches!(
                state.process,
                ProcessState::Running { .. }
                    | ProcessState::Stopping { .. }
                    | ProcessState::RecoveryRequired {}
            )
    }
    fn snapshot(&self) -> TerminalSnapshot {
        let state = self.state.lock().unwrap();
        TerminalSnapshot {
            runtime: self.reference,
            process: state.visible_process(),
            attached: state.attachment.is_some(),
            backlog_bytes: state.backlog.len(),
        }
    }
    fn stop(&self, signal: ProcessSignal) -> Result<StopTransition, ErrorCode> {
        let mut state = self.state.lock().unwrap();
        let pid = match state.process {
            ProcessState::Running { pid } => pid,
            ProcessState::Stopping { pid } if signal == ProcessSignal::Kill => pid,
            _ => return Ok(StopTransition::AlreadyStopped),
        };
        // The same state lock protects waitpid and signaling; never signal a reaped/reused PID.
        if unsafe { libc::kill(-pid.as_raw(), signal.as_raw()) } < 0
            && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
        {
            return Err(ErrorCode::NotRunning);
        }
        state.process = ProcessState::Stopping { pid };
        Ok(StopTransition::Signaled)
    }

    fn record_completion(&self) {
        // Reaper and reader may finish in either order. Serialize their journal writes so
        // an interim recovery record can never overwrite a later, proven clean completion.
        let _writer = self.completion_writer.lock().unwrap();
        let Some(record) = self.state.lock().unwrap().completion_record() else {
            return;
        };
        let result = self
            .journal
            .lock()
            .unwrap()
            .update(self.reference, record.process);
        self.state.lock().unwrap().completion = match result {
            Ok(()) => record.persistence,
            Err(_) => CompletionPersistence::Failed,
        };
    }
    fn record_output(&self, data: &[u8]) -> Result<(), ErrorCode> {
        let mut state = self.state.lock().unwrap();
        let offset = state.next_offset;
        state.next_offset = offset
            .checked_add(data.len() as u64)
            .ok_or(ErrorCode::Capacity)?;
        for byte in data {
            if state.backlog.len() == BACKLOG_BYTES {
                state.backlog.pop_front();
            }
            state.backlog.push_back(*byte);
        }
        if let Some(attachment) = &state.attachment
            && !attachment.sink.send(Frame::Output {
                attachment: attachment.reference,
                offset,
                data: data.to_vec(),
            })
        {
            state.attachment = None;
        }
        Ok(())
    }

    fn finish_output(&self, outcome: OutputState) {
        {
            let mut state = self.state.lock().unwrap();
            state.output = outcome;
            self.controller.lock().unwrap().take();
            if outcome == OutputState::Failed {
                if let Some(attachment) = state.attachment.take() {
                    attachment.sink.disconnected.store(true, Ordering::SeqCst);
                }
            } else if let ProcessState::Exited { wait_status } = state.process {
                send_exit(&state, wait_status);
            }
        }
        self.record_completion();
    }

    fn require_attachment(
        &self,
        state: &State,
        owner: ClientId,
        reference: AttachmentRef,
    ) -> Result<(), ErrorCode> {
        if !matches!(state.process, ProcessState::Running { .. })
            || state.output != OutputState::Draining
        {
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

struct SpawnedTerminal {
    terminal: Arc<Terminal>,
    pid: ChildPid,
    reader: Arc<File>,
}
impl SpawnedTerminal {
    fn new(reference: RuntimeRef, child: pty::ChildTerminal, journal: Arc<Mutex<Journal>>) -> Self {
        let reader = Arc::new(child.controller);
        let terminal = Arc::new(Terminal {
            reference,
            controller: Mutex::new(Some(reader.clone())),
            journal,
            completion_writer: Mutex::new(()),
            state: Mutex::new(State {
                process: ProcessState::Running { pid: child.pid },
                attachment: None,
                backlog: VecDeque::with_capacity(BACKLOG_BYTES),
                next_offset: 0,
                output: OutputState::Draining,
                process_group: ProcessGroupState::Unobserved,
                completion: CompletionPersistence::Pending,
            }),
        });
        Self {
            terminal,
            pid: child.pid,
            reader,
        }
    }
    fn supervise(self) {
        let drain_owner = self.terminal.clone();
        thread::spawn(move || drain(drain_owner, self.reader));
        thread::spawn(move || reap(self.terminal, self.pid));
    }
}

pub struct Manager {
    pub generation: HostGeneration,
    journal: Arc<Mutex<Journal>>,
    pub(crate) work: Arc<Mutex<crate::work::WorkStore>>,
    admission: Mutex<()>,
    terminals: Mutex<BTreeMap<PaneId, Arc<Terminal>>>,
    stopping: AtomicBool,
}
impl Manager {
    pub fn new(journal: Journal) -> Self {
        Self {
            generation: HostGeneration::new(),
            work: journal.work.clone(),
            admission: Mutex::new(()),
            journal: Arc::new(Mutex::new(journal)),
            terminals: Mutex::new(BTreeMap::new()),
            stopping: AtomicBool::new(false),
        }
    }
    pub(crate) fn command_receipt(
        &self,
        command: CommandId,
    ) -> Option<crate::work::CommandReceipt> {
        let _admission = self.admission.lock().unwrap();
        if let Some(committed) = self.work.lock().unwrap().receipt(command) {
            return Some(crate::work::CommandReceipt::Work { committed });
        }
        let runtime = self.journal.lock().unwrap().command_runtime(command)?;
        let terminal = self.list().into_iter().find(|t| t.runtime == runtime);
        Some(crate::work::CommandReceipt::Runtime { runtime, terminal })
    }
    pub(crate) fn mutate_work(
        &self,
        command: CommandId,
        intent: crate::work::WorkIntent,
        profiles: &BTreeMap<String, TerminalLaunch>,
    ) -> Result<crate::work::CommittedWork, crate::work::WorkError> {
        let _admission = self.admission.lock().unwrap();
        if self.stopping.load(Ordering::SeqCst) {
            return Err(crate::work::WorkError::Rejected);
        }
        {
            let journal = self.journal.lock().unwrap();
            if journal.is_fenced() {
                return Err(crate::work::WorkError::StorageFailed);
            }
            if journal.contains_command(command) {
                return Err(crate::work::WorkError::Conflict);
            }
        }
        self.work.lock().unwrap().apply(command, intent, profiles)
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
        self.start_inner(command, target, launch, false)
            .map(|(terminal, _)| terminal)
    }
    /// The daemon owner receives the anonymous control endpoint, never a viewing client.
    /// Reconciliation cannot recreate/retarget an already-issued endpoint.
    pub fn start_with_control(
        &self,
        command: CommandId,
        target: TerminalTarget,
        launch: &TerminalLaunch,
    ) -> Result<(TerminalSnapshot, UnixStream), ErrorCode> {
        let (terminal, channel) = self.start_inner(command, target, launch, true)?;
        Ok((terminal, channel.ok_or(ErrorCode::RecoveryRequired)?))
    }
    fn start_inner(
        &self,
        command: CommandId,
        target: TerminalTarget,
        launch: &TerminalLaunch,
        controlled: bool,
    ) -> Result<(TerminalSnapshot, Option<UnixStream>), ErrorCode> {
        let _admission = self.admission.lock().unwrap();
        {
            let work = self.work.lock().unwrap();
            if work.is_fenced() {
                return Err(ErrorCode::StorageFailed);
            }
            if work.contains_command(command) {
                return Err(ErrorCode::Conflict);
            }
        }
        let mut terminals = self.terminals.lock().unwrap();
        if self.stopping.load(Ordering::SeqCst) {
            return Err(ErrorCode::NotRunning);
        }
        let previous = self
            .journal
            .lock()
            .unwrap()
            .lookup_mode(command, target, launch, controlled)?;
        if let Some(previous) = previous {
            return self
                .reconcile_start(previous, &terminals)
                .map(|terminal| (terminal, None));
        }
        check_launch_admission(&terminals, target)?;
        let reference = RuntimeRef {
            host_generation: self.generation,
            target,
            runtime_generation: RuntimeGeneration::new(),
        };
        self.journal
            .lock()
            .unwrap()
            .prepare_mode(command, reference, launch, controlled)?;
        // Intent precedes fork; child supervision must start even if its Running commit fails.
        let (spawned, channel) = self.spawn_terminal(reference, launch, controlled)?;
        let terminal = spawned.terminal.clone();
        terminals.insert(target.pane_id, terminal.clone());
        let persisted = self
            .journal
            .lock()
            .unwrap()
            .update(reference, ProcessState::Running { pid: spawned.pid });
        spawned.supervise();
        persisted?;
        Ok((terminal.snapshot(), channel))
    }

    fn reconcile_start(
        &self,
        previous: RuntimeRef,
        terminals: &BTreeMap<PaneId, Arc<Terminal>>,
    ) -> Result<TerminalSnapshot, ErrorCode> {
        let snapshot = terminals
            .get(&previous.target.pane_id)
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
        match snapshot.process {
            ProcessState::Failed {} => Err(ErrorCode::LaunchFailed),
            ProcessState::RecoveryRequired {} | ProcessState::Starting {} => {
                Err(ErrorCode::RecoveryRequired)
            }
            _ => Ok(snapshot),
        }
    }

    fn spawn_terminal(
        &self,
        reference: RuntimeRef,
        launch: &TerminalLaunch,
        controlled: bool,
    ) -> Result<(SpawnedTerminal, Option<UnixStream>), ErrorCode> {
        let child = if controlled {
            pty::spawn_with_control(&launch.directory, &launch.argv)
                .map(|(child, channel)| (child, Some(channel)))
        } else {
            pty::spawn(&launch.directory, &launch.argv).map(|child| (child, None))
        };
        match child {
            Ok((child, channel)) => Ok((
                SpawnedTerminal::new(reference, child, self.journal.clone()),
                channel,
            )),
            Err(_) => {
                self.journal
                    .lock()
                    .unwrap()
                    .update(reference, ProcessState::Failed {})?;
                Err(ErrorCode::LaunchFailed)
            }
        }
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
        owner: ClientId,
        sink: Sink,
    ) -> Result<AttachedTerminal, ErrorCode> {
        let terminal = self.find(reference)?;
        let mut state = terminal.state.lock().unwrap();
        if !matches!(state.process, ProcessState::Running { .. })
            || state.output != OutputState::Draining
        {
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
        let initial = Frame::Attached {
            attachment,
            terminal: snapshot,
            backlog,
        };
        if !sink.send(initial.clone()) {
            return Err(ErrorCode::Capacity);
        }
        state.attachment = Some(Attachment {
            owner,
            reference: attachment,
            sink,
        });
        Ok(AttachedTerminal {
            attachment,
            initial,
        })
    }
    pub fn input(
        &self,
        attachment: AttachmentRef,
        owner: ClientId,
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
        owner: ClientId,
        rows: u16,
        columns: u16,
    ) -> Result<(), ErrorCode> {
        let dimensions = TerminalSize::new(rows, columns).map_err(|_| ErrorCode::InvalidSize)?;
        let terminal = self.find(attachment.runtime)?;
        let state = terminal.state.lock().unwrap();
        terminal.require_attachment(&state, owner, attachment)?;
        let controller = terminal.controller.lock().unwrap();
        pty::resize(
            controller.as_ref().ok_or(ErrorCode::NotRunning)?,
            dimensions,
        )
        .map_err(|_| ErrorCode::InvalidSize)
    }
    pub fn detach(&self, attachment: AttachmentRef, owner: ClientId) -> Result<(), ErrorCode> {
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
    pub fn disconnect(&self, owner: ClientId) {
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
        if let StopTransition::AlreadyStopped = terminal.stop(ProcessSignal::Terminate)? {
            return Ok(());
        }
        // Only the first stop transition gets an escalation worker; repeated requests stay bounded.
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(1));
            let _ = terminal.stop(ProcessSignal::Kill);
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
            let _ = terminal.stop(ProcessSignal::Terminate);
        }
        thread::sleep(Duration::from_secs(1));
        for terminal in &owned {
            let _ = terminal.stop(ProcessSignal::Kill);
        }
        for _ in 0..80 {
            if owned.iter().all(|value| {
                let state = value.state.lock().unwrap();
                state.completion != CompletionPersistence::Pending
                    && state.output != OutputState::Draining
            }) {
                break;
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
}

fn check_launch_admission(
    terminals: &BTreeMap<PaneId, Arc<Terminal>>,
    target: TerminalTarget,
) -> Result<(), ErrorCode> {
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
    Ok(())
}

fn drain(terminal: Arc<Terminal>, controller: Arc<File>) {
    let mut reader = &*controller;
    let mut buffer = [0u8; OUTPUT_CHUNK];
    let outcome = loop {
        match reader.read(&mut buffer) {
            Ok(0) => break OutputState::Closed,
            Ok(count) => {
                if terminal.record_output(&buffer[..count]).is_err() {
                    break OutputState::Failed;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if wait_for_output(controller.as_raw_fd()).is_err() {
                    break OutputState::Failed;
                }
            }
            // PTY EOF may be reported as EIO after its last child-side descriptor closes.
            Err(error) if error.raw_os_error() == Some(libc::EIO) => break OutputState::Closed,
            Err(_) => break OutputState::Failed,
        }
    };
    terminal.finish_output(outcome);
}

fn wait_for_output(descriptor: i32) -> io::Result<()> {
    let mut fd = libc::pollfd {
        fd: descriptor,
        events: libc::POLLIN,
        revents: 0,
    };
    if unsafe { libc::poll(&mut fd, 1, 100) } < 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    Ok(())
}
fn send_exit(state: &State, wait_status: i32) {
    if let Some(attachment) = &state.attachment {
        attachment.sink.send(Frame::Exited {
            attachment: attachment.reference,
            wait_status,
        });
    }
}
fn observe_process_group(pid: ChildPid) -> ProcessGroupState {
    // Signal 0 delivers no signal: it is an existence/permission probe only.
    // Reuse of this numeric group can only cause conservative recovery, never a kill/adoption.
    // This proves nothing about descendants that deliberately left the original group.
    if unsafe { libc::kill(-pid.as_raw(), 0) } < 0
        && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    {
        ProcessGroupState::Empty
    } else {
        ProcessGroupState::Uncertain
    }
}

fn reap(terminal: Arc<Terminal>, pid: ChildPid) {
    loop {
        let ended = {
            let mut state = terminal.state.lock().unwrap();
            let mut wait_status = 0;
            let result = unsafe { libc::waitpid(pid.as_raw(), &mut wait_status, libc::WNOHANG) };
            if result == pid.as_raw() {
                state.process_group = observe_process_group(pid);
                state.process = ProcessState::Exited { wait_status };
                if state.output == OutputState::Closed {
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
        if ended.is_some() {
            terminal.record_completion();
            return;
        }
        thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;

    struct CompletionFixture {
        terminal: Arc<Terminal>,
        directory: TestDirectory,
    }
    impl CompletionFixture {
        fn new() -> Self {
            let directory = TestDirectory::new();
            let mut journal = Journal::open(directory.path()).unwrap();
            let reference = RuntimeRef {
                host_generation: HostGeneration::new(),
                target: TerminalTarget {
                    session_id: SessionId::new(),
                    pane_id: PaneId::new(),
                },
                runtime_generation: RuntimeGeneration::new(),
            };
            let launch = TerminalLaunch {
                directory: "/".into(),
                argv: vec!["/bin/sh".into()],
            };
            let process = ProcessState::Running {
                pid: ChildPid::try_from(42).unwrap(),
            };
            journal
                .prepare(CommandId::new(), reference, &launch)
                .unwrap();
            journal.update(reference, process.clone()).unwrap();
            // Synthetic completion state only: no process is launched or signaled by these unit tests.
            let terminal = Arc::new(Terminal {
                reference,
                controller: Mutex::new(None),
                completion_writer: Mutex::new(()),
                journal: Arc::new(Mutex::new(journal)),
                state: Mutex::new(State {
                    process,
                    attachment: None,
                    backlog: VecDeque::new(),
                    next_offset: 0,
                    output: OutputState::Draining,
                    process_group: ProcessGroupState::Unobserved,
                    completion: CompletionPersistence::Pending,
                }),
            });
            Self {
                terminal,
                directory,
            }
        }
        fn saved_process(&self) -> ProcessState {
            self.terminal.journal.lock().unwrap().snapshots()[0]
                .process
                .clone()
        }
        fn observe_exit(&self) {
            let mut state = self.terminal.state.lock().unwrap();
            state.process = ProcessState::Exited { wait_status: 0 };
            state.process_group = ProcessGroupState::Empty;
        }
    }

    #[test]
    fn reaped_child_is_uncertain_until_terminal_eof_then_becomes_clean() {
        let fixture = CompletionFixture::new();
        fixture.observe_exit();
        fixture.terminal.record_completion();
        assert_eq!(fixture.saved_process(), ProcessState::RecoveryRequired {});
        assert!(fixture.terminal.owns_live_resources());
        fixture.terminal.finish_output(OutputState::Closed);
        assert_eq!(
            fixture.saved_process(),
            ProcessState::Exited { wait_status: 0 }
        );
        assert!(!fixture.terminal.owns_live_resources());
    }

    #[test]
    fn terminal_eof_alone_does_not_claim_child_exit() {
        let fixture = CompletionFixture::new();
        fixture.terminal.finish_output(OutputState::Closed);
        assert!(matches!(
            fixture.saved_process(),
            ProcessState::Running { .. }
        ));
        assert!(fixture.terminal.owns_live_resources());
        fixture.observe_exit();
        fixture.terminal.record_completion();
        assert_eq!(
            fixture.saved_process(),
            ProcessState::Exited { wait_status: 0 }
        );
    }

    #[test]
    fn eof_with_uncertain_group_membership_stays_recovery_required() {
        let fixture = CompletionFixture::new();
        fixture.observe_exit();
        fixture.terminal.state.lock().unwrap().process_group = ProcessGroupState::Uncertain;
        fixture.terminal.finish_output(OutputState::Closed);
        assert_eq!(fixture.saved_process(), ProcessState::RecoveryRequired {});
        assert_eq!(
            fixture.terminal.snapshot().process,
            ProcessState::RecoveryRequired {}
        );
        assert!(fixture.terminal.owns_live_resources());
    }

    #[test]
    fn failed_terminal_io_never_becomes_a_clean_completion() {
        let fixture = CompletionFixture::new();
        fixture.observe_exit();
        fixture.terminal.finish_output(OutputState::Failed);
        assert_eq!(fixture.saved_process(), ProcessState::RecoveryRequired {});
    }

    #[test]
    fn completion_persistence_failure_is_not_reported_as_recorded() {
        let fixture = CompletionFixture::new();
        let path = fixture.directory.path().join("runtime-state.json");
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        fixture.observe_exit();
        fixture.terminal.finish_output(OutputState::Closed);
        assert_eq!(
            fixture.terminal.state.lock().unwrap().completion,
            CompletionPersistence::Failed
        );
    }
}
