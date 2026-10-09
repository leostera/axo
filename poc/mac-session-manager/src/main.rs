//! Isolated macOS PTY ownership spike. Not Axo's production broker or transcript model.
#[cfg(not(target_os = "macos"))]
compile_error!("This POC currently targets macOS");
mod pty;

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::{
    fs::MetadataExt,
    fs::PermissionsExt,
    net::{UnixListener, UnixStream},
};
use std::path::Path;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, AtomicUsize, Ordering},
    mpsc::{self, SyncSender},
};
use std::thread;
use std::time::Duration;

const FRAME_BYTES: u64 = 64 * 1024;
const BACKLOG_BYTES: usize = 16 * 1024;
const OUTPUT_CHUNK: usize = 1024;
const MAX_SESSIONS: usize = 8;
const MAX_CLIENTS: usize = 16;

type Sessions = Arc<Mutex<BTreeMap<SessionId, Arc<Session>>>>;

#[derive(Clone, Debug, Ord, PartialOrd, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
struct SessionId(String);
impl TryFrom<String> for SessionId {
    type Error = &'static str;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() != 32
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err("Invalid POC session ID");
        }
        Ok(Self(value))
    }
}
impl From<SessionId> for String {
    fn from(value: SessionId) -> Self {
        value.0
    }
}
fn new_id() -> io::Result<SessionId> {
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(SessionId(
        bytes.iter().map(|byte| format!("{byte:02x}")).collect(),
    ))
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Create {
        cwd: String,
        argv: Vec<String>,
    },
    List {},
    Attach {
        session: SessionId,
    },
    Input {
        session: SessionId,
        data: Vec<u8>,
    },
    Resize {
        session: SessionId,
        rows: u16,
        columns: u16,
    },
    Stop {
        session: SessionId,
    },
    Detach {},
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum ProcessState {
    Running { pid: libc::pid_t },
    Stopping { pid: libc::pid_t },
    Exited { wait_status: i32 },
    RecoveryRequired,
}
#[derive(Serialize)]
struct Snapshot {
    id: SessionId,
    process: ProcessState,
    attached: bool,
    backlog_bytes: usize,
}
#[derive(Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum Event {
    Created {
        session: Snapshot,
    },
    Sessions {
        sessions: Vec<Snapshot>,
    },
    Attached {
        session: Snapshot,
    },
    Output {
        session: SessionId,
        data: Vec<u8>,
    },
    InputAccepted {
        bytes: usize,
    },
    Ok,
    Exited {
        session: SessionId,
        wait_status: i32,
    },
    Error {
        message: String,
    },
}

#[derive(Clone)]
struct Sink {
    sender: SyncSender<Event>,
    socket: Arc<UnixStream>,
}
impl Sink {
    fn send(&self, event: Event) -> bool {
        if self.sender.try_send(event).is_err() {
            let _ = self.socket.shutdown(std::net::Shutdown::Both);
            return false;
        }
        true
    }
}
struct Attachment {
    client: u64,
    sink: Sink,
}
struct TerminalState {
    process: ProcessState,
    attachment: Option<Attachment>,
    backlog: VecDeque<u8>,
    output_finished: bool,
}
struct Session {
    id: SessionId,
    controller: File,
    state: Mutex<TerminalState>,
}
impl Session {
    fn snapshot(&self) -> Snapshot {
        let state = self.state.lock().unwrap();
        Snapshot {
            id: self.id.clone(),
            process: state.process.clone(),
            attached: state.attachment.is_some(),
            backlog_bytes: state.backlog.len(),
        }
    }
    fn require_input_owner(&self, client: u64, state: &TerminalState) -> io::Result<()> {
        if !matches!(state.process, ProcessState::Running { .. }) {
            return Err(io::Error::other("Child is not running"));
        }
        if state.attachment.as_ref().map(|value| value.client) != Some(client) {
            return Err(io::Error::other(
                "This client does not own the terminal attachment",
            ));
        }
        Ok(())
    }
    fn stop(&self, signal: i32) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        let pid = match state.process {
            ProcessState::Running { pid } | ProcessState::Stopping { pid } => pid,
            _ => return Ok(()),
        };
        // Reaping uses this same lock: never signal an already-reaped/reused process ID.
        if unsafe { libc::kill(-pid, signal) } < 0
            && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
        {
            return Err(io::Error::last_os_error());
        }
        state.process = ProcessState::Stopping { pid };
        Ok(())
    }
}

fn start_session(cwd: &str, argv: &[String]) -> io::Result<Arc<Session>> {
    let id = new_id()?;
    let child = pty::spawn(cwd, argv)?;
    let session = Arc::new(Session {
        id,
        controller: child.controller,
        state: Mutex::new(TerminalState {
            process: ProcessState::Running { pid: child.pid },
            attachment: None,
            backlog: VecDeque::with_capacity(BACKLOG_BYTES),
            output_finished: false,
        }),
    });
    let output_owner = session.clone();
    thread::spawn(move || drain_terminal(output_owner));
    let process_owner = session.clone();
    thread::spawn(move || observe_exit(process_owner, child.pid));
    Ok(session)
}

fn drain_terminal(session: Arc<Session>) {
    let mut buffer = [0u8; OUTPUT_CHUNK];
    let mut reader = &session.controller;
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                finish_output(&session);
                return;
            }
            Ok(length) => {
                let mut state = session.state.lock().unwrap();
                for byte in &buffer[..length] {
                    if state.backlog.len() == BACKLOG_BYTES {
                        state.backlog.pop_front();
                    }
                    state.backlog.push_back(*byte);
                }
                if let Some(attachment) = &state.attachment
                    && !attachment.sink.send(Event::Output {
                        session: session.id.clone(),
                        data: buffer[..length].to_vec(),
                    })
                {
                    state.attachment = None;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut fd = libc::pollfd {
                    fd: session.controller.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                unsafe {
                    libc::poll(&mut fd, 1, 100);
                }
            }
            Err(_) => {
                finish_output(&session);
                return;
            }
        }
    }
}

fn finish_output(session: &Session) {
    let mut state = session.state.lock().unwrap();
    state.output_finished = true;
    if let ProcessState::Exited { wait_status } = state.process {
        send_exit(session, &state, wait_status);
    }
}

fn send_exit(session: &Session, state: &TerminalState, wait_status: i32) {
    if let Some(attachment) = &state.attachment {
        attachment.sink.send(Event::Exited {
            session: session.id.clone(),
            wait_status,
        });
    }
}

fn observe_exit(session: Arc<Session>, pid: libc::pid_t) {
    loop {
        {
            let mut state = session.state.lock().unwrap();
            let mut status = 0;
            let result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            if result == pid {
                state.process = ProcessState::Exited {
                    wait_status: status,
                };
                if state.output_finished {
                    send_exit(&session, &state, status);
                }
                return;
            }
            if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                state.process = ProcessState::RecoveryRequired;
                return;
            }
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn find_session(sessions: &Sessions, id: &SessionId) -> io::Result<Arc<Session>> {
    sessions
        .lock()
        .unwrap()
        .get(id)
        .cloned()
        .ok_or_else(|| io::Error::other("Unknown POC session"))
}

fn attach(session: &Session, client: u64, sink: &Sink) -> io::Result<()> {
    let mut state = session.state.lock().unwrap();
    if state.attachment.is_some() {
        return Err(io::Error::other(
            "Terminal already has an interactive attachment",
        ));
    }
    if !matches!(state.process, ProcessState::Running { .. }) {
        return Err(io::Error::other("Child is not running"));
    }
    if !sink.send(Event::Attached {
        session: Snapshot {
            id: session.id.clone(),
            process: state.process.clone(),
            attached: true,
            backlog_bytes: state.backlog.len(),
        },
    }) {
        return Err(io::Error::other("Attachment disconnected"));
    }
    let backlog: Vec<u8> = state.backlog.iter().copied().collect();
    for chunk in backlog.chunks(OUTPUT_CHUNK) {
        if !sink.send(Event::Output {
            session: session.id.clone(),
            data: chunk.to_vec(),
        }) {
            return Err(io::Error::other("Attachment output queue is full"));
        }
    }
    state.attachment = Some(Attachment {
        client,
        sink: sink.clone(),
    });
    Ok(())
}

fn handle(
    request: Request,
    sessions: &Sessions,
    client: u64,
    sink: &Sink,
    attached: &mut Option<SessionId>,
) -> io::Result<()> {
    match request {
        Request::Create { cwd, argv } => {
            let mut registry = sessions.lock().unwrap();
            if registry.len() >= MAX_SESSIONS {
                return Err(io::Error::other("POC session limit reached"));
            }
            let session = start_session(&cwd, &argv)?;
            sink.send(Event::Created {
                session: session.snapshot(),
            });
            registry.insert(session.id.clone(), session);
        }
        Request::List {} => {
            let values = sessions
                .lock()
                .unwrap()
                .values()
                .map(|value| value.snapshot())
                .collect();
            sink.send(Event::Sessions { sessions: values });
        }
        Request::Attach { session } => {
            if attached.is_some() {
                return Err(io::Error::other("Detach before attaching another terminal"));
            }
            let terminal = find_session(sessions, &session)?;
            attach(&terminal, client, sink)?;
            *attached = Some(session);
        }
        Request::Input { session, data } => {
            if data.len() > 4096 {
                return Err(io::Error::other("Input exceeds 4096 bytes"));
            }
            let terminal = find_session(sessions, &session)?;
            let state = terminal.state.lock().unwrap();
            terminal.require_input_owner(client, &state)?;
            let bytes = (&terminal.controller).write(&data)?;
            sink.send(Event::InputAccepted { bytes }); // Partial acceptance is explicit, never silently replayed.
        }
        Request::Resize {
            session,
            rows,
            columns,
        } => {
            let terminal = find_session(sessions, &session)?;
            let state = terminal.state.lock().unwrap();
            terminal.require_input_owner(client, &state)?;
            pty::resize(&terminal.controller, rows, columns)?;
            sink.send(Event::Ok);
        }
        Request::Stop { session } => {
            let terminal = find_session(sessions, &session)?;
            terminal.stop(libc::SIGTERM)?;
            thread::spawn(move || {
                thread::sleep(Duration::from_secs(1));
                let _ = terminal.stop(libc::SIGKILL);
            });
            sink.send(Event::Ok);
        }
        Request::Detach {} => {
            detach(sessions, client, attached);
            sink.send(Event::Ok);
        }
    }
    Ok(())
}

fn detach(sessions: &Sessions, client: u64, attached: &mut Option<SessionId>) {
    let Some(id) = attached.take() else {
        return;
    };
    let Ok(session) = find_session(sessions, &id) else {
        return;
    };
    let mut state = session.state.lock().unwrap();
    if state.attachment.as_ref().map(|value| value.client) == Some(client) {
        state.attachment = None;
    }
}

fn serve_client(socket: UnixStream, sessions: Sessions, client: u64) -> io::Result<()> {
    check_peer(&socket)?;
    socket.set_write_timeout(Some(Duration::from_millis(500)))?;
    let shared_socket = Arc::new(socket.try_clone()?);
    let (sender, receiver) = mpsc::sync_channel(32);
    let sink = Sink {
        sender,
        socket: shared_socket.clone(),
    };
    thread::spawn(move || {
        let mut writer = &*shared_socket;
        while let Ok(event) = receiver.recv() {
            let Ok(mut frame) = serde_json::to_vec(&event) else {
                break;
            };
            frame.push(b'\n');
            if frame.len() as u64 > FRAME_BYTES || writer.write_all(&frame).is_err() {
                let _ = shared_socket.shutdown(std::net::Shutdown::Both);
                return;
            }
        }
    });
    let mut reader = BufReader::new(socket);
    let mut attached = None;
    loop {
        let mut frame = Vec::new();
        let result = (&mut reader)
            .take(FRAME_BYTES + 1)
            .read_until(b'\n', &mut frame);
        if !matches!(result, Ok(length) if length > 0) {
            break;
        }
        if frame.len() as u64 > FRAME_BYTES || !frame.ends_with(b"\n") {
            sink.send(Event::Error {
                message: "Frame exceeds the POC limit".into(),
            });
            break;
        }
        let outcome = serde_json::from_slice::<Request>(&frame)
            .map_err(|_| io::Error::other("Invalid POC request"))
            .and_then(|request| handle(request, &sessions, client, &sink, &mut attached));
        if let Err(error) = outcome {
            sink.send(Event::Error {
                message: error.to_string(),
            });
        }
    }
    detach(&sessions, client, &mut attached);
    Ok(())
}

fn check_peer(socket: &UnixStream) -> io::Result<()> {
    let (mut uid, mut gid) = (0, 0);
    if unsafe { libc::getpeereid(socket.as_raw_fd(), &mut uid, &mut gid) } < 0
        || uid != unsafe { libc::geteuid() }
    {
        return Err(io::Error::other("Only this OS user may connect"));
    }
    Ok(())
}

fn serve(path: &Path) -> io::Result<()> {
    let root = path
        .parent()
        .ok_or_else(|| io::Error::other("Missing private socket directory"))?;
    let metadata = fs::symlink_metadata(root)?;
    if !path.is_absolute()
        || path.as_os_str().as_encoded_bytes().len() > 90
        || !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::other(
            "Use a short absolute socket path inside an owned private 0700 directory",
        ));
    }
    // Never unlink an existing socket: it could belong to another live host or an uncertain orphan.
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let sessions: Sessions = Arc::new(Mutex::new(BTreeMap::new()));
    let next_client = AtomicU64::new(1);
    let clients = Arc::new(AtomicUsize::new(0));
    for socket in listener.incoming() {
        let socket = socket?;
        if clients
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |value| {
                (value < MAX_CLIENTS).then_some(value + 1)
            })
            .is_err()
        {
            continue;
        }
        let sessions = sessions.clone();
        let clients = clients.clone();
        let client = next_client.fetch_add(1, Ordering::SeqCst);
        thread::spawn(move || {
            let _ = serve_client(socket, sessions, client);
            clients.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.len() != 3 || arguments[1] != "serve" {
        return Err(io::Error::other(
            "Usage: axo-host-poc serve /tmp/private-poc/host.sock",
        ));
    }
    serve(Path::new(&arguments[2]))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn session_ids_are_validated_at_the_wire_boundary() {
        for id in ["", "../../session", "G0000000000000000000000000000000"] {
            assert!(SessionId::try_from(id.to_string()).is_err());
        }
        assert!(SessionId::try_from("0123456789abcdef0123456789abcdef".to_string()).is_ok());
    }
    #[test]
    fn protocol_rejects_unknown_fields_and_operations() {
        assert!(serde_json::from_str::<Request>(r#"{"op":"list","selected":"ambient"}"#).is_err());
        assert!(serde_json::from_str::<Request>(r#"{"op":"broadcast_prompt"}"#).is_err());
    }
}
