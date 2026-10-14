use std::collections::HashMap;
use std::ffi::CStr;
use std::fs;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler, Params};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

const DATABASE_FILE: &str = "axo.db";
const ATTACH_SOCKET_FILE: &str = "attach.sock";
const PTY_ROWS: libc::c_ushort = 24;
const PTY_COLUMNS: libc::c_ushort = 80;
const REAPER_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct SessionId(i64);

#[derive(Debug)]
struct SessionRecord {
    id: SessionId,
    initial_pwd: PathBuf,
}

#[derive(Debug)]
struct RunningSession {
    child: Child,
    master: OwnedFd,
    slave_device: String,
    attached: bool,
}

struct SessionState {
    database: Connection,
    running: HashMap<SessionId, RunningSession>,
    initial_pwd: PathBuf,
}

pub struct SessionManager {
    state: Mutex<SessionState>,
    attach_socket_path: PathBuf,
    stop_workers: Arc<AtomicBool>,
    workers: Mutex<Vec<JoinHandle<()>>>,
}

#[derive(Debug)]
struct SessionMetadata {
    id: SessionId,
    process_id: u32,
    initial_pwd: PathBuf,
    slave_device: String,
    attach_socket_path: PathBuf,
}

impl SessionMetadata {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id.0,
            "processId": self.process_id,
            "initialPwd": self.initial_pwd,
            "ptyDevice": self.slave_device,
            "attachSocketPath": self.attach_socket_path,
        })
    }
}

impl SessionManager {
    pub fn open(server_directory: &Path) -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        let database_path = server_directory.join(DATABASE_FILE);
        let attach_socket_path = server_directory.join(ATTACH_SOCKET_FILE);
        let initial_pwd = super::current_user_home_directory()?;

        let database = Connection::open(&database_path)?;
        database.busy_timeout(Duration::from_secs(3))?;
        database.pragma_update(None, "journal_mode", "WAL")?;
        database.pragma_update(None, "synchronous", "FULL")?;
        database.execute_batch(
            "CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                initial_pwd TEXT NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                created_at INTEGER NOT NULL,
                archived_at INTEGER,
                termination_reason TEXT
            );",
        )?;
        fs::set_permissions(&database_path, fs::Permissions::from_mode(0o600))?;

        let manager = Arc::new(Self {
            state: Mutex::new(SessionState {
                database,
                running: HashMap::new(),
                initial_pwd,
            }),
            attach_socket_path,
            stop_workers: Arc::new(AtomicBool::new(false)),
            workers: Mutex::new(Vec::new()),
        });

        manager.restore_open_sessions()?;
        manager.start_attachment_listener()?;
        manager.start_reaper();
        Ok(manager)
    }

    pub fn register_rpc_methods(self: &Arc<Self>, handler: &mut IoHandler) {
        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.list", move |_| {
            manager
                .list_sessions()
                .map(|sessions| json!({ "sessions": sessions.iter().map(SessionMetadata::to_json).collect::<Vec<_>>() }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.create", move |_| {
            manager
                .create_session()
                .map(|session| session.to_json())
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.close", move |params| {
            let id = parse_session_id(params)?;
            manager
                .close_session(id)
                .map(|replacement| {
                    json!({
                        "archivedSessionId": id.0,
                        "replacement": replacement.map(|session| session.to_json()),
                    })
                })
                .map_err(internal_rpc_error)
        });
    }

    fn restore_open_sessions(self: &Arc<Self>) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let records = read_open_sessions(&state.database)?;
        if records.is_empty() {
            create_session(&mut state, &self.attach_socket_path)?;
        } else {
            for record in records {
                let running = spawn_shell(&record.initial_pwd)?;
                state.running.insert(record.id, running);
            }
        }
        Ok(())
    }

    fn start_attachment_listener(self: &Arc<Self>) -> io::Result<()> {
        let socket_path = &self.attach_socket_path;
        super::SocketPath::parse(socket_path.clone())
            .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))?;
        super::remove_stale_socket(socket_path)?;

        let listener = UnixListener::bind(socket_path)?;
        fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;

        let manager = Arc::downgrade(self);
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-pty-attachments".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let manager = manager.clone();
                            let _ = thread::Builder::new()
                                .name("axo-pty-attachment".into())
                                .spawn(move || handle_attachment(stream, manager));
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(20));
                        }
                        Err(_) => thread::sleep(Duration::from_millis(50)),
                    }
                }
            })?;
        self.workers
            .lock()
            .map_err(|_| io::Error::other("session worker lock was poisoned"))?
            .push(worker);
        Ok(())
    }

    fn start_reaper(self: &Arc<Self>) {
        let manager = Arc::downgrade(self);
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-session-reaper".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    thread::sleep(REAPER_INTERVAL);
                    let Some(manager) = manager.upgrade() else {
                        break;
                    };
                    if let Err(error) = manager.reap_exited_sessions() {
                        log::error!("event=session.reap_failed reason={error}");
                    }
                }
            });
        if let Ok(worker) = worker
            && let Ok(mut workers) = self.workers.lock()
        {
            workers.push(worker);
        }
    }

    fn list_sessions(&self) -> io::Result<Vec<SessionMetadata>> {
        let state = self.lock_state()?;
        let mut sessions = state
            .running
            .iter()
            .map(|(id, running)| {
                let initial_pwd = session_initial_pwd(&state.database, *id)?;
                Ok(SessionMetadata {
                    id: *id,
                    process_id: running.child.id(),
                    initial_pwd,
                    slave_device: running.slave_device.clone(),
                    attach_socket_path: self.attach_socket_path.clone(),
                })
            })
            .collect::<io::Result<Vec<_>>>()?;
        sessions.sort_by_key(|session| session.id.0);
        Ok(sessions)
    }

    fn create_session(&self) -> io::Result<SessionMetadata> {
        let mut state = self.lock_state()?;
        create_session(&mut state, &self.attach_socket_path)
    }

    fn close_session(&self, id: SessionId) -> io::Result<Option<SessionMetadata>> {
        let mut state = self.lock_state()?;
        if !state.running.contains_key(&id) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "session is not open",
            ));
        }

        let replacement = if state.running.len() == 1 {
            Some(create_session(&mut state, &self.attach_socket_path)?)
        } else {
            None
        };

        archive_session(&state.database, id, "explicit_close")?;
        if let Some(mut running) = state.running.remove(&id) {
            terminate_shell(&mut running.child);
        }
        Ok(replacement)
    }

    fn reap_exited_sessions(&self) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let exited = state
            .running
            .iter_mut()
            .filter_map(|(id, running)| match running.child.try_wait() {
                Ok(Some(_)) => Some(Ok(*id)),
                Ok(None) => None,
                Err(error) => Some(Err(error)),
            })
            .collect::<io::Result<Vec<_>>>()?;

        for id in exited {
            state.running.remove(&id);
            archive_session(&state.database, id, "shell_exited")?;
        }
        if state.running.is_empty() {
            create_session(&mut state, &self.attach_socket_path)?;
        }
        Ok(())
    }

    fn duplicate_master(&self, id: SessionId) -> io::Result<OwnedFd> {
        let mut state = self.lock_state()?;
        let running = state
            .running
            .get_mut(&id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session is not open"))?;
        if running.attached {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                "session already has a PTY attachment",
            ));
        }
        let fd = unsafe { libc::fcntl(running.master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }
        running.attached = true;
        // SAFETY: fcntl returned a new, owned descriptor.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    fn mark_detached(&self, id: SessionId) {
        if let Ok(mut state) = self.state.lock()
            && let Some(running) = state.running.get_mut(&id)
        {
            running.attached = false;
        }
    }

    pub fn shutdown(&self) {
        self.stop_workers.store(true, Ordering::Relaxed);
        if let Ok(mut workers) = self.workers.lock() {
            for worker in workers.drain(..) {
                let _ = worker.join();
            }
        }
        if let Ok(mut state) = self.state.lock() {
            for running in state.running.values_mut() {
                terminate_shell(&mut running.child);
            }
        }
    }

    fn lock_state(&self) -> io::Result<std::sync::MutexGuard<'_, SessionState>> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("session state lock was poisoned"))
    }
}

impl Drop for SessionManager {
    fn drop(&mut self) {
        self.stop_workers.store(true, Ordering::Relaxed);
        if let Ok(workers) = self.workers.get_mut() {
            for worker in workers.drain(..) {
                let _ = worker.join();
            }
        }
        if let Ok(state) = self.state.get_mut() {
            for running in state.running.values_mut() {
                terminate_shell(&mut running.child);
            }
        }
        let _ = fs::remove_file(&self.attach_socket_path);
    }
}

fn create_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
) -> io::Result<SessionMetadata> {
    let initial_pwd = state.initial_pwd.clone();
    let timestamp = unix_timestamp();
    state
        .database
        .execute(
            "INSERT INTO sessions (initial_pwd, state, created_at) VALUES (?1, 'open', ?2)",
            params![initial_pwd.to_string_lossy(), timestamp],
        )
        .map_err(io::Error::other)?;
    let id = SessionId(state.database.last_insert_rowid());

    let running = match spawn_shell(&initial_pwd) {
        Ok(running) => running,
        Err(error) => {
            archive_session(&state.database, id, "spawn_failed")?;
            return Err(error);
        }
    };
    let metadata = SessionMetadata {
        id,
        process_id: running.child.id(),
        initial_pwd,
        slave_device: running.slave_device.clone(),
        attach_socket_path: attach_socket_path.to_path_buf(),
    };
    state.running.insert(id, running);
    Ok(metadata)
}

fn read_open_sessions(database: &Connection) -> io::Result<Vec<SessionRecord>> {
    let mut statement = database
        .prepare("SELECT id, initial_pwd FROM sessions WHERE state = 'open' ORDER BY id")
        .map_err(io::Error::other)?;
    let records = statement
        .query_map([], |row| {
            Ok(SessionRecord {
                id: SessionId(row.get(0)?),
                initial_pwd: PathBuf::from(row.get::<_, String>(1)?),
            })
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)?;
    Ok(records)
}

fn session_initial_pwd(database: &Connection, id: SessionId) -> io::Result<PathBuf> {
    database
        .query_row(
            "SELECT initial_pwd FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.0],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))
}

fn archive_session(database: &Connection, id: SessionId, reason: &str) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, id.0],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "session was not open in the database",
        ));
    }
    Ok(())
}

fn spawn_shell(initial_pwd: &Path) -> io::Result<RunningSession> {
    let mut master_fd: RawFd = -1;
    let mut slave_fd: RawFd = -1;
    let mut size = libc::winsize {
        ws_row: PTY_ROWS,
        ws_col: PTY_COLUMNS,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: openpty initializes both descriptors and receives a valid winsize pointer.
    if unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    } == -1
    {
        return Err(io::Error::last_os_error());
    }

    // SAFETY: openpty returned two new owned descriptors.
    let master = unsafe { OwnedFd::from_raw_fd(master_fd) };
    // SAFETY: openpty returned two new owned descriptors.
    let slave = unsafe { OwnedFd::from_raw_fd(slave_fd) };
    let slave_device = tty_device_path(slave.as_raw_fd())?;

    let shell = std::env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.is_file())
        .unwrap_or_else(|| PathBuf::from("/bin/zsh"));
    let home = super::current_user_home_directory()?;
    let slave_raw_fd = slave.as_raw_fd();
    let mut command = Command::new(shell);
    command
        .arg("-l")
        .current_dir(initial_pwd)
        .env("HOME", &home)
        .env("PWD", initial_pwd)
        .env("TERM", "xterm-ghostty")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    // SAFETY: this child-only setup creates a session, assigns the PTY as its
    // controlling terminal, and connects all standard streams before exec.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(slave_raw_fd, libc::TIOCSCTTY as libc::c_ulong, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::tcsetpgrp(slave_raw_fd, libc::getpgrp()) == -1 {
                return Err(io::Error::last_os_error());
            }
            for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
                if libc::dup2(slave_raw_fd, target) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            libc::close(slave_raw_fd);
            Ok(())
        });
    }

    let child = command.spawn()?;
    drop(slave);
    Ok(RunningSession {
        child,
        master,
        slave_device,
        attached: false,
    })
}

fn tty_device_path(slave_fd: RawFd) -> io::Result<String> {
    let mut bytes = vec![0_i8; libc::PATH_MAX as usize];
    // SAFETY: bytes is writable storage and slave_fd is an open PTY slave.
    let error = unsafe { libc::ttyname_r(slave_fd, bytes.as_mut_ptr(), bytes.len()) };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    // SAFETY: ttyname_r wrote a NUL-terminated device path into bytes.
    let device = unsafe { CStr::from_ptr(bytes.as_ptr()) };
    device
        .to_str()
        .map(str::to_owned)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "PTY path is not UTF-8"))
}

fn terminate_shell(child: &mut Child) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    let process_id = child.id() as libc::pid_t;
    let process_group = -process_id;
    log::info!("event=session.shell_stop_started pid={process_id}");
    // The process-group signal covers foreground jobs; the direct signal also
    // covers a shell that changed its process group for interactive job control.
    signal_shell(process_group, process_id, libc::SIGTERM);

    if wait_for_shell_exit(child, Duration::from_millis(500)) {
        log::info!("event=session.shell_stopped pid={process_id}");
        return;
    }

    signal_shell(process_group, process_id, libc::SIGKILL);
    if wait_for_shell_exit(child, Duration::from_secs(2)) {
        log::info!("event=session.shell_stopped pid={process_id}");
    } else {
        log::error!("event=session.shell_stop_timed_out pid={process_id}");
    }
}

fn signal_shell(process_group: libc::pid_t, process_id: libc::pid_t, signal: libc::c_int) {
    // SAFETY: process_group and process_id come from the child this manager spawned.
    unsafe {
        libc::kill(process_group, signal);
        libc::kill(process_id, signal);
    }
}

fn wait_for_shell_exit(child: &mut Child, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => thread::sleep(Duration::from_millis(25)),
            Err(_) => return false,
        }
    }
    child.try_wait().ok().flatten().is_some()
}

fn handle_attachment(mut stream: UnixStream, manager: Weak<SessionManager>) {
    let mut request = Vec::new();
    let mut byte = [0_u8; 1];
    while request.len() <= 20 {
        match stream.read(&mut byte) {
            Ok(0) => return,
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) if byte[0].is_ascii_digit() => request.push(byte[0]),
            Ok(_) => return,
            Err(_) => return,
        }
    }
    let Ok(text) = std::str::from_utf8(&request) else {
        return;
    };
    let Ok(raw_id) = text.parse::<i64>() else {
        return;
    };
    let id = SessionId(raw_id);
    let Some(manager) = manager.upgrade() else {
        return;
    };
    let master = match manager.duplicate_master(id) {
        Ok(master) => master,
        Err(_) => return,
    };

    if send_file_descriptor(stream.as_raw_fd(), master.as_raw_fd()).is_err() {
        manager.mark_detached(id);
        return;
    }

    // Keep the control connection alive so the daemon knows when the client
    // has detached and can issue a new master descriptor to the next client.
    let mut discard = [0_u8; 64];
    while stream.read(&mut discard).unwrap_or(0) > 0 {}
    manager.mark_detached(id);
}

fn send_file_descriptor(socket_fd: RawFd, descriptor: RawFd) -> io::Result<()> {
    let mut byte = b'1';
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    let control_size = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0_usize; control_size.div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: zeroed msghdr is a valid starting point before its fields are initialized.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = control_size as _;

    // SAFETY: message points to valid iovec and control storage sized for one descriptor.
    let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    if header.is_null() {
        return Err(io::Error::other(
            "could not allocate PTY descriptor message",
        ));
    }
    // SAFETY: header points into message's control buffer with enough SCM_RIGHTS capacity.
    unsafe {
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
        std::ptr::copy_nonoverlapping(
            &descriptor as *const RawFd as *const u8,
            libc::CMSG_DATA(header).cast(),
            std::mem::size_of::<RawFd>(),
        );
    }

    // SAFETY: sendmsg reads the initialized message and descriptor; both remain alive here.
    let sent = unsafe { libc::sendmsg(socket_fd, &message, 0) };
    if sent == -1 {
        return Err(io::Error::last_os_error());
    }
    if sent != 1 {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "short PTY descriptor message",
        ));
    }
    Ok(())
}

fn parse_session_id(params: Params) -> Result<SessionId, RpcError> {
    let value: Value = params
        .parse()
        .map_err(|_| invalid_params("expected {sessionId}"))?;
    let id = value
        .get("sessionId")
        .and_then(Value::as_i64)
        .filter(|id| *id > 0)
        .ok_or_else(|| invalid_params("sessionId must be a positive integer"))?;
    Ok(SessionId(id))
}

fn invalid_params(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message: message.to_owned(),
        data: None,
    }
}

fn internal_rpc_error(error: io::Error) -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
        message: error.to_string(),
        data: None,
    }
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

impl Drop for RunningSession {
    fn drop(&mut self) {
        // Closing the master PTY sends SIGHUP to its controlling session, so a
        // daemon restart tears down the shell without archiving its DB record.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_a_shell_attached_to_a_real_pty() {
        let home = super::super::current_user_home_directory().unwrap();
        let mut session = spawn_shell(&home).unwrap();
        assert!(session.slave_device.starts_with("/dev/"));

        let master = session.master.as_raw_fd();
        let command = b"printf 'AXO_PTY_READY\\n'\n";
        // SAFETY: command points to initialized bytes and master is an open PTY.
        let written = unsafe { libc::write(master, command.as_ptr().cast(), command.len()) };
        assert_eq!(written as usize, command.len());
        assert!(read_until(master, b"AXO_PTY_READY", Duration::from_secs(3)));
        terminate_shell(&mut session.child);
    }

    fn read_until(master: RawFd, needle: &[u8], timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut received = Vec::new();
        while std::time::Instant::now() < deadline {
            let mut descriptor = libc::pollfd {
                fd: master,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: descriptor is a valid one-element poll array.
            let ready = unsafe { libc::poll(&mut descriptor, 1, 100) };
            if ready <= 0 {
                continue;
            }
            let mut bytes = [0_u8; 1024];
            // SAFETY: bytes is writable and master is open.
            let count = unsafe { libc::read(master, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count > 0 {
                received.extend_from_slice(&bytes[..count as usize]);
                if received
                    .windows(needle.len())
                    .any(|window| window == needle)
                {
                    return true;
                }
            }
        }
        false
    }
}
