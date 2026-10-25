//! Fixtures shared by the `session` modules' tests.

use super::*;
use axo_panes::UnavailablePane;
use axo_pi::bridge;
use axo_pi::takeover::TakeoverPolicy;
use axo_pi::{AgentCommand, BridgeSocketPath};
use axo_protocol::{Event, Layout, SessionId, ShellId, Viewport, new_uuid_v4};
use axo_pty::process;
use axo_pty::{NextOutput, OutputSubscriber};
use axo_store::Connection;
use axo_store::{DATABASE_FILE, store_pi_bridge_token};
use axo_store::{initialize_database, inserted_session_id, inserted_shell_id, unix_timestamp};
use rusqlite::params;
use serde_json::{Value, json};
use std::fs;
use std::io::BufReader;
use std::io::{self};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub(super) fn wait_for_shell_exit(child: &mut Child, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        match child.try_wait()? {
            Some(_) => return Ok(true),
            None => thread::sleep(Duration::from_millis(25)),
        }
    }
    Ok(child.try_wait()?.is_some())
}

pub(super) fn sid(value: i64) -> SessionId {
    SessionId::new(value).unwrap()
}

pub(super) fn shid(value: i64) -> ShellId {
    ShellId::new(value).unwrap()
}

/// An event as it goes over the wire.
pub(super) fn wire(event: impl std::ops::Deref<Target = Event>) -> Value {
    serde_json::to_value(&*event).unwrap()
}

/// A socket file whose listener is gone, as a killed Pi leaves it.
pub(super) fn abandoned_socket(path: &Path) {
    drop(UnixListener::bind(path).unwrap());
    assert!(fs::symlink_metadata(path).is_ok());
}

pub(super) fn bridge_socket_directory() -> PathBuf {
    // /tmp, not the per-user temp directory: socket paths are limited to 104 bytes.
    let directory = PathBuf::from("/tmp").join(format!("axo-bridge-{}", new_uuid_v4().unwrap()));
    fs::create_dir_all(&directory).unwrap();
    directory
}

pub(super) struct ChildProcessGuard(pub(super) Child);

impl Drop for ChildProcessGuard {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

pub(super) struct RunningShellGuard(pub(super) RunningShell);

impl Drop for RunningShellGuard {
    fn drop(&mut self) {
        process::stop(&mut self.0.child, process::SHELL_STOP_GRACE);
    }
}

/// Opens a manager whose shells (the home Session's included) run a silent stand-in for the
/// login shell: no profile, no history, and no output to race a test's event assertions.
pub(super) fn open_with_silent_shell(directory: &Path) -> Arc<SessionManager> {
    let shell = directory.join("silent-shell");
    fs::write(&shell, "#!/bin/sh\nexec /bin/sleep 3600\n").unwrap();
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
    let mut database = Connection::open(directory.join(DATABASE_FILE)).unwrap();
    initialize_database(&mut database).unwrap();
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![shell.to_string_lossy()],
        )
        .unwrap();
    drop(database);
    SessionManager::open(directory).unwrap()
}

pub(super) struct LifecycleFixture {
    pub(super) directory: PathBuf,
    pub(super) manager: Arc<SessionManager>,
}

impl LifecycleFixture {
    pub(super) fn new() -> Self {
        let directory = PathBuf::from("/tmp").join(format!("axo-life-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        // Lifecycle tests must not race real login-profile initialization or
        // read/write the user's shell history. Seed only this private catalog.
        let shell = directory.join("fixture-shell");
        fs::write(
            &shell,
            "#!/bin/sh\nunset ENV BASH_ENV\nexport HISTFILE=/dev/null\nexec /bin/sh -i\n",
        )
        .unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
        let mut database = Connection::open(directory.join(DATABASE_FILE)).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1)",
                params![shell.to_string_lossy()],
            )
            .unwrap();
        drop(database);
        let manager = SessionManager::open(&directory).unwrap();
        // Keep state transitions deterministic: these tests drive the reaper
        // explicitly, rather than racing its periodic background tick.
        manager.stop_workers.store(true, Ordering::Relaxed);
        let workers = std::mem::take(&mut *manager.workers.lock().unwrap());
        join_session_workers(workers);
        Self { directory, manager }
    }
}

impl Drop for LifecycleFixture {
    fn drop(&mut self) {
        self.manager.shutdown();
        let _ = fs::remove_dir_all(&self.directory);
    }
}

pub(super) struct PiRecoveryFixture {
    pub(super) lifecycle: LifecycleFixture,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) session_uuid: String,
    pub(super) pane_id: String,
    pub(super) file: PathBuf,
    pub(super) socket: BridgeSocketPath,
    pub(super) token: String,
}

impl PiRecoveryFixture {
    pub(super) fn new() -> Self {
        let lifecycle = LifecycleFixture::new();
        let manager = &lifecycle.manager;
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let token = new_uuid_v4().unwrap();
        let file = manager
            .pi_session_directory
            .join(format!("{session_uuid}.jsonl"));
        let socket =
            BridgeSocketPath::for_session(&manager.pi_session_directory, &session_uuid).unwrap();
        fs::write(&file, b"original history\n").unwrap();
        let executable = lifecycle.directory.join("fake-pi");
        fs::write(&executable, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let (session_id, shell_id) = {
            let mut state = manager.lock_state().unwrap();
            state.agent_command = AgentCommand::parse(executable.to_str().unwrap()).unwrap();
            state.database.execute(
                "INSERT INTO sessions (initial_pwd, state, created_at, session_uuid, pi_session_file, pi_bridge_socket_path)
                 VALUES (?1, 'open', ?2, ?3, ?4, ?5)",
                params![lifecycle.directory.to_string_lossy(), unix_timestamp(), session_uuid, file.to_string_lossy(), socket.as_str()],
            ).unwrap();
            let session_id = inserted_session_id(&state.database).unwrap();
            state.database.execute(
                "INSERT INTO shells (session_id, initial_pwd, state, created_at, role, pane_id) VALUES (?1, ?2, 'open', ?3, 'pi', ?4)",
                params![session_id.get(), lifecycle.directory.to_string_lossy(), unix_timestamp(), pane_id],
            ).unwrap();
            let shell_id = inserted_shell_id(&state.database).unwrap();
            state
                .database
                .execute(
                    "UPDATE sessions SET layout_json = ?1 WHERE id = ?2",
                    params![
                        serde_json::to_string(&Layout::single(shell_id)).unwrap(),
                        session_id.get()
                    ],
                )
                .unwrap();
            store_pi_bridge_token(&state.database, &session_uuid, &token).unwrap();
            state
                .panes
                .insert_unavailable(
                    shell_id,
                    UnavailablePane::new(
                        session_id,
                        Some(pane_id.clone()),
                        lifecycle.directory.clone(),
                    ),
                )
                .unwrap();
            (session_id, shell_id)
        };
        Self {
            lifecycle,
            session_id,
            shell_id,
            session_uuid,
            pane_id,
            file,
            socket,
            token,
        }
    }

    pub(super) fn begin_recovery(
        &self,
        policy: TakeoverPolicy,
    ) -> (JoinHandle<io::Result<()>>, BufReader<UnixStream>) {
        let session_id = self.session_id;
        let shell_id = self.shell_id;
        self.observe_operation(move |manager| {
            manager
                .restart_unavailable_pi(session_id, shell_id, policy)
                .map(|_| ())
        })
    }

    pub(super) fn observe_operation(
        &self,
        operation: impl FnOnce(Arc<SessionManager>) -> io::Result<()> + Send + 'static,
    ) -> (JoinHandle<io::Result<()>>, BufReader<UnixStream>) {
        let listener = UnixListener::bind(self.socket.as_path()).unwrap();
        listener.set_nonblocking(true).unwrap();
        let manager = Arc::clone(&self.lifecycle.manager);
        let worker = thread::spawn(move || operation(manager));
        let deadline = Instant::now() + Duration::from_secs(3);
        let stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline =>
                {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(error) => panic!("recovery never reached the fixture bridge: {error}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut reader = BufReader::new(stream);
        let auth = bridge::read_record::<Value>(&mut reader).unwrap();
        assert_eq!(auth["token"], self.token);
        (worker, reader)
    }

    pub(super) fn accept_shutdown(&self, reader: &mut BufReader<UnixStream>, process_id: u32) {
        bridge::write_record(
            reader.get_mut(),
            &json!({ "type": "authenticated", "protocolVersion": 1 }),
        )
        .unwrap();
        bridge::write_record(reader.get_mut(), &json!({
            "type": "hello", "protocolVersion": 1,
            "identity": { "axoSessionId": self.session_uuid, "axoPaneId": self.pane_id, "piSessionId": "pi-takeover",
                "sessionFile": self.file, "cwd": self.lifecycle.directory, "processId": process_id }
        })).unwrap();
        let command = bridge::read_record::<Value>(reader).unwrap();
        assert_eq!(command["type"], "command");
        bridge::write_record(reader.get_mut(), &json!({
            "type": "commandResult", "requestId": command["requestId"], "result": { "accepted": true }
        })).unwrap();
    }

    pub(super) fn assert_preserved(&self) {
        assert_eq!(fs::read(&self.file).unwrap(), b"original history\n");
    }
}

/// Whether the catalog lock can be taken within a second. Code that wrongly holds it across a
/// blocked operation holds it the whole time; a single `try_lock` would also fail whenever
/// another thread holds it for a moment.
pub(super) fn catalog_lock_is_free(manager: &SessionManager) -> bool {
    let deadline = std::time::Instant::now() + Duration::from_secs(1);
    loop {
        if manager.state.try_lock().is_ok() {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// How long to wait for a test shell's output. Only a failing test waits this long, and a shell
/// started while many test processes launch has taken over 3 s to answer.
pub(super) const SHELL_OUTPUT_WAIT: Duration = Duration::from_secs(15);

pub(super) fn read_until(output: &OutputSubscriber, needle: &[u8], timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    let mut received = Vec::new();
    while std::time::Instant::now() < deadline {
        match output.next(Duration::from_millis(100)) {
            NextOutput::Chunks(chunks) => {
                // Scan only the new bytes (and a needle's worth before), not all output again.
                let start = received.len().saturating_sub(needle.len() - 1);
                for chunk in chunks {
                    received.extend_from_slice(&chunk);
                }
                if received[start..]
                    .windows(needle.len())
                    .any(|window| window == needle)
                {
                    return true;
                }
            }
            NextOutput::Idle => {}
            _ => return false,
        }
    }
    false
}

pub(super) fn pty_size(manager: &SessionManager, shell_id: ShellId) -> (u16, u16) {
    let state = manager.lock_state().unwrap();
    let size = process::window_size(&state.panes.running(shell_id).unwrap().master).unwrap();
    (size.rows(), size.columns())
}

pub(super) fn test_viewport(width: f64) -> Viewport {
    serde_json::from_value(json!({
        "terminalArea": { "width": width, "height": 600.0 },
        "backingScale": 2.0,
        "cell": { "width": 16, "height": 34 },
        "padding": { "top": 10, "bottom": 10, "left": 2, "right": 2 },
        "dividerThickness": 1.0
    }))
    .unwrap()
}
