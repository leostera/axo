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
    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}
impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
