//! A child and the task that hears it exit (RFD0037, "Child processes").
//!
//! Each child's watch is a task on axo-pty's runtime, woken by tokio's SIGCHLD stream. On each
//! wake it asks `waitid(WEXITED | WNOHANG | WNOWAIT)` whether its own child has exited, which
//! leaves the child unreaped. Reaping stays with the owner, through `try_wait`, which reaps only
//! once the watch has seen the exit. So a pid is never reaped, and so never reused, while the
//! watch or anything signalling the child or its process group could still name it. That is
//! why this is not `tokio::process`: it reaps as soon as it hears.

use std::io;
use std::process::{Child, ExitStatus};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

/// What happens when a child exits: callbacks run on axo-pty's runtime, so they must not block.
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

    /// Runs `then` once the child has exited: at once if it already has, otherwise on axo-pty's
    /// runtime when it does. `then` must not block.
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

/// A child this process spawned, with its watch.
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
    /// Starts the watch for a child just spawned, before anything could reap it. A child
    /// that cannot be watched is killed and reaped.
    pub fn new(mut child: Child) -> io::Result<Self> {
        let exit = Arc::new(Exit::default());
        let pid = child.id() as libc::id_t;
        if let Err(error) = watch(pid, Arc::clone(&exit)) {
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

    /// Reaps the child if it has exited. Before its watch has seen the exit this says it is
    /// still running, so the pid stays the child's until the watch is done with it.
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

/// Watches `pid` from axo-pty's runtime and marks `exit` once it has exited.
fn watch(pid: libc::id_t, exit: Arc<Exit>) -> io::Result<()> {
    let runtime = crate::runtime::shared()?;
    let _inside = runtime.enter();
    // Listening before the first look: an exit after that look still sends a SIGCHLD it hears.
    let mut children = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child())?;
    runtime.spawn(async move {
        while !has_exited(pid) {
            // Any child's exit wakes every watch; each asks only about its own.
            if children.recv().await.is_none() {
                // The runtime is shutting down with the process.
                return;
            }
        }
        exit.exited();
    });
    Ok(())
}

/// Whether `pid` has exited, without reaping it or waiting. True too if it is no longer this
/// process's child (it was reaped), which only `try_wait` above can do, after this.
fn has_exited(pid: libc::id_t) -> bool {
    loop {
        // SAFETY: waitid writes into `info`; P_PID names one child; WNOWAIT leaves it unreaped
        // and WNOHANG returns at once, with `info` still zeroed while the child runs.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return info.si_pid != 0;
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return true;
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
        // Callbacks run just after the exit is known, on axo-pty's runtime.
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

    /// A hundred running children must not cost a hundred threads: watches are tasks.
    #[test]
    fn watching_children_costs_no_thread_each() {
        let _ = crate::runtime::shared().unwrap();
        let before = crate::runtime::thread_count();
        let mut children: Vec<_> = (0..64).map(|_| spawn("sleep 30")).collect();
        let after = crate::runtime::thread_count();
        // Other tests run beside this one and start threads of their own; 64 watches as
        // threads would add 64.
        assert!(after - before < 16, "{before} threads, then {after}");
        for child in &mut children {
            child.kill().unwrap();
        }
        for child in &mut children {
            assert!(
                child
                    .exit()
                    .wait_until(Instant::now() + Duration::from_secs(10)),
                "every exit is heard, however many share one signal"
            );
            assert!(child.try_wait().unwrap().is_some());
        }
    }

    /// One child's exit wakes every watch; the others stay running and unreaped.
    #[test]
    fn another_childs_exit_is_not_this_ones() {
        let mut running = spawn("sleep 30");
        let mut exiting = spawn("exit 0");
        assert!(
            exiting
                .exit()
                .wait_until(Instant::now() + Duration::from_secs(5))
        );
        assert!(exiting.try_wait().unwrap().is_some());
        assert!(!running.exit().has_exited());
        assert!(running.try_wait().unwrap().is_none());
        running.kill().unwrap();
        assert!(running.wait().is_ok());
    }
}
