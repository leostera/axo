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
    fingerprint: Vec<u8>,
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
fn fingerprint(request: &Request) -> Vec<u8> {
    Sha256::digest(serde_json::to_vec(request).unwrap()).to_vec()
}

fn dispatch(
    request: &Request,
    manager: &Manager,
    client: u64,
    sink: &Sink,
    attachment: &mut Option<AttachmentRef>,
) -> Result<(Response, bool), ErrorCode> {
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
            let (lease, response) =
                manager.attach(*runtime, client, sink.clone(), request.request_id)?;
            *attachment = Some(lease);
            return Ok((response, true));
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
    Ok((response, false))
}

fn client(socket: UnixStream, manager: Arc<Manager>, id: u64) -> io::Result<()> {
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
    thread::spawn(move || {
        let mut writer = &*shared;
        while let Ok(frame) = receiver.recv() {
            let Ok(mut data) = serde_json::to_vec(&frame) else {
                break;
            };
            data.push(b'\n');
            if data.len() as u64 > FRAME_BYTES || writer.write_all(&data).is_err() {
                let _ = shared.shutdown(std::net::Shutdown::Both);
                break;
            }
        }
    });
    let mut reader = BufReader::new(socket);
    let mut requests = Requests::new();
    let mut attachment = None;
    loop {
        let mut data = Vec::new();
        if !matches!((&mut reader).take(FRAME_BYTES + 1).read_until(b'\n', &mut data), Ok(length) if length > 0)
        {
            break;
        }
        if data.len() as u64 > FRAME_BYTES || !data.ends_with(b"\n") {
            break;
        }
        let Ok(request) = serde_json::from_slice::<Request>(&data) else {
            break;
        };
        let previous = requests.previous(&request);
        let (response, sent) = match previous {
            Ok(Some(response)) => (response, false),
            Err(code) => (Response::from(code), false),
            Ok(None) => {
                let outcome = dispatch(&request, &manager, id, &sink, &mut attachment)
                    .unwrap_or_else(|code| (Response::from(code), false));
                requests.remember(&request, outcome.0.clone());
                outcome
            }
        };
        if !sent
            && !sink.send(Frame::Response {
                request_id: request.request_id,
                response,
            })
        {
            break;
        }
    }
    manager.disconnect(id);
    let _ = sink.socket.shutdown(std::net::Shutdown::Both);
    Ok(())
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
        let id = next_id.fetch_add(1, Ordering::SeqCst);
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
