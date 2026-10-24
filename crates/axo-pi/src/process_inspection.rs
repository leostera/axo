//! Bounded, cancellation-aware execution of Axod's metadata inspection tools.
//! This is not a general-purpose shell or a supervisor for arbitrary daemons.

use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const POLL_INTERVAL: Duration = Duration::from_millis(25);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
pub(crate) const MAX_INSPECTION_OUTPUT_BYTES: usize = 16 * 1024;

// Remain the exclusive waiter. In particular, do not reap a leader while its
// descendants retain stdout: cleanup still needs the unreused process-group ID.
struct InspectionChild {
    child: Child,
    owns_wait: bool,
}

impl InspectionChild {
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        let result = self.child.try_wait();
        if let Err(error) = &result {
            log::error!(
                "event=session.pi_inspection_cleanup_unconfirmed pid={} phase=wait error_kind={:?}",
                self.child.id(),
                error.kind()
            );
        }
        if !matches!(result, Ok(None)) {
            self.owns_wait = false;
        }
        result
    }

    fn confirm_wait_ownership(&self) -> io::Result<()> {
        // SAFETY: waitid receives initialized writable storage and probes only
        // the child we launched. WNOWAIT preserves its PID until explicit reap.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let deadline = Instant::now() + POLL_INTERVAL;
        loop {
            // SAFETY: P_PID selects this owned child; WNOHANG never waits for exit.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.child.id() as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result == 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted || Instant::now() >= deadline {
                return Err(error);
            }
        }
    }
}

impl Drop for InspectionChild {
    fn drop(&mut self) {
        if !self.owns_wait {
            return;
        }
        if let Err(error) = self.confirm_wait_ownership() {
            log::error!(
                "event=session.pi_inspection_cleanup_unconfirmed pid={} phase=ownership error_kind={:?}",
                self.child.id(),
                error.kind()
            );
            return; // Lost wait ownership is not permission to signal a reused PID.
        }
        let pid = self.child.id() as libc::pid_t;
        // SAFETY: pre_exec created this child's session/group. The leader is
        // still unreaped, fencing its ID even if it exited before stdout closed.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
        // Also cover the directly owned child; never adopt an inspected Pi PID.
        let _ = self.child.kill();
        let deadline = Instant::now() + CLEANUP_TIMEOUT;
        loop {
            match self.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) if Instant::now() < deadline => thread::sleep(POLL_INTERVAL),
                Err(_) => return, // try_wait already reported lost ownership.
                Ok(None) => {
                    log::error!(
                        "event=session.pi_inspection_cleanup_unconfirmed pid={pid} phase=reap error_kind=TimedOut"
                    );
                    return;
                }
            }
        }
    }
}

fn remaining(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|time| !time.is_zero())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "Pi owner inspection timed out"))
}

/// Capture at most 16 KiB of stdout; discard stderr and never log tool output.
/// All tools in one inspection must receive the same absolute deadline. Error
/// cleanup has its own bounded reap budget; kernel process creation is separate.
pub(crate) fn run(
    command: &mut Command,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<Output> {
    check_current()?;
    remaining(deadline)?;
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // SAFETY: only the child calls this async-signal-safe syscall before exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut process = InspectionChild {
        child: command.spawn()?,
        owns_wait: true,
    };
    let mut stdout = process
        .child
        .stdout
        .take()
        .expect("piped inspection stdout");
    let fd = stdout.as_raw_fd();
    // SAFETY: only the owned pipe's status flags are read/updated here.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    let mut output = Vec::new();
    let mut eof = false;
    loop {
        check_current()?;
        let time = remaining(deadline)?;
        if eof {
            if let Some(status) = process.try_wait()? {
                // Revalidate after the final wait too; partial/stale inspection
                // output must not authorize a subsequent lifecycle action.
                check_current()?;
                remaining(deadline)?;
                return Ok(Output {
                    status,
                    stdout: output,
                    stderr: Vec::new(),
                });
            }
            thread::sleep(time.min(POLL_INTERVAL));
            continue;
        }
        let mut chunk = [0_u8; 4096];
        match stdout.read(&mut chunk) {
            Ok(0) => {
                eof = true;
            }
            Ok(length) => {
                if output.len().saturating_add(length) > MAX_INSPECTION_OUTPUT_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Pi owner inspection output exceeds its limit",
                    ));
                }
                output.extend_from_slice(&chunk[..length]);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut poll = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                // SAFETY: poll receives one live, initialized owned pipe record.
                if unsafe {
                    libc::poll(
                        &mut poll,
                        1,
                        time.min(POLL_INTERVAL).as_millis().max(1) as libc::c_int,
                    )
                } == -1
                {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::Interrupted {
                        return Err(error);
                    }
                }
            }
            Err(error) => return Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc;

    fn shell(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", script])
            .env_remove("ENV")
            .env_remove("BASH_ENV");
        command
    }

    #[test]
    fn captures_only_stdout_and_preserves_exit_status() {
        let output = run(
            &mut shell("printf 'metadata'; printf 'discarded' >&2; exit 7"),
            Instant::now() + Duration::from_secs(2),
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(output.stdout, b"metadata");
        assert!(output.stderr.is_empty());
        assert_eq!(output.status.code(), Some(7));
    }

    #[test]
    fn output_limit_accepts_exact_boundary_and_rejects_floods() {
        let script = format!("printf '%0{}d' 0", MAX_INSPECTION_OUTPUT_BYTES);
        let output = run(
            &mut shell(&script),
            Instant::now() + Duration::from_secs(2),
            &|| Ok(()),
        )
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout.len(), MAX_INSPECTION_OUTPUT_BYTES);
        let error = run(
            &mut shell("while :; do printf '0123456789abcdef'; done"),
            Instant::now() + Duration::from_secs(2),
            &|| Ok(()),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn deadline_covers_hung_children_with_or_without_stdout() {
        for script in ["exec /bin/sleep 60", "exec 1>&-; exec /bin/sleep 60"] {
            let start = Instant::now();
            let error = run(
                &mut shell(script),
                start + Duration::from_millis(150),
                &|| Ok(()),
            )
            .unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::TimedOut);
            assert!(start.elapsed() < Duration::from_secs(1));
        }
    }

    #[test]
    fn cancellation_interrupts_a_running_inspection() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = Arc::clone(&cancelled);
        let (started, ready) = mpsc::sync_channel(1);
        let worker = thread::spawn(move || {
            let checks = AtomicUsize::new(0);
            run(
                &mut shell("exec /bin/sleep 60"),
                Instant::now() + Duration::from_secs(5),
                &|| {
                    if checks.fetch_add(1, Ordering::Relaxed) == 1 {
                        started.send(()).unwrap();
                    }
                    if cancel.load(Ordering::Relaxed) {
                        Err(io::Error::from(io::ErrorKind::Interrupted))
                    } else {
                        Ok(())
                    }
                },
            )
        });
        ready.recv_timeout(Duration::from_secs(2)).unwrap();
        let start = Instant::now();
        cancelled.store(true, Ordering::Relaxed);
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn expired_or_cancelled_inspections_do_not_spawn() {
        let mut invalid = Command::new("/nonexistent/axo-inspection-fixture");
        assert_eq!(
            run(
                &mut invalid,
                Instant::now() - Duration::from_secs(1),
                &|| Ok(())
            )
            .unwrap_err()
            .kind(),
            io::ErrorKind::TimedOut
        );
        assert_eq!(
            run(
                &mut invalid,
                Instant::now() + Duration::from_secs(1),
                &|| Err(io::Error::from(io::ErrorKind::Interrupted))
            )
            .unwrap_err()
            .kind(),
            io::ErrorKind::Interrupted
        );
        assert_eq!(
            run(
                &mut invalid,
                Instant::now() + Duration::from_secs(1),
                &|| Ok(())
            )
            .unwrap_err()
            .kind(),
            io::ErrorKind::NotFound
        );
    }

    #[test]
    fn sequential_tools_share_the_original_deadline() {
        let start = Instant::now();
        let deadline = start + Duration::from_secs(1);
        run(
            &mut shell("/bin/sleep 0.1; printf 'first'"),
            deadline,
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(
            run(&mut shell("exec /bin/sleep 60"), deadline, &|| Ok(()))
                .unwrap_err()
                .kind(),
            io::ErrorKind::TimedOut
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn cleanup_preserves_leader_identity_until_descendant_pipe_holders_are_stopped() {
        let (mut observer, writer) = UnixStream::pair().unwrap();
        observer
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let fd = writer.as_raw_fd();
        let mut command = shell(&format!("/bin/sleep 60 & printf 'ready\\n' >&{fd}; exit 0"));
        // SAFETY: make only this test child's observer descriptor survive exec.
        unsafe {
            command.pre_exec(move || {
                if libc::fcntl(fd, libc::F_SETFD, 0) == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        let worker = thread::spawn(move || {
            let result = run(
                &mut command,
                Instant::now() + Duration::from_secs(1),
                &|| Ok(()),
            );
            drop(writer);
            result
        });
        let mut marker = [0_u8; 6];
        observer.read_exact(&mut marker).unwrap();
        assert_eq!(&marker, b"ready\n");
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        // If cleanup only reaped the exited leader, its background sleep would
        // still hold this descriptor. EOF proves cleanup covered the owned group.
        assert_eq!(observer.read(&mut [0_u8; 1]).unwrap(), 0);
    }

    #[test]
    fn lost_wait_ownership_is_not_permission_to_signal() {
        let mut command = shell("exit 0");
        // SAFETY: the isolated child creates its own process group before exec.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        let mut process = InspectionChild {
            child: command.spawn().unwrap(),
            owns_wait: true,
        };
        let pid = process.child.id() as libc::pid_t;
        // SAFETY: deliberately simulate another waiter reaping this fixture child.
        assert_eq!(unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) }, pid);
        assert_eq!(
            process.confirm_wait_ownership().unwrap_err().raw_os_error(),
            Some(libc::ECHILD)
        );
        assert!(process.try_wait().is_err());
        assert!(!process.owns_wait);
    }
}
