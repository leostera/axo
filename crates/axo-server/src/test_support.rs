//! What the crate's tests share: an axod core in a directory of its own, whose shells are silent
//! stand-ins and whose Pi is either silent or axod's fake Pi (`crates/axod/testdata/fake_pi.rs`),
//! which binds the bridge, answers commands and writes a transcript.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axo_protocol::{PaneRole, SessionId, SessionRecord, ShellId, new_uuid_v4};
use axo_store::{Connection, DATABASE_FILE, initialize_database};

use crate::core::Core;

/// A fresh directory under `/tmp` for one test, with a short name: socket paths are limited to
/// 104 bytes.
pub(crate) fn test_directory(prefix: &str) -> PathBuf {
    let unique = new_uuid_v4().unwrap().replace('-', "");
    PathBuf::from("/tmp").join(format!("{prefix}-{}", &unique[..12]))
}

/// Which program the fixture's Pi panes run.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Pi {
    /// Sleeps and never binds its bridge: a Pi that is slow to start, or that never does.
    Silent,
    /// axod's fake Pi, whose turns take `turn_ms`.
    Fake { turn_ms: u64 },
}

pub(crate) struct Fixture {
    pub(crate) directory: PathBuf,
    pub(crate) core: Arc<Core>,
    /// Stops the attach socket, once `listen` started it.
    attachments: Option<axo_ipc::Stop>,
}

impl Fixture {
    /// A core whose shells and Pis run a silent stand-in: no profile, no output to race a test's
    /// assertions, and never the user's real Pi. Run it in a multi-threaded runtime.
    pub(crate) async fn new() -> Self {
        Self::with(Pi::Silent).await
    }

    pub(crate) async fn with(pi: Pi) -> Self {
        let directory = test_directory("axo-server");
        fs::create_dir_all(&directory).unwrap();
        let directory = directory.canonicalize().unwrap();
        let shell = executable(
            &directory.join("silent-shell"),
            "#!/bin/sh\nexec /bin/sleep 3600\n",
        );
        let agent = match pi {
            Pi::Silent => shell.clone(),
            Pi::Fake { turn_ms } => {
                let fake = std::env::var("AXO_TEST_FAKE_PI").expect("the fake Pi's runfile");
                let fake = fs::canonicalize(fake).unwrap();
                fs::write(directory.join("turn-ms"), turn_ms.to_string()).unwrap();
                executable(
                    &directory.join("fake-pi"),
                    &format!(
                        "#!/bin/sh\nAXO_FAKE_PI_LOG='{}' AXO_FAKE_PI_STARTUP_MS=20 AXO_FAKE_PI_TURN_MS=$(cat '{}') exec '{}' \"$@\"\n",
                        directory.join("pi.log").display(),
                        directory.join("turn-ms").display(),
                        fake.display()
                    ),
                )
            }
        };
        let mut database = Connection::open(directory.join(DATABASE_FILE)).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1), ('agent_command', ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                rusqlite::params![shell.to_string_lossy(), agent.to_string_lossy()],
            )
            .unwrap();
        drop(database);
        let core = open(&directory).await;
        Self {
            directory,
            core,
            attachments: None,
        }
    }

    /// Stops this core as axod stops, and opens the next on the same directory.
    pub(crate) async fn restart(&mut self) {
        if let Some(stop) = self.attachments.take() {
            stop.stop();
        }
        crate::sessions::stop(&self.core).await;
        self.core = open(&self.directory).await;
    }

    /// How long the fake Pi's turns last from its next start.
    pub(crate) fn set_turn_ms(&self, turn_ms: u64) {
        fs::write(self.directory.join("turn-ms"), turn_ms.to_string()).unwrap();
    }

    /// Serves the attach socket, as axod does.
    pub(crate) fn listen(&mut self) {
        let stop = axo_ipc::Stop::default();
        crate::attachments::listen(&self.core, stop.clone()).unwrap();
        self.attachments = Some(stop);
    }

    /// A new Session with Pi beside a terminal, in the test's own directory.
    pub(crate) async fn new_session(&self) -> SessionRecord {
        crate::sessions::create(
            &self.core,
            axo_protocol::rpc::CreateSession {
                folder: Some(self.directory.clone()),
                like: None,
            },
        )
        .await
        .unwrap()
    }

    /// The Session as the catalog lists it now.
    pub(crate) fn listed(&self, id: SessionId) -> Option<SessionRecord> {
        self.core.catalog.record(id)
    }

    /// What the fake Pi was typed and sent so far.
    pub(crate) fn pi_log(&self) -> String {
        fs::read_to_string(self.directory.join("pi.log")).unwrap_or_default()
    }

    /// Waits for `check` to hold; a test that would wait longer fails, naming `what`.
    pub(crate) async fn until(&self, what: &str, mut check: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// Waits for the Session's Pi to bind its bridge.
    pub(crate) async fn wait_for_pi(&self, id: SessionId) {
        crate::sessions::wait_for_pi(&self.core, id, Duration::from_secs(10))
            .await
            .unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stop) = self.attachments.take() {
            stop.stop();
        }
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
}

async fn open(directory: &Path) -> Arc<Core> {
    let (core, previous) = crate::open_core(
        directory,
        &directory.join("sessions"),
        &directory.join("axod.sock"),
        tokio::runtime::Handle::current(),
    )
    .unwrap();
    crate::sessions::restore(&core, previous).await.unwrap();
    core
}

fn executable(path: &Path, script: &str) -> PathBuf {
    fs::write(path, script).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    path.to_path_buf()
}

/// The pane of `role` in a Session; a new Session has one of each, Pi first.
pub(crate) fn pane(record: &SessionRecord, role: PaneRole) -> ShellId {
    record
        .shells
        .iter()
        .find(|shell| shell.role == role)
        .unwrap_or_else(|| panic!("the Session has no {role:?} pane"))
        .id
}

/// The process of the pane of `role`, or 0 while it is unavailable.
pub(crate) fn pid(record: &SessionRecord, role: PaneRole) -> i32 {
    record
        .shells
        .iter()
        .find(|shell| shell.role == role)
        .map_or(0, |shell| shell.process_id as i32)
}

pub(crate) fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only asks whether the process exists.
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}
