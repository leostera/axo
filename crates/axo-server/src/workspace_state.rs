//! What a Session's folder looks like to git, so another Mac can tell what it would need to
//! continue the Session (RFD0022).
//!
//! Read after the agent settles, in a task of its own with `tokio::process`: git can be slow on a
//! big repository, and nothing waits for it. One read per Session runs at a time; a settle during
//! a read reads again once it ends, so the state is never older than the last settle.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axo_protocol::SessionId;
use axo_relay::WorkspaceState;

/// The longest one git command may take.
const GIT_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Default)]
pub(crate) struct WorkspaceStates {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    known: HashMap<SessionId, WorkspaceState>,
    reading: HashSet<SessionId>,
    /// Sessions that settled again while being read.
    again: HashSet<SessionId>,
}

impl WorkspaceStates {
    /// The last state read for the Session, if any since axod started.
    pub(crate) fn get(&self, session_id: SessionId) -> Option<WorkspaceState> {
        self.inner.lock().ok()?.known.get(&session_id).cloned()
    }

    /// Reads the Session's folder again, in the background.
    pub(crate) fn refresh(&self, session_id: SessionId, path: PathBuf) {
        {
            let Ok(mut inner) = self.inner.lock() else {
                return;
            };
            if !inner.reading.insert(session_id) {
                inner.again.insert(session_id);
                return;
            }
        }
        let inner = Arc::clone(&self.inner);
        tokio::spawn(async move {
            loop {
                let state = read(&path, unix_now()).await;
                let Ok(mut guard) = inner.lock() else { return };
                guard.known.insert(session_id, state);
                if !guard.again.remove(&session_id) {
                    guard.reading.remove(&session_id);
                    return;
                }
            }
        });
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0)
}

/// The folder's state now. A folder outside a repository, or a git that fails, gives the path
/// alone.
pub(crate) async fn read(path: &Path, at: i64) -> WorkspaceState {
    let mut state = WorkspaceState {
        path: path.to_string_lossy().into_owned(),
        repo_root: None,
        remote: None,
        branch: None,
        head: None,
        upstream_head: None,
        dirty: Vec::new(),
        dirty_more: 0,
        at,
    };
    let Some(root) = git(path, &["rev-parse", "--show-toplevel"]).await else {
        return state;
    };
    let root = PathBuf::from(root);
    state.repo_root = Some(root.to_string_lossy().into_owned());
    state.head = git(&root, &["rev-parse", "--verify", "-q", "HEAD"]).await;
    state.branch = git(&root, &["symbolic-ref", "-q", "--short", "HEAD"]).await;
    let upstream = git(
        &root,
        &[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    )
    .await;
    if upstream.is_some() {
        state.upstream_head = git(&root, &["rev-parse", "--verify", "-q", "@{upstream}"]).await;
    }
    let remote_name = upstream
        .as_deref()
        .and_then(|upstream| upstream.split_once('/'))
        .map(|(remote, _)| remote.to_owned())
        .unwrap_or_else(|| "origin".to_owned());
    state.remote = git(&root, &["remote", "get-url", &remote_name])
        .await
        .map(|url| without_credentials(&url));
    if let Some(status) = git(
        &root,
        &["status", "--porcelain=v1", "--untracked-files=normal"],
    )
    .await
    {
        let paths: Vec<String> = status
            .lines()
            .filter_map(|line| line.get(3..))
            .map(str::to_owned)
            .collect();
        state.dirty_more = paths.len().saturating_sub(WorkspaceState::MAX_DIRTY) as u32;
        state.dirty = paths.into_iter().take(WorkspaceState::MAX_DIRTY).collect();
    }
    state
}

/// `https://user:token@github.com/a/b` → `https://github.com/a/b`. An scp-like `git@host:path`
/// names no secret and is kept.
fn without_credentials(url: &str) -> String {
    match url.split_once("://") {
        Some((scheme, rest)) => {
            let (authority, path) = rest.split_once('/').map_or((rest, ""), |(a, p)| (a, p));
            let host = authority
                .rsplit_once('@')
                .map_or(authority, |(_, host)| host);
            if path.is_empty() && !rest.contains('/') {
                format!("{scheme}://{host}")
            } else {
                format!("{scheme}://{host}/{path}")
            }
        }
        None => url.to_owned(),
    }
}

/// One git command's trimmed output, or None if it failed, printed nothing or took too long.
async fn git(directory: &Path, arguments: &[&str]) -> Option<String> {
    let child = tokio::process::Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        // Reading must never take the index lock from the agent's own git.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        // Past the limit, dropping it kills it.
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let output = tokio::time::timeout(GIT_TIMEOUT, child.wait_with_output())
        .await
        .ok()?
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim_end_matches(['\n', '\r']).to_owned();
    (output.status.success() && !text.trim().is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh folder, removed when dropped.
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("axo-workspace-state-{}-{n}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path.canonicalize().unwrap())
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn run(directory: &Path, arguments: &[&str]) {
        let status = std::process::Command::new("git")
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_AUTHOR_NAME", "Axo")
            .env("GIT_AUTHOR_EMAIL", "axo@example.com")
            .env("GIT_COMMITTER_NAME", "Axo")
            .env("GIT_COMMITTER_EMAIL", "axo@example.com")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "git {arguments:?}");
    }

    #[tokio::test]
    async fn a_folder_outside_a_repository_gives_its_path_alone() {
        let directory = Scratch::new();
        let state = read(directory.path(), 7).await;
        assert_eq!(state.path, directory.path().to_string_lossy());
        assert_eq!(
            (state.repo_root, state.head, state.branch),
            (None, None, None)
        );
        assert!(state.dirty.is_empty());
        assert_eq!(state.at, 7);
    }

    #[tokio::test]
    async fn a_repository_gives_its_branch_commit_remote_and_changes() {
        let directory = Scratch::new();
        let root = directory.path().to_path_buf();
        run(&root, &["init", "-q", "-b", "relay-backoff"]);
        std::fs::write(root.join("relay.rs"), "one").unwrap();
        run(&root, &["add", "relay.rs"]);
        run(&root, &["commit", "-q", "-m", "one"]);
        run(
            &root,
            &[
                "remote",
                "add",
                "origin",
                "https://leo:secret@github.com/leostera/axo.git",
            ],
        );
        std::fs::write(root.join("relay.rs"), "two").unwrap();
        std::fs::write(root.join("new.rs"), "new").unwrap();
        std::fs::create_dir(root.join("crates")).unwrap();

        let state = read(&root.join("crates"), 1).await;
        assert_eq!(state.repo_root.as_deref(), Some(&*root.to_string_lossy()));
        assert_eq!(state.branch.as_deref(), Some("relay-backoff"));
        assert_eq!(state.head.as_deref().map(str::len), Some(40));
        assert_eq!(state.upstream_head, None, "no upstream yet");
        assert_eq!(
            state.remote.as_deref(),
            Some("https://github.com/leostera/axo.git"),
            "no credentials"
        );
        let mut dirty = state.dirty.clone();
        dirty.sort();
        assert_eq!(dirty, ["new.rs", "relay.rs"]);
    }

    #[test]
    fn credentials_never_leave_a_remote_url() {
        assert_eq!(
            without_credentials("https://x-access-token:ghp_1@github.com/a/b"),
            "https://github.com/a/b"
        );
        assert_eq!(
            without_credentials("ssh://git@github.com/a/b"),
            "ssh://github.com/a/b"
        );
        assert_eq!(
            without_credentials("https://github.com"),
            "https://github.com"
        );
        assert_eq!(
            without_credentials("git@github.com:a/b.git"),
            "git@github.com:a/b.git"
        );
    }
}
