//! Rust owns orchestration. The Node child hosts only the actual isolated Worker/Access fixture.
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs,
    io::Read,
    net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream},
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Stdio},
    thread,
    time::{Duration, Instant},
};
use tungstenite::{Message, WebSocket, client::IntoClientRequest};

struct OwnedWorkerProcess {
    child: Child,
    reaped: bool,
}
impl OwnedWorkerProcess {
    fn exited(&self) -> bool {
        if self.reaped {
            return true;
        }
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // Keep the original leader unreaped until its entire owned group has been cleaned.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.child.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        result == 0 && unsafe { info.si_pid() } != 0
    }
    fn stop(&mut self) {
        if self.reaped {
            return;
        }
        drop(self.child.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.exited() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
        }
        // Node may own a workerd child. Never leave it behind or signal a historical/reused PID.
        unsafe {
            libc::kill(-(self.child.id() as i32), libc::SIGKILL);
        }
        let _ = self.child.wait();
        self.reaped = true;
    }
}
impl Drop for OwnedWorkerProcess {
    fn drop(&mut self) {
        self.stop();
    }
}
pub struct Worker {
    process: OwnedWorkerProcess,
    pub relay: PathBuf,
    config: ClientConfig,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientConfig {
    url: String,
    assertion: String,
}
impl Worker {
    pub fn new(repo: &Path, root: &Path) -> Self {
        let build = std::process::Command::new("npm")
            .arg("--prefix")
            .arg(repo.join("protocol"))
            .args(["run", "build"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let mut build = OwnedWorkerProcess {
            child: build,
            reaped: false,
        };
        let deadline = Instant::now() + Duration::from_secs(30);
        while !build.exited() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
        }
        assert!(build.exited(), "Owned protocol fixture build deadline");
        unsafe {
            libc::kill(-(build.child.id() as i32), libc::SIGKILL);
        }
        let status = build.child.wait().unwrap();
        build.reaped = true;
        assert!(status.success(), "Owned protocol fixture build failed");
        let root = root.join("cloud");
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let child = std::process::Command::new("node")
            .args(["--import", "tsx"])
            .arg(repo.join("sites/api.axo.leostera.dev/testing/owned-worker.ts"))
            .arg(&root)
            .current_dir(repo.join("sites/api.axo.leostera.dev"))
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let process = OwnedWorkerProcess {
            child,
            reaped: false,
        };
        let deadline = Instant::now() + Duration::from_secs(15);
        let config = loop {
            if let Ok(config) = private_config(&root.join("client.json")) {
                break config;
            }
            if process.exited() || Instant::now() >= deadline {
                panic!("Owned Worker startup failed");
            }
            thread::sleep(Duration::from_millis(50));
        };
        Self {
            process,
            relay: root.join("relay.json"),
            config,
        }
    }
    pub fn connect(&mut self, machine: axod::model::MachineId) -> CloudPeer {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(peer) = CloudPeer::connect(&self.config, machine) {
                return peer;
            }
            assert!(
                !self.process.exited() && Instant::now() < deadline,
                "Owned cloud registration deadline"
            );
            thread::sleep(Duration::from_millis(50)); // Discovery/connection only; never retry an execution request.
        }
    }
    pub fn stop(&mut self) {
        self.process.stop();
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.stop();
    }
}
fn private_config(path: &Path) -> Result<ClientConfig, ()> {
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| ())?;
    let metadata = file.metadata().map_err(|_| ())?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(());
    }
    let mut bytes = Vec::new();
    file.by_ref()
        .take(4097)
        .read_to_end(&mut bytes)
        .map_err(|_| ())?;
    if bytes.len() > 4096 {
        return Err(());
    }
    serde_json::from_slice(&bytes).map_err(|_| ())
}
#[derive(Deserialize)]
enum RpcVersion {
    #[serde(rename = "2.0")]
    V2,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CloudReply {
    #[serde(rename = "jsonrpc")]
    _version: RpcVersion,
    id: uuid::Uuid,
    result: Value,
}
pub struct CloudPeer {
    socket: WebSocket<TcpStream>,
}
impl CloudPeer {
    fn connect(config: &ClientConfig, machine: axod::model::MachineId) -> Result<Self, ()> {
        let mut url = url::Url::parse(&config.url).map_err(|_| ())?;
        if url.scheme() != "http"
            || url.host_str() != Some("127.0.0.1")
            || url.port().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(());
        }
        let port = url.port().ok_or(())?;
        url.set_scheme("ws").map_err(|_| ())?;
        let machine = serde_json::to_value(machine).map_err(|_| ())?;
        let machine = machine.as_str().ok_or(())?;
        url.set_path(&format!("/v1/machines/{machine}/client"));
        let mut request = url.as_str().into_client_request().map_err(|_| ())?;
        request.headers_mut().insert(
            "Cf-Access-Jwt-Assertion",
            config.assertion.parse().map_err(|_| ())?,
        );
        let stream = TcpStream::connect_timeout(
            &SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port),
            Duration::from_secs(2),
        )
        .map_err(|_| ())?;
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .map_err(|_| ())?;
        stream
            .set_write_timeout(Some(Duration::from_millis(500)))
            .map_err(|_| ())?;
        let bounds = tungstenite::protocol::WebSocketConfig::default()
            .max_message_size(Some(65536))
            .max_frame_size(Some(65536));
        let (socket, _) = tungstenite::client::client_with_config(request, stream, Some(bounds))
            .map_err(|_| ())?;
        let mut peer = Self { socket };
        peer.call("axo.protocol.negotiate", json!({"protocolVersion":1}));
        Ok(peer)
    }
    pub fn call(&mut self, method: &str, params: Value) -> Value {
        let id = uuid::Uuid::new_v4();
        self.send(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}));
        for _ in 0..16 {
            match self
                .socket
                .read()
                .unwrap_or_else(|_| panic!("Owned cloud reply uncertain"))
            {
                Message::Text(text) => {
                    let reply: CloudReply = serde_json::from_str(&text)
                        .unwrap_or_else(|_| panic!("Owned cloud RPC rejected or malformed"));
                    self.send(
                        json!({"jsonrpc":"2.0","method":"axo.transport.ack","params":{"frames":1}}),
                    );
                    assert!(reply.id == id, "Wrong cloud hop identity");
                    return reply.result;
                }
                Message::Ping(bytes) => {
                    self.socket.send(Message::Pong(bytes)).unwrap();
                }
                Message::Pong(_) => (),
                _ => panic!("Unexpected cloud frame"),
            }
        }
        panic!("Owned cloud control budget exhausted")
    }
    fn send(&mut self, frame: Value) {
        let body = serde_json::to_string(&frame).unwrap();
        assert!(body.len() <= 65536);
        self.socket.send(Message::Text(body.into())).unwrap();
    }
}
impl Drop for CloudPeer {
    fn drop(&mut self) {
        let _ = self.socket.close(None);
    }
}
