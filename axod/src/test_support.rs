//! Disposable private filesystem fixtures; never opens live Axo state or signals real PIDs.
use std::fs::{self, DirBuilder};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

pub(crate) struct TestDirectory(PathBuf);
impl TestDirectory {
    pub(crate) fn new() -> Self {
        let path = std::env::temp_dir().join(format!("axod-unit-{}", uuid::Uuid::new_v4()));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    // Parallel PTY fork tests can briefly inherit another fixture's CLOEXEC lock before exec.
    // Wait only for this disposable root's ownership lock; never retry commands or corruption.
    pub(crate) fn reopen_journal(&self) -> crate::journal::Journal {
        self.try_reopen_journal()
            .expect("Owned fixture journal reopen failed")
    }
    pub(crate) fn try_reopen_journal(&self) -> std::io::Result<crate::journal::Journal> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            match crate::journal::Journal::open(&self.0) {
                Ok(journal) => return Ok(journal),
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                Err(error) => return Err(error),
            }
        }
    }
    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}
impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
