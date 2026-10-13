use super::*;
use crate::{pi_session::persistence::WriterLease, test_support::TestDirectory};
use std::{
    fs::DirBuilder,
    io::Write,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
};
fn directory(path: &Path) {
    DirBuilder::new().mode(0o700).create(path).unwrap();
}
fn file(path: &Path) {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap();
    file.write_all(b"owned canonical bytes\n").unwrap();
}
#[test]
fn bounded_owned_file_read_is_pinned_and_does_not_rewrite_bytes() {
    let root = TestDirectory::new();
    let path = root.path().join("session.jsonl");
    file(&path);
    let before = fs::read(&path).unwrap();
    assert_eq!(CanonicalFile::open(&path).unwrap().read().unwrap(), before);
    assert_eq!(fs::read(&path).unwrap(), before);
}
#[test]
fn symlink_hardlink_public_mode_fifo_and_oversized_files_are_refused() {
    let root = TestDirectory::new();
    let path = root.path().join("session.jsonl");
    file(&path);
    let link = root.path().join("alias.jsonl");
    symlink(&path, &link).unwrap();
    assert!(CanonicalFile::open(&link).is_err());
    fs::remove_file(&link).unwrap();
    fs::hard_link(&path, &link).unwrap();
    assert!(CanonicalFile::open(&path).is_err());
    fs::remove_file(&link).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(CanonicalFile::open(&path).is_err());
    assert_eq!(
        fs::metadata(&path).unwrap().mode() & 0o777,
        0o644,
        "No permission repair"
    );
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    OpenOptions::new()
        .write(true)
        .open(&path)
        .unwrap()
        .set_len(MAX_BYTES + 1)
        .unwrap();
    assert!(CanonicalFile::open(&path).is_err());
    let fifo = root.path().join("fifo");
    let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(CanonicalFile::open(&fifo).is_err());
}
#[test]
fn private_parent_symlink_and_public_directory_are_not_read_authority() {
    let root = TestDirectory::new();
    let parent = root.path().join("private");
    directory(&parent);
    let path = parent.join("session.jsonl");
    file(&path);
    let alias = root.path().join("alias");
    symlink(&parent, &alias).unwrap();
    assert!(CanonicalFile::open(&alias.join("session.jsonl")).is_err());
    assert!(WriterLease::acquire(&alias.join("session.jsonl")).is_err());
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(CanonicalFile::open(&path).is_err());
    assert!(WriterLease::acquire(&path).is_err());
    assert!(!parent.join(".session.jsonl.axo-writer.lock").exists());
}
#[test]
fn unsafe_existing_writer_locks_are_refused_without_modification() {
    let root = TestDirectory::new();
    let path = root.path().join("session.jsonl");
    let lock = root.path().join(".session.jsonl.axo-writer.lock");
    let opaque = root.path().join("opaque.lock");
    file(&opaque);
    let original = fs::read(&opaque).unwrap();
    symlink(&opaque, &lock).unwrap();
    assert!(WriterLease::acquire(&path).is_err());
    fs::remove_file(&lock).unwrap();
    fs::hard_link(&opaque, &lock).unwrap();
    assert!(WriterLease::acquire(&path).is_err());
    fs::remove_file(&lock).unwrap();
    fs::rename(&opaque, &lock).unwrap();
    fs::set_permissions(&lock, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(WriterLease::acquire(&path).is_err());
    assert_eq!(fs::read(&lock).unwrap(), original);
    assert_eq!(fs::metadata(&lock).unwrap().mode() & 0o777, 0o644);
}
#[test]
fn exchanged_parent_and_leaf_invalidate_previously_pinned_reads() {
    let root = TestDirectory::new();
    let parent = root.path().join("private");
    directory(&parent);
    let path = parent.join("session.jsonl");
    file(&path);
    let pinned = CanonicalFile::open(&path).unwrap();
    fs::rename(&parent, root.path().join("old-private")).unwrap();
    directory(&parent);
    file(&path);
    assert!(
        pinned.read().is_err(),
        "Parent exchange is not transparent rebinding"
    );
    let pinned = CanonicalFile::open(&path).unwrap();
    fs::rename(&path, parent.join("old.jsonl")).unwrap();
    file(&path);
    assert!(
        pinned.read().is_err(),
        "Leaf exchange must not publish a captured source"
    );
}
#[test]
fn writer_lease_detects_lock_and_parent_namespace_exchange_without_unlocking_successor() {
    let root = TestDirectory::new();
    let parent = root.path().join("private");
    directory(&parent);
    let path = parent.join("session.jsonl");
    let lease = WriterLease::acquire(&path).unwrap();
    lease.check().unwrap();
    let lock = parent.join(".session.jsonl.axo-writer.lock");
    fs::rename(&lock, parent.join("old.lock")).unwrap();
    assert!(lease.check().is_err());
    let successor = WriterLease::acquire(&path).unwrap();
    drop(lease);
    successor.check().unwrap();
    assert!(WriterLease::acquire(&path).is_err());
    fs::rename(&parent, root.path().join("old-private")).unwrap();
    directory(&parent);
    assert!(successor.check().is_err());
}
