//! A child and the thread that waits for it to exit (RFD0037, "Child processes: one blocking
//! waiter each").
//!
//! The waiter blocks in `waitid(WEXITED | WNOWAIT)`: it learns of the exit the moment the kernel
//! does, and leaves the child unreaped. Reaping stays with the owner, through `try_wait`, which
//! reaps only once the waiter has seen the exit. So a pid is never reaped, and so never reused,
//! while the waiter or anything signalling the child could still name it.

use std::io;
use std::process::{Child, ExitStatus};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

/// What happens when a child exits: callbacks run on its waiter thread.
type OnExit = Box<dyn FnOnce() + Send>;

/// Whether a child has exited, known as soon as the kernel knows.
#[derive(Default)]
pub struct Exit {
    state: Mutex<ExitState>,
    changed: Condvar,
}

#[derive(Default)]
struct ExitState {
    exited: bool,
    on_exit: Vec<OnExit>,
}

impl Exit {
    pub fn has_exited(&self) -> bool {
        self.lock().exited
    }

    /// Waits until the child exits.
    pub fn wait(&self) {
        let mut state = self.lock();
        while !state.exited {
            state = self.changed.wait(state).unwrap_or_else(|p| p.into_inner());
        }
    }

    /// Waits until the child exits or `deadline` passes; returns whether it exited.
    pub fn wait_until(&self, deadline: Instant) -> bool {
        let mut state = self.lock();
        while !state.exited {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            state = self
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
        true
    }

    /// Runs `then` once the child has exited: at once if it already has, otherwise on the
    /// waiter's thread when it does. `then` must not block.
    pub fn on_exit(&self, then: impl FnOnce() + Send + 'static) {
        let mut state = self.lock();
        if state.exited {
            drop(state);
            then();
        } else {
            state.on_exit.push(Box::new(then));
        }
    }

    fn exited(&self) {
        let callbacks = {
            let mut state = self.lock();
            state.exited = true;
            std::mem::take(&mut state.on_exit)
        };
        self.changed.notify_all();
        for callback in callbacks {
            callback();
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, ExitState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// A child this process spawned, with its waiter.
#[derive(Debug)]
pub struct WatchedChild {
    child: Child,
    exit: Arc<Exit>,
}

impl std::fmt::Debug for Exit {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Exit")
            .field("exited", &self.has_exited())
            .finish()
    }
}

impl WatchedChild {
    /// Starts the waiter for a child just spawned, before anything could reap it. A child
    /// that cannot be watched is killed and reaped.
    pub fn new(mut child: Child) -> io::Result<Self> {
        let exit = Arc::new(Exit::default());
        let pid = child.id() as libc::id_t;
        let waiting = Arc::clone(&exit);
        let started = std::thread::Builder::new()
            .name(format!("axo-exit-{pid}"))
            .stack_size(64 * 1024)
            .spawn(move || {
                wait_for_exit(pid);
                waiting.exited();
            });
        if let Err(error) = started {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        Ok(Self { child, exit })
    }

    pub fn id(&self) -> u32 {
        self.child.id()
    }

    pub fn exit(&self) -> &Arc<Exit> {
        &self.exit
    }

    /// Reaps the child if it has exited. Before its waiter has seen the exit this says it is
    /// still running, so the pid stays the child's until the waiter is done with it.
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        if !self.exit.has_exited() {
            return Ok(None);
        }
        self.child.try_wait()
    }

    /// Waits for the child to exit and reaps it.
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        self.exit.wait();
        self.child.wait()
    }

    pub fn kill(&mut self) -> io::Result<()> {
        self.child.kill()
    }
}

/// Blocks until `pid` has exited, leaving it unreaped. Returns at once if it is not this
/// process's child any more (it was reaped), which only `try_wait` above can do, after this.
fn wait_for_exit(pid: libc::id_t) {
    loop {
        // SAFETY: waitid writes into `info`; P_PID names one child; WNOWAIT leaves it unreaped.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result =
            unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) };
        if result == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    fn spawn(script: &str) -> WatchedChild {
        WatchedChild::new(
            Command::new("/bin/sh")
                .arg("-c")
                .arg(script)
                .spawn()
                .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn an_exit_is_known_the_moment_it_happens_and_the_child_is_left_to_reap() {
        let mut child = spawn("exit 7");
        let started = Instant::now();
        assert!(child.exit().wait_until(started + Duration::from_secs(5)));
        assert_eq!(child.try_wait().unwrap().unwrap().code(), Some(7));
    }

    #[test]
    fn a_running_child_is_not_reaped_and_its_exit_runs_what_waits_for_it() {
        let mut child = spawn("sleep 30");
        let told = Arc::new(AtomicBool::new(false));
        let telling = Arc::clone(&told);
        child
            .exit()
            .on_exit(move || telling.store(true, Ordering::SeqCst));
        assert!(
            !child
                .exit()
                .wait_until(Instant::now() + Duration::from_millis(50))
        );
        assert!(child.try_wait().unwrap().is_none());
        child.kill().unwrap();
        assert!(
            child
                .exit()
                .wait_until(Instant::now() + Duration::from_secs(5))
        );
        // Callbacks run just after the exit is known, on the waiter's thread.
        let deadline = Instant::now() + Duration::from_secs(5);
        while !told.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "the callback never ran");
            std::thread::yield_now();
        }
        assert!(child.try_wait().unwrap().is_some());
        // Told at once when it had already exited.
        let late = Arc::new(AtomicBool::new(false));
        let telling = Arc::clone(&late);
        child
            .exit()
            .on_exit(move || telling.store(true, Ordering::SeqCst));
        assert!(late.load(Ordering::SeqCst));
    }
}
