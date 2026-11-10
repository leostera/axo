//! What the crate's tests share: an axod core in a directory of its own, whose shells and Pis are
//! silent stand-ins.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;

use axo_protocol::{SessionRecord, new_uuid_v4};
use axo_store::{Connection, DATABASE_FILE, initialize_database};

use crate::core::Core;

/// A fresh directory under `/tmp` for one test, with a short name: socket paths are limited to
/// 104 bytes.
pub(crate) fn test_directory(prefix: &str) -> PathBuf {
    let unique = new_uuid_v4().unwrap().replace('-', "");
    PathBuf::from("/tmp").join(format!("{prefix}-{}", &unique[..12]))
}

pub(crate) struct Fixture {
    pub(crate) directory: PathBuf,
    pub(crate) core: Arc<Core>,
}

impl Fixture {
    /// An axod core whose shells and Pis run a silent stand-in: no profile, no output to race a
    /// test's assertions, and never the user's real Pi. Run it in a multi-threaded runtime.
    pub(crate) async fn new() -> Self {
        let directory = test_directory("axo-server");
        fs::create_dir_all(&directory).unwrap();
        let directory = directory.canonicalize().unwrap();
        let shell = directory.join("silent-shell");
        fs::write(&shell, "#!/bin/sh\nexec /bin/sleep 3600\n").unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
        let mut database = Connection::open(directory.join(DATABASE_FILE)).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1), ('agent_command', ?1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                rusqlite::params![shell.to_string_lossy()],
            )
            .unwrap();
        drop(database);
        let (core, previous) = crate::open_core(
            &directory,
            &directory.join("sessions"),
            &directory.join("axod.sock"),
            tokio::runtime::Handle::current(),
        )
        .unwrap();
        crate::sessions::restore(&core, previous).await.unwrap();
        Self { directory, core }
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
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}
