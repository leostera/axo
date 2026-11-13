use std::ffi::{CStr, OsStr};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axo_ipc::{ErrorCode, Extension, Methods, RpcError, TypedMethods};
use axo_protocol::rpc::{self, method};
use jsonrpc_core::IoHandler;

mod ai;
mod attachments;
mod brief;
mod catalog;
mod core;
mod devices;
mod event_stream;
mod events;
mod handlers;
mod idle_pis;
mod input_key;
mod ops;
mod peers;
pub mod permissions;
mod relay_host;
mod remote;
#[cfg(test)]
mod scenarios;
mod session;
mod sessions;
mod settings;
mod stop_notice;
mod store;
mod terminal_input;
#[cfg(test)]
mod test_support;
mod transcripts;
mod workspace_state;

const MAX_SOCKET_PATH_BYTES: usize = 103;

pub const BUILD_NUMBER: &str = match option_env!("AXO_BUILD_NUMBER") {
    Some(build_number) => build_number,
    None => "1",
};

pub fn build_number() -> u64 {
    BUILD_NUMBER
        .parse()
        .expect("build metadata must provide a positive decimal build number")
}

/// Where every Mac's transcripts live, by host: `sessions/` beside the server directory, so
/// `~/.axo/server` has `~/.axo/sessions` (RFD0022).
pub fn sessions_directory_for(server_directory: &Path) -> PathBuf {
    match server_directory.parent() {
        Some(parent) => parent.join("sessions"),
        None => server_directory.join("sessions"),
    }
}

/// Returns the default directory for daemon metadata and logs.
pub fn default_server_directory() -> io::Result<PathBuf> {
    Ok(current_user_home_directory()?.join(".axo/server"))
}

pub(crate) fn current_user_home_directory() -> io::Result<PathBuf> {
    resolve_home_directory(std::env::var_os("HOME").map(PathBuf::from))
}

pub(crate) fn current_user_login_shell() -> io::Result<PathBuf> {
    let mut account = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0; 16 * 1024];
    let mut result = std::ptr::null_mut();
    // SAFETY: account, buffer, and result are valid writable storage for getpwuid_r.
    let error = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            account.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    if result.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "could not determine the current user's login shell",
        ));
    }

    // SAFETY: getpwuid_r returned a non-null result and initialized account.
    let shell = unsafe { account.assume_init() }.pw_shell;
    if shell.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the current user's account has no login shell",
        ));
    }

    // SAFETY: pw_shell points to a NUL-terminated string in buffer, which remains alive here.
    let shell = unsafe { CStr::from_ptr(shell) }.to_bytes();
    let shell = PathBuf::from(OsStr::from_bytes(shell));
    if !shell.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the current user's login shell path is not absolute",
        ));
    }
    Ok(shell)
}

fn resolve_home_directory(configured_home: Option<PathBuf>) -> io::Result<PathBuf> {
    if let Some(home) = configured_home.filter(|path| path.is_absolute()) {
        return Ok(home);
    }

    // LaunchAgents do not guarantee that HOME is present in their environment.
    let mut account = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0; 16 * 1024];
    let mut result = std::ptr::null_mut();
    // SAFETY: account, buffer, and result are valid writable storage for getpwuid_r.
    let error = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            account.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    if result.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "could not determine the current user's home directory",
        ));
    }

    // SAFETY: getpwuid_r returned a non-null result and initialized account.
    let home = unsafe { account.assume_init() }.pw_dir;
    if home.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the current user's account has no home directory",
        ));
    }

    // SAFETY: pw_dir points to a NUL-terminated string in buffer, which remains alive here.
    let home = unsafe { CStr::from_ptr(home) }.to_bytes();
    let home = PathBuf::from(OsStr::from_bytes(home));
    if !home.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the current user's home directory is not absolute",
        ));
    }
    Ok(home)
}

/// Creates the daemon's per-user directory with private permissions.
pub fn prepare_server_directory(path: &Path) -> io::Result<()> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "server directory must be an absolute path",
        ));
    }
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// Where axod keeps per-host relay credentials.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostCredentialStorage {
    /// The user's login Keychain (macOS).
    Keychain,
    /// `0600` files under `<server-dir>/host-credentials`, for platforms without a secret store
    /// and for isolated tests.
    Files,
}

impl HostCredentialStorage {
    pub const fn platform_default() -> Self {
        if cfg!(target_os = "macos") {
            Self::Keychain
        } else {
            Self::Files
        }
    }

    fn open(self, server_directory: &Path) -> Arc<dyn axo_relay::credential::HostCredentialStore> {
        match self {
            Self::Keychain => Arc::new(axo_relay::credential::MacOSKeychain),
            Self::Files => Arc::new(axo_relay::credential::FileCredentialStore::new(
                server_directory.join("host-credentials"),
            )),
        }
    }
}

pub use axo_relay::{DEFAULT_RELAY_URL, RelayEndpoint};

/// How this daemon reaches the Axo relay.
pub struct RemoteAccess {
    pub endpoint: RelayEndpoint,
    pub credential_storage: HostCredentialStorage,
}

/// What the relay RPCs act on; absent if the relay worker could not start.
#[derive(Clone)]
struct RelayContext {
    control: Arc<axo_relay::RelayControl>,
    channel: Arc<axo_relay::RelayChannel>,
    endpoint: axo_relay::RelayEndpoint,
    host: Arc<relay_host::RelayHostAdapter>,
    credentials: Arc<dyn axo_relay::credential::HostCredentialStore>,
}

const ATTACH_SOCKET_FILE: &str = "attach.sock";

/// Starts Axo's local JSON-RPC server and blocks for the daemon's lifetime.
pub fn serve_ipc(
    socket_override: Option<&Path>,
    server_directory: &Path,
    daemon_version: &'static str,
    remote_access: RemoteAccess,
) -> Result<(), Box<dyn std::error::Error>> {
    prepare_server_directory(server_directory)?;
    let socket_path = match socket_override {
        Some(path) => SocketPath::parse(path.to_path_buf())?,
        None => default_socket_path()?,
    };
    prepare_runtime_directory(&socket_path.0)?;
    remove_stale_socket(&socket_path.0)?;

    let runtime = axod_runtime()?;
    let stop = axo_ipc::Stop::default();
    let sessions_directory = sessions_directory_for(server_directory);
    let (core, previous_stop) = {
        let _inside = runtime.enter();
        open_core(server_directory, &sessions_directory, &socket_path.0)?
    };
    let host = Arc::new(relay_host::RelayHostAdapter::new(Arc::clone(&core)));
    let credentials = remote_access.credential_storage.open(server_directory);
    core.input_keys.keep_in(Arc::clone(&credentials));
    // What the peers socket follows, shared with the remote panes' handlers (RFD0024).
    let peer_live = axo_relay::peers::PeerLive::new();
    peers::Peers::attach(
        &core,
        Arc::clone(&peer_live),
        server_directory.join("peers.json"),
    );
    let _bridges = runtime.block_on(async {
        attachments::listen(&core, stop.clone())?;
        let watched = watch_bridges(&core);
        sessions::restore(&core, previous_stop).await?;
        Ok::<_, io::Error>(watched)
    })?;
    let mut remote_relay = match axo_relay::RelayWorker::start(
        axo_relay::RelayDependencies {
            host: host.clone(),
            sync: host.clone(),
            endpoint: remote_access.endpoint.clone(),
            links: host.clone(),
            credentials: Arc::clone(&credentials),
            // Every Mac's transcripts by host, this Mac's beside the copies (RFD0022).
            peers: Some(axo_relay::peers::PeersPaths {
                sessions_directory: sessions_directory.clone(),
                index: server_directory.join("peers.json"),
                live: peer_live,
            }),
            // Prompts' attachments, beside the Sessions (RFD0030).
            assets_directory: sessions_directory.parent().map(|axo| axo.join("assets")),
        },
        runtime.handle().clone(),
        stop.clone(),
    ) {
        Ok(worker) => Some(worker),
        Err(error) => {
            log::error!("event=relay.worker_unavailable reason={error}");
            None
        }
    };
    let relay = remote_relay.as_ref().map(|worker| RelayContext {
        control: worker.control_handle(),
        channel: worker.channel_handle(),
        endpoint: remote_access.endpoint,
        host,
        credentials,
    });
    let host_for_calls = relay.as_ref().map(|relay| Arc::clone(&relay.host));
    let handler = rpc_handler(Arc::clone(&core), daemon_version, relay);
    // The account's calls are answered by the same methods, as the relay's caller.
    if let Some(host) = host_for_calls {
        host.answer_with(handler.clone());
    }
    let listener = std::os::unix::net::UnixListener::bind(&socket_path.0)?;
    fs::set_permissions(&socket_path.0, fs::Permissions::from_mode(0o600))?;
    let _pid_file = PidFile::write(&server_directory.join("axo.pid"))?;
    let signalled = {
        // Signal streams register with the runtime they are made in.
        let _inside = runtime.enter();
        stop_on_signal(stop.clone())?
    };
    runtime.spawn(signalled);

    log::info!("event=daemon.ready pid={}", std::process::id());
    // `axod mcp` opens the MCP server for its Session on its connection (RFD0034).
    let mut upgrades = axo_ipc::Upgrades::default();
    let mcp_socket = socket_path.0.clone();
    upgrades.add(axo_mcp::OPEN, move |upgraded| {
        axo_mcp::upgrade(upgraded, mcp_socket.clone())
    });
    // Clients hear of events on a connection of their own, pushed as they happen (RFD0037).
    let streaming = Arc::clone(&core);
    upgrades.add(event_stream::STREAM, move |upgraded| {
        event_stream::serve(Arc::clone(&streaming), upgraded)
    });
    let served = axo_ipc::serve(runtime.handle(), listener, handler, upgrades, stop.clone());
    stop.stop();
    runtime.block_on(async {
        if let Some(relay) = remote_relay.as_mut() {
            relay.shutdown().await;
        }
        sessions::stop(&core).await;
    });
    attachments::remove_socket(&core.attach_socket_path);
    // Requests still running get a moment to finish; then they are cut short.
    runtime.shutdown_timeout(SHUTDOWN_GRACE);
    log::info!("event=daemon.server_stopped");
    served?;
    Ok(())
}

/// Opens the store and everything axod keeps beside it, and the previous axod's stop record.
fn open_core(
    server_directory: &Path,
    sessions_directory: &Path,
    agent_socket: &Path,
) -> Result<(Arc<core::Core>, Option<stop_notice::DaemonStop>), Box<dyn std::error::Error>> {
    fs::create_dir_all(server_directory)?;
    let server_directory = fs::canonicalize(server_directory)?;
    let mut database = axo_store::open(&server_directory.join(axo_store::DATABASE_FILE))?;
    let host_id = axo_store::load_or_create_host_id(&database)?;
    let settings = settings::Settings::load(&database)?;
    let viewport = axo_store::load_viewport(&database)?;
    let bridges = server_directory.join("pi-sessions");
    fs::create_dir_all(&bridges)?;
    fs::set_permissions(&bridges, fs::Permissions::from_mode(0o700))?;
    axo_store::ensure_pi_bridge_socket_paths(&database, &bridges)?;
    let pi_directories = transcripts::open(&mut database, bridges, sessions_directory, &host_id)?;
    remove_abandoned_pi_bridge_sockets(&database)?;
    let previous_stop = sessions::take_previous_stop(&database)?;
    let home = current_user_home_directory()?;
    let home = home.canonicalize().unwrap_or(home);
    let core = Arc::new(core::Core::new(core::CoreParts {
        store: store::Store::new(database),
        host_id,
        host_generation: axo_protocol::new_uuid_v4()?,
        home,
        attach_socket_path: server_directory.join(ATTACH_SOCKET_FILE),
        agent_socket: agent_socket.to_path_buf(),
        pi_directories,
        sessions_directory: sessions_directory.to_path_buf(),
        settings,
        viewport,
        lifeline: axo_agent::Lifeline::new()?,
    }));
    Ok((core, previous_stop))
}

/// Startup reconciliation: removes the bridge socket of every Session whose writer lock no Pi
/// holds. Failures are logged and skipped; they must not keep axod from starting.
fn remove_abandoned_pi_bridge_sockets(database: &axo_store::Connection) -> io::Result<()> {
    for (session_id, session_file, socket_path) in axo_store::pi_bridge_sockets(database)? {
        match axo_agent::pi::BridgeSocketPath::parse(socket_path)
            .and_then(|socket| socket.reconcile(&session_file))
        {
            Ok(cleanup) => session::pi::log_socket_cleanup(session_id, cleanup),
            Err(error) => log::warn!(
                "event=pi.bridge_socket_reconcile_failed session_id={session_id} error_kind={:?}",
                error.kind()
            ),
        }
    }
    Ok(())
}

/// Tells Pi links when something changes where Pis make their bridge sockets, so a link tries
/// again the moment its Pi listens. Kept for axod's lifetime; without it links still retry.
fn watch_bridges(core: &Arc<core::Core>) -> Option<notify::RecommendedWatcher> {
    use notify::Watcher;
    let changed = Arc::clone(&core.bridges_changed);
    let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if event.is_ok() {
            changed.notify_waiters();
        }
    });
    match watcher.and_then(|mut watcher| {
        watcher
            .watch(
                &core.pi_directories.bridges,
                notify::RecursiveMode::NonRecursive,
            )
            .map(|()| watcher)
    }) {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            log::warn!("event=pi.bridge_watch_unavailable reason={error}");
            None
        }
    }
}

/// Grace for requests still running when axod stops.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

/// axod's one runtime (RFD0041): the socket, its requests, every Session's task, the MCP servers
/// and the relay run on it; blocking work runs on its blocking pool.
fn axod_runtime() -> io::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("axod")
        .enable_all()
        .build()
}

/// Stops axod on SIGTERM or SIGINT. The streams are made now, so a signal from here on is never
/// missed, and they replace the default handlers, which would kill the process.
fn stop_on_signal(stop: axo_ipc::Stop) -> io::Result<impl std::future::Future<Output = ()>> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    Ok(async move {
        let name = tokio::select! {
            _ = terminate.recv() => "SIGTERM",
            _ = interrupt.recv() => "SIGINT",
        };
        log::info!("event=daemon.signal signal={name}");
        stop.stop();
    })
}

/// axod's methods, from its extensions (RFD0034). Each method has one owner; two claiming the
/// same name is a bug, found when axod starts.
fn rpc_handler(
    core: Arc<core::Core>,
    daemon_version: &'static str,
    relay: Option<RelayContext>,
) -> IoHandler {
    let apps = axo_apps::Apps::new(relay.as_ref().map(|relay| Arc::clone(&relay.channel)));
    let brief = brief::Brief::new(relay.as_ref().map(|relay| brief::AccountRoute {
        links: Arc::clone(&relay.host) as Arc<dyn axo_relay::HostLinkStore>,
        channel: Arc::clone(&relay.channel),
    }));
    let assets = axo_assets::Assets::new(Arc::clone(&core.assets));
    let questions = axo_questions::QuestionsExtension::new(
        Arc::clone(&core.questions),
        Arc::clone(&core) as Arc<dyn axo_questions::QuestionsHost>,
    );
    let computer = axo_computer_use::ComputerExtension::new(
        Arc::clone(&core.computer),
        Arc::clone(&core) as Arc<dyn axo_computer_use::ComputerHost>,
    );
    let daemon = Daemon {
        version: daemon_version,
        core: Arc::clone(&core),
    };
    let mut methods = Methods::new();
    for extension in [
        &daemon as &dyn Extension,
        &Relay(relay),
        &handlers::Sessions(Arc::clone(&core)),
        &remote::Remote::new(core),
        &apps,
        &brief,
        &assets,
        &questions,
        &computer,
    ] {
        if let Err(conflict) = methods.add(extension) {
            panic!("{conflict}");
        }
    }
    methods.into_handler()
}

/// The daemon's own methods: negotiating the protocol, and its health.
struct Daemon {
    version: &'static str,
    core: Arc<core::Core>,
}

impl Extension for Daemon {
    fn name(&self) -> &'static str {
        "daemon"
    }

    fn register(&self, methods: &mut IoHandler) {
        add_protocol_negotiate_method(methods);
        let core = Arc::clone(&self.core);
        add_health_method(methods, self.version, move || {
            core.ready.load(std::sync::atomic::Ordering::Acquire)
        });
    }
}

/// Linking this Mac, its relay's status, and sharing through it.
struct Relay(Option<RelayContext>);

impl Extension for Relay {
    fn name(&self) -> &'static str {
        "relay"
    }

    fn register(&self, methods: &mut IoHandler) {
        add_relay_methods(methods, self.0.clone());
    }
}

fn add_relay_methods(handler: &mut IoHandler, relay: Option<RelayContext>) {
    let context = relay.clone();
    handler.add_typed(
        method::RELAY_LINK,
        "expected {code}",
        move |request: rpc::LinkHost| {
            let context = context.clone();
            async move {
                let context = context
                    .as_ref()
                    .ok_or_else(|| internal_error("host relay is unavailable"))?;
                let host_label = axo_relay::link_host(
                    &context.endpoint,
                    &request.code,
                    axo_relay::RelayHost::identity(context.host.as_ref()),
                    context.host.as_ref(),
                    context.credentials.clone(),
                )
                .await
                .map_err(|error| {
                    log::warn!("event=relay.link_failed reason={error}");
                    internal_error("could not link this Mac")
                })?;
                context.control.request_connect();
                Ok(rpc::HostLinked {
                    linked: true,
                    host_label,
                })
            }
        },
    );

    let context = relay.clone();
    handler.add_typed(
        method::RELAY_STATUS,
        "expected no parameters",
        move |_: rpc::NoParams| {
            std::future::ready(match &context {
                Some(context) => Ok(context.control.snapshot()),
                None => Ok(axo_relay::unavailable_status()),
            })
        },
    );

    let context = relay.clone();
    handler.add_typed(
        method::SESSION_SHARE,
        "expected {snapshot}",
        move |request: rpc::ShareSession| {
            let context = context.clone();
            async move {
                let context = context
                    .as_ref()
                    .ok_or_else(|| internal_error("this Mac cannot reach its Axo account"))?;
                share_session(context, request.snapshot).await
            }
        },
    );

    handler.add_typed(
        method::RELAY_CONNECT,
        "expected no parameters",
        move |_: rpc::NoParams| {
            let relay = relay.clone();
            async move {
                let requested = match &relay {
                    Some(context) => {
                        context.control.request_connect();
                        true
                    }
                    None => false,
                };
                Ok(rpc::ConnectRequested { requested })
            }
        },
    );
}

/// The cloud method that stores a shared conversation (`@axo/protocol`'s `SHARE_PUBLISH_METHOD`).
const SHARE_PUBLISH_METHOD: &str = "axo.host.share.publish";
/// Storing a snapshot of up to 1.5 MiB; generous, since nothing else waits on it.
const SHARE_PUBLISH_TIMEOUT: Duration = Duration::from_secs(60);

/// Forwards a redacted conversation over the relay link, so the cloud publishes it under this
/// Mac's account. No Cloudflare credentials are needed on the Mac.
async fn share_session(
    context: &RelayContext,
    snapshot: serde_json::Value,
) -> Result<rpc::SessionShared, RpcError> {
    use axo_relay::{RelayCallError, RelayHost};
    let params = serde_json::json!({
        "hostId": context.host.identity().host_id,
        "hostGeneration": context.host.identity().host_generation,
        "snapshot": snapshot,
    });
    let reply = context
        .channel
        .request(
            SHARE_PUBLISH_METHOD,
            params,
            axo_relay::Priority::Control,
            SHARE_PUBLISH_TIMEOUT,
        )
        .await
        .map_err(|error| {
            log::warn!("event=share.publish_failed reason={error:?}");
            internal_error(match error {
                RelayCallError::NotConnected => {
                    "this Mac is not connected to its Axo account; link it under Settings > Remote Access, or check that it is online"
                }
                RelayCallError::TooLarge => "the conversation is too large to share",
                RelayCallError::Rejected { .. } => "Axo's cloud refused the conversation",
                RelayCallError::Disconnected
                | RelayCallError::TimedOut
                | RelayCallError::Abandoned => {
                    "the connection to Axo's cloud dropped; the conversation may have been published"
                }
            })
        })?;
    serde_json::from_value(reply).map_err(|_| internal_error("Axo's cloud answered unexpectedly"))
}

fn add_protocol_negotiate_method(handler: &mut IoHandler) {
    handler.add_typed(
        method::PROTOCOL_NEGOTIATE,
        "expected {protocolVersion}",
        |request: rpc::NegotiateProtocol| async move {
            if request.protocol_version != rpc::PROTOCOL_VERSION {
                return Err(invalid_params("unsupported protocol version"));
            }
            Ok(rpc::ProtocolNegotiated {
                protocol_version: rpc::PROTOCOL_VERSION,
                methods: method::ADVERTISED
                    .iter()
                    .map(|&name| name.to_owned())
                    .collect(),
            })
        },
    );
}

fn add_health_method(
    handler: &mut IoHandler,
    daemon_version: &'static str,
    ready: impl Fn() -> bool + Send + Sync + 'static,
) {
    handler.add_typed(
        method::DAEMON_HEALTH,
        "expected no parameters",
        move |_: rpc::NoParams| {
            let ready = ready();
            async move {
                Ok(rpc::DaemonHealth {
                    version: daemon_version.to_owned(),
                    build_number: build_number(),
                    status: rpc::DaemonStatus::Running,
                    ready,
                    developer_tools: tokio::task::spawn_blocking(permissions::developer_tools)
                        .await
                        .map_err(|_| internal_error("permission probe failed"))?,
                })
            }
        },
    );
}

fn invalid_params(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message: message.to_owned(),
        data: None,
    }
}

fn internal_error(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
        message: message.to_owned(),
        data: None,
    }
}

#[derive(Debug, Eq, PartialEq)]
struct SocketPath(PathBuf);

impl SocketPath {
    fn parse(path: PathBuf) -> Result<Self, &'static str> {
        let byte_length = path.as_os_str().as_bytes().len();
        if !path.is_absolute() || path.file_name().is_none() {
            return Err("socket path must be an absolute file path");
        }
        if byte_length > MAX_SOCKET_PATH_BYTES {
            return Err("socket path is too long for a Unix-domain socket");
        }
        Ok(Self(path))
    }
}

fn default_socket_path() -> Result<SocketPath, Box<dyn std::error::Error>> {
    Ok(SocketPath::parse(
        current_user_home_directory()?.join("Library/Application Support/Axo/run/axod.sock"),
    )?)
}

fn prepare_runtime_directory(socket_path: &Path) -> io::Result<()> {
    let runtime_directory = socket_path
        .parent()
        .ok_or_else(|| io::Error::other("socket path must have a parent directory"))?;
    fs::create_dir_all(runtime_directory)?;
    fs::set_permissions(runtime_directory, fs::Permissions::from_mode(0o700))
}

fn remove_stale_socket(socket_path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(socket_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };

    if !metadata.file_type().is_socket() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "refusing to replace a non-socket path",
        ));
    }
    if UnixStream::connect(socket_path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "another Axo server is already listening on this socket",
        ));
    }

    log::warn!("event=daemon.stale_socket_removed");
    fs::remove_file(socket_path)
}

struct PidFile {
    path: PathBuf,
    process_id: u32,
}

impl PidFile {
    fn write(path: &Path) -> io::Result<Self> {
        let process_id = std::process::id();
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temporary_path = path.with_file_name(format!("axo.pid.{process_id}.{nonce}.tmp"));
        let mut temporary_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary_path)?;
        writeln!(temporary_file, "{process_id}")?;
        temporary_file.sync_all()?;
        drop(temporary_file);
        if let Err(error) = fs::rename(&temporary_path, path) {
            let _ = fs::remove_file(&temporary_path);
            return Err(error);
        }

        Ok(Self {
            path: path.to_path_buf(),
            process_id,
        })
    }
}

impl Drop for PidFile {
    fn drop(&mut self) {
        let still_ours = fs::read_to_string(&self.path)
            .map(|contents| contents.trim() == self.process_id.to_string())
            .unwrap_or(false);
        if still_ours {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_directory() -> PathBuf {
        static NEXT_DIRECTORY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = NEXT_DIRECTORY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::env::temp_dir().join(format!("axo-server-test-{}-{unique}", std::process::id()))
    }

    #[tokio::test]
    async fn health_method_reports_this_build() {
        let mut handler = IoHandler::new();
        add_health_method(&mut handler, env!("CARGO_PKG_VERSION"), || false);
        let response = handler
            .handle_request(r#"{"jsonrpc":"2.0","id":1,"method":"axo.daemon.health"}"#)
            .await
            .expect("health is a request with a response");
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(response["result"]["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(response["result"]["buildNumber"], build_number());
        assert_eq!(response["result"]["status"], "running");
        assert_eq!(response["result"]["ready"], false, "still starting");
    }

    #[test]
    fn unknown_methods_use_the_json_rpc_method_not_found_error() {
        let mut handler = IoHandler::new();
        add_health_method(&mut handler, env!("CARGO_PKG_VERSION"), || true);
        let response = handler
            .handle_request_sync(r#"{"jsonrpc":"2.0","id":1,"method":"axo.unknown"}"#)
            .expect("unknown method requests have an error response");
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(response["error"]["code"], -32601);
    }

    #[test]
    fn socket_paths_are_bounded_absolute_file_paths() {
        assert!(SocketPath::parse(PathBuf::from("/tmp/axod.sock")).is_ok());
        assert!(SocketPath::parse(PathBuf::from("relative/axod.sock")).is_err());
        assert!(
            SocketPath::parse(PathBuf::from(format!(
                "/{}",
                "x".repeat(MAX_SOCKET_PATH_BYTES)
            )))
            .is_err()
        );
    }

    #[test]
    fn stale_socket_cleanup_never_removes_regular_files() {
        let file = temporary_directory();
        fs::write(&file, b"keep me").unwrap();

        let error = remove_stale_socket(&file).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&file).unwrap(), b"keep me");
        fs::remove_file(file).unwrap();
    }

    #[test]
    fn home_directory_uses_the_account_database_when_home_is_unset_or_relative() {
        let from_account = resolve_home_directory(None).unwrap();
        assert!(from_account.is_absolute());
        assert_eq!(
            resolve_home_directory(Some(PathBuf::from("relative/home"))).unwrap(),
            from_account
        );
    }

    #[test]
    fn server_directory_is_private_and_must_be_absolute() {
        let directory = temporary_directory();
        prepare_server_directory(&directory).unwrap();
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::remove_dir_all(directory).unwrap();

        assert_eq!(
            prepare_server_directory(Path::new("relative"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn pid_file_is_removed_on_drop_only_when_it_still_identifies_this_process() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("axo.pid");

        let pid_file = PidFile::write(&path).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap().trim(),
            std::process::id().to_string()
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(pid_file);
        assert!(!path.exists());

        let pid_file = PidFile::write(&path).unwrap();
        fs::write(&path, "different process\n").unwrap();
        drop(pid_file);

        assert_eq!(fs::read_to_string(&path).unwrap(), "different process\n");
        fs::remove_dir_all(directory).unwrap();
    }
}
