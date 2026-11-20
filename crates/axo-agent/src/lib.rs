//! Coding agents for Axod (RFD0072): which agent a Session runs and what it can do (`kind`), the
//! one shape every running agent presents to its Session (`runtime`), and each agent's adapter.
//! Unix agents use the Session's TUI and lifeline; Windows currently supports Codex through
//! its stdio app-server. Each adapter owns its transport and agent process.
//!
//! Nothing here knows about the session catalog or its database; callers decide which agent to
//! launch and when, and what its events mean for the catalog.

pub mod activity;
#[cfg(unix)]
pub mod axo_mcp;
#[cfg(unix)]
pub mod catalog;
#[cfg(unix)]
mod channel;
#[cfg(unix)]
pub mod claude;
pub mod version;
// The Unix TUI and Windows stdio clients have different process/transport contracts.
#[cfg(unix)]
#[path = "codex/mod.rs"]
pub mod codex;
#[cfg(windows)]
#[path = "codex.rs"]
pub mod codex;
#[cfg(unix)]
mod command;
#[cfg(unix)]
pub mod discovery;
#[cfg(unix)]
mod history;
#[cfg(unix)]
mod lock;
#[cfg(unix)]
pub mod opencode;
#[cfg(unix)]
pub mod pi;
#[cfg(unix)]
pub mod process;
#[cfg(unix)]
mod runtime;
pub mod transcript;
#[cfg(unix)]
mod vocabulary;

pub use activity::Activity;
pub use axo_protocol::agent::{AgentKind, Capabilities, Deliveries, UnknownAgent};
#[cfg(unix)]
pub use axo_pty::lifeline::{LIFELINE_FD, Lifeline};
#[cfg(unix)]
pub use command::AgentCommand;
#[cfg(unix)]
pub use history::{HistoryIdentity, ensure_existing_history, recoverable_history};
#[cfg(unix)]
pub use lock::{FORK_EXEC_WINDOW, WriterLock};
#[cfg(unix)]
pub use runtime::{AgentCommands, AgentEvent, CommandResult, QueuedDelivery, RejectReason};

/// A fresh test directory. Unix socket tests need short paths under /tmp.
#[cfg(test)]
pub(crate) fn test_directory() -> std::path::PathBuf {
    #[cfg(unix)]
    let root = std::path::PathBuf::from("/tmp");
    #[cfg(windows)]
    let root = std::env::temp_dir();
    let directory = root.join(format!(
        "axo-agent-test-{}",
        axo_protocol::new_uuid_v4().unwrap()
    ));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

/// A child forked from this process and held just before exec, so it still has a copy of every
/// descriptor this process had open, as any concurrently launching process briefly does.
#[cfg(all(test, unix))]
pub(crate) struct PausedBeforeExec {
    release: std::os::fd::OwnedFd,
    spawning: std::thread::JoinHandle<std::process::ExitStatus>,
}

#[cfg(all(test, unix))]
impl PausedBeforeExec {
    /// Returns once the child has forked (and so holds its copies).
    pub(crate) fn fork() -> Self {
        use std::os::fd::AsRawFd;
        use std::os::unix::process::CommandExt;

        let (forked_read, forked_write) = test_pipe();
        let (release_read, release_write) = test_pipe();
        let (forked, release) = (forked_write.as_raw_fd(), release_read.as_raw_fd());
        let mut command = std::process::Command::new("/usr/bin/true");
        // SAFETY: the child only calls write and read, both async-signal-safe, on pipe ends kept
        // open by the spawning thread until exec.
        unsafe {
            command.pre_exec(move || {
                libc::write(forked, [1_u8].as_ptr().cast(), 1);
                let mut byte = 0_u8;
                libc::read(release, (&mut byte as *mut u8).cast(), 1);
                Ok(())
            });
        }
        let spawning = std::thread::spawn(move || {
            let status = command.spawn().unwrap().wait().unwrap();
            drop((forked_write, release_read));
            status
        });
        let mut byte = 0_u8;
        // SAFETY: byte is writable; forked_read is open.
        let read = unsafe { libc::read(forked_read.as_raw_fd(), (&mut byte as *mut u8).cast(), 1) };
        assert_eq!(read, 1, "the child never reported its fork");
        Self {
            release: release_write,
            spawning,
        }
    }

    /// Lets the child exec (closing its close-on-exec copies) and waits for it.
    pub(crate) fn exec(self) -> std::process::ExitStatus {
        use std::os::fd::AsRawFd;
        // SAFETY: release is the open write end of the child's pipe.
        assert_eq!(
            unsafe { libc::write(self.release.as_raw_fd(), [1_u8].as_ptr().cast(), 1) },
            1
        );
        self.spawning.join().unwrap()
    }
}

#[cfg(all(test, unix))]
fn test_pipe() -> (std::os::fd::OwnedFd, std::os::fd::OwnedFd) {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let mut fds = [0; 2];
    // SAFETY: fds is writable storage for two descriptors.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    // SAFETY: pipe returned two new descriptors owned from here on.
    let ends = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    axo_pty::process::set_cloexec(ends.0.as_raw_fd()).unwrap();
    axo_pty::process::set_cloexec(ends.1.as_raw_fd()).unwrap();
    ends
}

mod bridge_path;

// Persisted Pi addresses remain readable even though Windows cannot launch Pi.
#[cfg(windows)]
#[path = "pi_windows.rs"]
pub mod pi;
