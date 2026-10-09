use crate::{
    journal::Journal,
    model::*,
    protocol::*,
    runtime::{Manager, Sink},
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::{
    fd::AsRawFd,
    unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
};
use std::path::Path;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    mpsc,
};
use std::thread;
use std::time::Duration;

struct Cached {
    fingerprint: [u8; 32],
    response: Response,
    bytes: usize,
}
struct Requests {
    highest: u64,
    cache: BTreeMap<u64, Cached>,
    order: VecDeque<u64>,
    bytes: usize,
}
impl Requests {
    fn new() -> Self {
        Self {
            highest: 0,
            cache: BTreeMap::new(),
            order: VecDeque::new(),
            bytes: 0,
        }
    }
    fn previous(&self, request: &Request) -> Result<Option<Response>, ErrorCode> {
        if request.request_id == 0 {
            return Err(ErrorCode::InvalidRequest);
        }
        if let Some(cached) = self.cache.get(&request.request_id) {
            if cached.fingerprint != fingerprint(request) {
                return Err(ErrorCode::Conflict);
            }
            return Ok(Some(cached.response.clone()));
        }
        if request.request_id <= self.highest {
            return Err(ErrorCode::RequestOutOfOrder);
        }
        Ok(None)
    }
    fn remember(&mut self, request: &Request, response: Response) {
        let bytes = serde_json::to_vec(&response)
            .expect("Domain response serializes")
            .len();
        self.highest = request.request_id;
        while self.cache.len() >= 64 || self.bytes + bytes > 128 * 1024 {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if let Some(old) = self.cache.remove(&oldest) {
                self.bytes -= old.bytes;
            }
        }
        self.bytes += bytes;
        self.order.push_back(request.request_id);
        self.cache.insert(
            request.request_id,
            Cached {
                fingerprint: fingerprint(request),
                response,
                bytes,
            },
        );
    }
}
fn fingerprint(request: &Request) -> [u8; 32] {
    Sha256::digest(serde_json::to_vec(request).expect("Domain request serializes")).into()
}

enum ResponseDelivery {
    NeedsQueue,
    AlreadyQueued,
}
struct DispatchOutcome {
    response: Response,
    delivery: ResponseDelivery,
}
impl DispatchOutcome {
    fn pending(response: Response) -> Self {
        Self {
            response,
            delivery: ResponseDelivery::NeedsQueue,
        }
    }
    fn queued(response: Response) -> Self {
        Self {
            response,
            delivery: ResponseDelivery::AlreadyQueued,
        }
    }
}

fn dispatch(
    request: &Request,
    manager: &Manager,
    client: ClientId,
    sink: &Sink,
    attachment: &mut Option<AttachmentRef>,
) -> Result<DispatchOutcome, ErrorCode> {
    if request.version != VERSION {
        return Err(ErrorCode::IncompatibleVersion);
    }
    if !matches!(request.command, Command::Hello { .. })
        && request.host_generation != Some(manager.generation)
    {
        return Err(ErrorCode::StaleHost);
    }
    let response = match &request.command {
        Command::Hello {} => Response::Hello {
            host_generation: manager.generation,
            protocol_version: VERSION,
        },
        Command::List { after, limit } => {
            if *limit == 0 || *limit > 50 {
                return Err(ErrorCode::InvalidRequest);
            }
            let mut remaining = manager
                .list()
                .into_iter()
                .filter(|value| after.is_none_or(|id| value.runtime.target.pane_id > id));
            let terminals: Vec<_> = remaining.by_ref().take(*limit).collect();
            let next = remaining
                .next()
                .and_then(|_| terminals.last().map(|value| value.runtime.target.pane_id));
            Response::Terminals { terminals, next }
        }
        Command::Start {
            command_id,
            target,
            launch,
        } => Response::Started {
            terminal: manager.start(*command_id, *target, launch)?,
        },
        Command::Attach { runtime } => {
            if attachment.is_some() {
                return Err(ErrorCode::AlreadyAttached);
            }
            let attached = manager.attach(*runtime, client, sink.clone(), request.request_id)?;
            *attachment = Some(attached.attachment);
            return Ok(DispatchOutcome::queued(attached.response));
        }
        Command::Input { attachment, data } => Response::InputAccepted {
            bytes: manager.input(*attachment, client, data)?,
        },
        Command::Resize {
            attachment,
            rows,
            columns,
        } => {
            manager.resize(*attachment, client, *rows, *columns)?;
            Response::Ok {}
        }
        Command::Detach { attachment: lease } => {
            manager.detach(*lease, client)?;
            *attachment = None;
            Response::Ok {}
        }
        Command::Stop { runtime } => {
            manager.stop(*runtime)?;
            Response::Ok {}
        }
    };
    Ok(DispatchOutcome::pending(response))
}

fn client(socket: UnixStream, manager: Arc<Manager>, id: ClientId) -> io::Result<()> {
    // BSD/macOS accepted sockets can inherit the listener's nonblocking flag.
    // A client reader must wait for its next frame rather than treating EAGAIN as disconnect.
    socket.set_nonblocking(false)?;
    check_peer(&socket)?;
    socket.set_write_timeout(Some(Duration::from_millis(500)))?;
    let shared = Arc::new(socket.try_clone()?);
    let (sender, receiver) = mpsc::sync_channel(32);
    let sink = Sink {
        sender,
        socket: shared.clone(),
    };
    thread::spawn(move || write_frames(shared, receiver));
    let mut reader = BufReader::new(socket);
    let mut requests = Requests::new();
    let mut attachment = None;
    while let Ok(Some(request)) = read_request(&mut reader) {
        let outcome = match requests.previous(&request) {
            Ok(Some(response)) => DispatchOutcome::pending(response),
            Err(code) => DispatchOutcome::pending(Response::from(code)),
            Ok(None) => {
                let outcome = dispatch(&request, &manager, id, &sink, &mut attachment)
                    .unwrap_or_else(|code| DispatchOutcome::pending(Response::from(code)));
                requests.remember(&request, outcome.response.clone());
                outcome
            }
        };
        if matches!(outcome.delivery, ResponseDelivery::NeedsQueue)
            && !sink.send(Frame::Response {
                request_id: request.request_id,
                response: outcome.response,
            })
        {
            break;
        }
    }
    manager.disconnect(id);
    let _ = sink.socket.shutdown(std::net::Shutdown::Both);
    Ok(())
}
fn read_request(reader: &mut impl BufRead) -> io::Result<Option<Request>> {
    let mut data = Vec::new();
    if reader.take(FRAME_BYTES + 1).read_until(b'\n', &mut data)? == 0 {
        return Ok(None);
    }
    if data.len() as u64 > FRAME_BYTES || !data.ends_with(b"\n") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Incomplete or oversized request frame",
        ));
    }
    serde_json::from_slice(&data)
        .map(Some)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Invalid request"))
}

fn write_frames(socket: Arc<UnixStream>, receiver: mpsc::Receiver<Frame>) {
    let mut writer = &*socket;
    while let Ok(frame) = receiver.recv() {
        let Ok(mut data) = serde_json::to_vec(&frame) else {
            break;
        };
        data.push(b'\n');
        if data.len() as u64 > FRAME_BYTES || writer.write_all(&data).is_err() {
            break;
        }
    }
    let _ = socket.shutdown(std::net::Shutdown::Both);
}

fn check_peer(socket: &UnixStream) -> io::Result<()> {
    let (mut uid, mut gid) = (0, 0);
    if unsafe { libc::getpeereid(socket.as_raw_fd(), &mut uid, &mut gid) } < 0
        || uid != unsafe { libc::geteuid() }
    {
        return Err(io::Error::other("axod only accepts this OS user"));
    }
    Ok(())
}

pub fn serve(root: &Path) -> io::Result<()> {
    let journal = Journal::open(root)?;
    let path = root.join("control.sock");
    if path.as_os_str().as_encoded_bytes().len() > 90 {
        return Err(io::Error::other("axod socket path is too long"));
    }
    // Existing socket means an unverified owner; never unlink and steal its endpoint.
    let listener = UnixListener::bind(&path)?;
    let bound = fs::symlink_metadata(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let stopping = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(libc::SIGTERM, stopping.clone())?;
    signal_hook::flag::register(libc::SIGINT, stopping.clone())?;
    let manager = Arc::new(Manager::new(journal));
    let clients = Arc::new(AtomicUsize::new(0));
    let next_id = AtomicU64::new(1);
    while !stopping.load(Ordering::SeqCst) {
        let (socket, _) = match listener.accept() {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(_) => break,
        };
        if clients
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |value| {
                (value < MAX_CLIENTS).then_some(value + 1)
            })
            .is_err()
        {
            continue;
        }
        let manager = manager.clone();
        let clients = clients.clone();
        let id = ClientId(next_id.fetch_add(1, Ordering::SeqCst));
        thread::spawn(move || {
            let _ = client(socket, manager, id);
            clients.fetch_sub(1, Ordering::SeqCst);
        });
    }
    drop(listener);
    manager.shutdown();
    // Remove only the socket this process bound during a controlled shutdown.
    if let Ok(current) = fs::symlink_metadata(&path)
        && current.file_type().is_socket()
        && current.dev() == bound.dev()
        && current.ino() == bound.ino()
    {
        fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_reader_rejects_partial_oversized_and_unknown_frames() {
        use std::io::Cursor;
        assert!(
            read_request(&mut Cursor::new(Vec::<u8>::new()))
                .unwrap()
                .is_none()
        );
        assert!(read_request(&mut Cursor::new(b"{\"version\":1}")).is_err());
        assert!(read_request(&mut Cursor::new(vec![b'x'; FRAME_BYTES as usize + 1])).is_err());
        assert!(
            read_request(&mut Cursor::new(
                b"{\"version\":1,\"request_id\":1,\"command\":{\"op\":\"hello\"},\"extra\":true}\n"
            ))
            .is_err()
        );
        let valid = b"{\"version\":1,\"request_id\":1,\"command\":{\"op\":\"hello\"}}\n";
        assert!(read_request(&mut Cursor::new(valid)).unwrap().is_some());
    }

    #[test]
    fn reply_cache_evicts_large_backlogs_by_bytes_not_just_count() {
        let runtime = RuntimeRef {
            host_generation: HostGeneration::new(),
            target: TerminalTarget {
                session_id: SessionId::new(),
                pane_id: PaneId::new(),
            },
            runtime_generation: RuntimeGeneration::new(),
        };
        let response = Response::Attached {
            attachment: AttachmentRef {
                runtime,
                attachment_id: AttachmentId::new(),
            },
            terminal: TerminalSnapshot {
                runtime,
                process: ProcessState::Running {
                    pid: ChildPid::try_from(42).unwrap(),
                },
                attached: true,
                backlog_bytes: BACKLOG_BYTES,
            },
            backlog: RawBacklog {
                start_offset: 0,
                next_offset: BACKLOG_BYTES as u64,
                data: vec![255; BACKLOG_BYTES],
                truncated: false,
            },
        };
        let mut requests = Requests::new();
        let mut request = Request {
            version: VERSION,
            request_id: 1,
            host_generation: None,
            command: Command::Hello {},
        };
        for id in 1..10 {
            request.request_id = id;
            requests.remember(&request, response.clone());
            assert!(requests.bytes <= 128 * 1024);
        }
        assert!(requests.cache.len() < 9);
        request.request_id = 1;
        assert_eq!(
            requests.previous(&request).err(),
            Some(ErrorCode::RequestOutOfOrder)
        );
    }

    #[test]
    fn request_reuse_conflicts_and_evicted_requests_never_execute_again() {
        let mut requests = Requests::new();
        let mut request = Request {
            version: VERSION,
            request_id: 1,
            host_generation: None,
            command: Command::Hello {},
        };
        requests.remember(&request, Response::Ok {});
        assert!(requests.previous(&request).unwrap().is_some());
        request.command = Command::List {
            after: None,
            limit: 50,
        };
        assert_eq!(requests.previous(&request).err(), Some(ErrorCode::Conflict));
        for id in 2..70 {
            request.request_id = id;
            requests.remember(&request, Response::Ok {});
        }
        request.request_id = 1;
        assert_eq!(
            requests.previous(&request).err(),
            Some(ErrorCode::RequestOutOfOrder)
        );
    }
}
