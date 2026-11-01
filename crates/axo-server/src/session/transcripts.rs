//! Where Pi transcripts live (RFD0022).
//!
//! Every Mac's transcripts are kept by host, the same way on every Mac:
//! `~/.axo/sessions/<hostId>/<workspaceId>/<sessionId>.jsonl`. This Mac writes its own under its
//! host id; the other Macs' are copies (see `axo_relay::peers`). `~/.axo/server/` keeps only this
//! Mac's server state: its database, and Pi's bridge sockets in `server/pi-sessions/`.
//!
//! Transcripts used to live in `server/pi-sessions/<workspaceId>/`. Opening moves each such
//! folder to the host's folder once, leaves a symlink behind for any Pi still writing by the old
//! path, and points the database at the new place.

use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use axo_store::Connection;

pub(super) struct PiDirectories {
    /// This Mac's transcripts: `<sessions>/<hostId>`.
    pub(super) transcripts: PathBuf,
    /// Pi's bridge sockets, in `server/pi-sessions`, where transcripts used to be.
    pub(super) bridges: PathBuf,
}

impl PiDirectories {
    /// The folder a transcript must be inside to be Axo's own: the host's folder, or for a file
    /// still at its old place, `pi-sessions`.
    pub(super) fn home_of(&self, file: &Path) -> &Path {
        let canonical = fs::canonicalize(file).or_else(|_| {
            file.parent()
                .map(fs::canonicalize)
                .unwrap_or_else(|| Err(io::Error::from(io::ErrorKind::NotFound)))
        });
        match (canonical, fs::canonicalize(&self.transcripts)) {
            (Ok(file), Ok(transcripts)) if file.starts_with(&transcripts) => &self.transcripts,
            _ => &self.bridges,
        }
    }
}

/// Prepares the host's transcript folder and moves older transcripts into it.
pub(super) fn open(
    database: &mut Connection,
    bridges: PathBuf,
    sessions_directory: &Path,
    host_id: &str,
) -> io::Result<PiDirectories> {
    private_directory(sessions_directory)?;
    // Paths are stored and compared as text, so they are canonical (`/tmp` is `/private/tmp`).
    let transcripts = fs::canonicalize(sessions_directory)?.join(host_id);
    private_directory(&transcripts)?;
    describe_host(&transcripts, host_id);
    move_older_transcripts(database, &bridges, &transcripts)?;
    Ok(PiDirectories {
        transcripts,
        bridges,
    })
}

fn private_directory(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// `host.json` says which Mac a folder is, for people reading `~/.axo/sessions`.
fn describe_host(folder: &Path, host_id: &str) {
    let description = serde_json::json!({ "hostId": host_id, "label": axo_relay::host_label() });
    let written = serde_json::to_vec_pretty(&description)
        .map_err(io::Error::other)
        .and_then(|bytes| fs::write(folder.join("host.json"), bytes));
    if let Err(error) = written {
        log::warn!("event=transcripts.host_description_failed error={error}");
    }
}

fn move_older_transcripts(
    database: &mut Connection,
    bridges: &Path,
    transcripts: &Path,
) -> io::Result<()> {
    for entry in fs::read_dir(bridges)? {
        let entry = entry?;
        // Workspace folders only: sockets stay, and a symlink is a folder already moved.
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let from = entry.path();
        let to = transcripts.join(&name);
        if let Err(error) = move_folder(&from, &to) {
            log::warn!(
                "event=transcripts.move_failed folder={} error={error}",
                from.display()
            );
            continue;
        }
        let moved = axo_store::relocate_pi_session_files(database, &from, &to)?;
        std::os::unix::fs::symlink(&to, &from)?;
        log::info!(
            "event=transcripts.moved folder={} sessions={moved}",
            to.display()
        );
    }
    Ok(())
}

/// Moves a folder, or merges it into one already there. A file present at both places stays
/// where it was, and the folder is not moved.
fn move_folder(from: &Path, to: &Path) -> io::Result<()> {
    if !to.exists() {
        return fs::rename(from, to);
    }
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if !target.exists() {
            fs::rename(entry.path(), target)?;
        }
    }
    fs::remove_dir(from)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "axo-transcripts-{}",
                axo_protocol::new_uuid_v4().unwrap()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path.canonicalize().unwrap())
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const HOST: &str = "1e1e7f91-3d8f-4f97-8f71-4fc7d53313c6";
    const WORKSPACE: &str = "8f8f8f8f-0000-4000-8000-000000000001";

    #[test]
    fn older_transcripts_move_to_the_hosts_folder_and_the_old_path_still_works() {
        let scratch = Scratch::new();
        let bridges = scratch.0.join("server/pi-sessions");
        let old = bridges.join(WORKSPACE).join("s1.jsonl");
        fs::create_dir_all(old.parent().unwrap()).unwrap();
        fs::write(&old, "history\n").unwrap();
        fs::write(bridges.join("s1.sock"), "").unwrap();
        let mut database = Connection::open_in_memory().unwrap();
        axo_store::initialize_database(&mut database).unwrap();

        let directories = open(
            &mut database,
            bridges.clone(),
            &scratch.0.join("sessions"),
            HOST,
        )
        .unwrap();

        let new = scratch
            .0
            .join("sessions")
            .join(HOST)
            .join(WORKSPACE)
            .join("s1.jsonl");
        assert_eq!(fs::read_to_string(&new).unwrap(), "history\n");
        // A Pi still writing by the old path writes the moved file.
        assert_eq!(fs::read_to_string(&old).unwrap(), "history\n");
        assert!(bridges.join("s1.sock").exists(), "sockets stay in server/");
        assert_eq!(directories.home_of(&new), directories.transcripts);
        assert_eq!(
            directories.home_of(&old),
            directories.transcripts,
            "the old path leads to the new place"
        );
        let description: serde_json::Value = serde_json::from_slice(
            &fs::read(scratch.0.join("sessions").join(HOST).join("host.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(description["hostId"], HOST);

        // Opening again moves nothing more.
        open(
            &mut database,
            bridges.clone(),
            &scratch.0.join("sessions"),
            HOST,
        )
        .unwrap();
        assert_eq!(fs::read_to_string(&new).unwrap(), "history\n");
    }

    #[test]
    fn a_file_at_the_old_place_alone_is_still_axos_own() {
        let scratch = Scratch::new();
        let bridges = scratch.0.join("server/pi-sessions");
        fs::create_dir_all(&bridges).unwrap();
        let flat = bridges.join("s2.jsonl");
        fs::write(&flat, "history\n").unwrap();
        let mut database = Connection::open_in_memory().unwrap();
        axo_store::initialize_database(&mut database).unwrap();
        let directories = open(
            &mut database,
            bridges.clone(),
            &scratch.0.join("sessions"),
            HOST,
        )
        .unwrap();
        assert_eq!(directories.home_of(&flat), bridges.as_path());
    }
}
