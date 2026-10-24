//! Launching programs on a pseudo-terminal, resizing them, writing their input, and stopping
//! them.
//!
//! Invariants:
//! - A spawned child is a session leader whose controlling terminal is its PTY, with the PTY on
//!   stdin/stdout/stderr. Its process group therefore receives job-control signals.
//! - Every descriptor Axod creates is close-on-exec; a child inherits only its PTY and the
//!   descriptors listed in `SpawnOptions::inherit`.
//! - Output is drained from the moment of spawn by the process's `TerminalOutput` pump.

use std::ffi::CStr;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crate::output::TerminalOutput;

/// A terminal size in character cells. Both dimensions are at least one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowSize {
    rows: u16,
    columns: u16,
}

impl WindowSize {
    /// The size a PTY starts with until a client reports its own.
    pub const DEFAULT: WindowSize = WindowSize {
        rows: 24,
        columns: 80,
    };

    /// Parses client-supplied dimensions; `None` if either is zero or exceeds `u16::MAX`.
    pub fn new(rows: u32, columns: u32) -> Option<WindowSize> {
        let rows = u16::try_from(rows).ok().filter(|rows| *rows > 0)?;
        let columns = u16::try_from(columns).ok().filter(|columns| *columns > 0)?;
        Some(WindowSize { rows, columns })
    }

    pub fn rows(self) -> u16 {
        self.rows
    }

    pub fn columns(self) -> u16 {
        self.columns
    }

    fn to_winsize(self) -> libc::winsize {
        libc::winsize {
            ws_row: self.rows,
            ws_col: self.columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        }
    }
}

/// A running child on its own PTY.
#[derive(Debug)]
pub struct PtyProcess {
    pub child: Child,
    /// Shared with attached clients for input, resizing and termios queries; only the output
    /// pump reads it.
    pub master: OwnedFd,
    /// The slave device path, e.g. `/dev/ttys004`.
    pub device: String,
    pub output: Arc<TerminalOutput>,
}

/// Starts `command` on a new PTY of `size`. `inherit` lists descriptors the child keeps across
/// exec (they stay close-on-exec in this process, so concurrent launches never leak them).
pub fn spawn(mut command: Command, size: WindowSize, inherit: &[RawFd]) -> io::Result<PtyProcess> {
    let (master, slave) = open_pty(size)?;
    let device = device_path(slave.as_raw_fd())?;
    let slave_fd = slave.as_raw_fd();
    let inherit = inherit.to_vec();
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: the closure runs in the forked child before exec and only makes async-signal-safe
    // calls: it creates a session, makes the PTY its controlling terminal and foreground group,
    // connects the standard streams, and clears close-on-exec on the inherited descriptors.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1
                || libc::ioctl(slave_fd, libc::TIOCSCTTY as libc::c_ulong, 0) == -1
                || libc::tcsetpgrp(slave_fd, libc::getpgrp()) == -1
            {
                return Err(io::Error::last_os_error());
            }
            for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
                if libc::dup2(slave_fd, target) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            libc::close(slave_fd);
            for descriptor in &inherit {
                if libc::fcntl(*descriptor, libc::F_SETFD, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    drop(slave);
    match TerminalOutput::start(&master) {
        Ok(output) => Ok(PtyProcess {
            child,
            master,
            device,
            output,
        }),
        Err(error) => {
            // It never started serving; no reason to wait long.
            stop(&mut child, SHELL_STOP_GRACE);
            Err(error)
        }
    }
}

fn open_pty(size: WindowSize) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut master_fd: RawFd = -1;
    let mut slave_fd: RawFd = -1;
    let mut size = size.to_winsize();
    // SAFETY: openpty initializes both descriptors and reads a valid winsize.
    let opened = unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    if opened == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty returned two new descriptors owned from here on.
    let (master, slave) = unsafe {
        (
            OwnedFd::from_raw_fd(master_fd),
            OwnedFd::from_raw_fd(slave_fd),
        )
    };
    set_cloexec(master.as_raw_fd())?;
    set_cloexec(slave.as_raw_fd())?;
    Ok((master, slave))
}

/// Applies `size` to the PTY and tells the child. The kernel signals the foreground group; the
/// direct SIGWINCH also reaches a shell that moved itself to another group.
pub fn resize(master: &OwnedFd, child: &Child, size: WindowSize) -> io::Result<()> {
    let size = size.to_winsize();
    // SAFETY: size is initialized and the master descriptor is open.
    if unsafe {
        libc::ioctl(
            master.as_raw_fd(),
            libc::TIOCSWINSZ,
            &size as *const libc::winsize,
        )
    } == -1
    {
        return Err(io::Error::last_os_error());
    }
    signal(child, libc::SIGWINCH);
    Ok(())
}

/// The PTY's current size.
pub fn window_size(master: &OwnedFd) -> io::Result<WindowSize> {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: size is writable and the master descriptor is open.
    if unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCGWINSZ, &mut size) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(WindowSize {
        rows: size.ws_row,
        columns: size.ws_col,
    })
}

/// Resizes only when the size differs, so an unchanged layout never interrupts the program
/// with a SIGWINCH. Returns whether it resized.
pub fn resize_if_changed(master: &OwnedFd, child: &Child, size: WindowSize) -> io::Result<bool> {
    if window_size(master)? == size {
        return Ok(false);
    }
    resize(master, child, size)?;
    Ok(true)
}

pub fn set_cloexec(descriptor: RawFd) -> io::Result<()> {
    // SAFETY: fcntl reads descriptor flags from an open descriptor.
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fcntl updates only the close-on-exec flag on this open descriptor.
    if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn device_path(slave_fd: RawFd) -> io::Result<String> {
    let mut bytes = vec![0_i8; libc::PATH_MAX as usize];
    // SAFETY: bytes is writable storage and slave_fd is an open PTY slave.
    let error = unsafe { libc::ttyname_r(slave_fd, bytes.as_mut_ptr(), bytes.len()) };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    // SAFETY: ttyname_r wrote a NUL-terminated device path into bytes.
    let device = unsafe { CStr::from_ptr(bytes.as_ptr()) };
    device
        .to_str()
        .map(str::to_owned)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "PTY path is not UTF-8"))
}

pub fn stop(child: &mut Child, grace: Duration) {
    stop_all(vec![Stopping { child, grace }]);
}

/// How long a stopped shell gets to exit after SIGHUP/SIGTERM before SIGKILL.
pub const SHELL_STOP_GRACE: Duration = Duration::from_millis(500);

/// How long to wait for the kernel to reap after SIGKILL before reporting a stuck process.
pub const KILL_WAIT: Duration = Duration::from_secs(2);

/// A child to stop, and how long it may take to exit before it is killed.
pub struct Stopping<'a> {
    pub child: &'a mut Child,
    pub grace: Duration,
}

/// Stops every child at once: all are signalled together and waited on together, so stopping
/// N children takes the longest grace among them, not the sum. Each is killed when its own
/// grace runs out.
///
/// SIGHUP is what a closing terminal sends: interactive shells ignore SIGTERM but exit on SIGHUP
/// and forward it to their jobs. SIGTERM covers non-shell agents. Survivors get SIGKILL.
pub fn stop_all(children: Vec<Stopping<'_>>) {
    let started = Instant::now();
    let mut pending: Vec<Pending<'_>> = Vec::with_capacity(children.len());
    for Stopping { child, grace } in children {
        match child.try_wait() {
            Ok(Some(_)) => {}
            Ok(None) => {
                log::info!("event=session.shell_stop_started pid={}", child.id());
                signal(child, libc::SIGHUP);
                signal(child, libc::SIGTERM);
                pending.push(Pending {
                    child,
                    deadline: started + grace,
                    killed: false,
                });
            }
            Err(error) => log::error!(
                "event=session.shell_stop_unconfirmed pid={} phase=before_signal error_kind={:?}",
                child.id(),
                error.kind()
            ),
        }
    }
    while !pending.is_empty() {
        let now = Instant::now();
        pending.retain_mut(|stopping| stopping.advance(now));
        if !pending.is_empty() {
            thread::sleep(Duration::from_millis(10));
        }
    }
}

/// One child on its way out: terminated until `deadline`, then killed until a new deadline.
struct Pending<'a> {
    child: &'a mut Child,
    deadline: Instant,
    killed: bool,
}

impl Pending<'_> {
    /// Returns whether the child still needs waiting on.
    fn advance(&mut self, now: Instant) -> bool {
        let phase = if self.killed {
            "kill_wait"
        } else {
            "term_wait"
        };
        match self.child.try_wait() {
            Ok(Some(_)) => {
                log::info!("event=session.shell_stopped pid={}", self.child.id());
                return false;
            }
            Ok(None) => {}
            Err(error) => {
                log::error!(
                    "event=session.shell_stop_unconfirmed pid={} phase={phase} error_kind={:?}",
                    self.child.id(),
                    error.kind()
                );
                return false;
            }
        }
        if now < self.deadline {
            return true;
        }
        if self.killed {
            log::error!("event=session.shell_stop_timed_out pid={}", self.child.id());
            return false;
        }
        signal(self.child, libc::SIGKILL);
        self.killed = true;
        self.deadline = now + KILL_WAIT;
        true
    }
}

/// Signals the child's process group (its foreground jobs) and the child itself (a shell that
/// moved to another group for job control).
pub fn signal(child: &Child, signal: libc::c_int) {
    let process_id = child.id() as libc::pid_t;
    // SAFETY: the pid comes from a child this manager spawned and has not yet reaped.
    unsafe {
        libc::kill(-process_id, signal);
        libc::kill(process_id, signal);
    }
}

pub fn write_all(fd: RawFd, mut bytes: &[u8], timeout: Duration) -> io::Result<()> {
    while !bytes.is_empty() {
        // SAFETY: bytes points to initialized memory and fd remains open for this call.
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written == -1 {
            let error = io::Error::last_os_error();
            match error.kind() {
                io::ErrorKind::Interrupted => continue,
                // An attached client may have set O_NONBLOCK on the shared PTY file description.
                io::ErrorKind::WouldBlock => {
                    wait_writable(fd, timeout)?;
                    continue;
                }
                _ => return Err(error),
            }
        }
        if written == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "terminal input write returned zero",
            ));
        }
        bytes = &bytes[written as usize..];
    }
    Ok(())
}

fn wait_writable(fd: RawFd, timeout: Duration) -> io::Result<()> {
    let mut descriptor = libc::pollfd {
        fd,
        events: libc::POLLOUT,
        revents: 0,
    };
    let timeout_millis = timeout.as_millis().clamp(1, libc::c_int::MAX as u128) as libc::c_int;
    // SAFETY: descriptor points to one initialized pollfd for a live descriptor.
    match unsafe { libc::poll(&mut descriptor, 1, timeout_millis) } {
        -1 => Err(io::Error::last_os_error()),
        0 => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "terminal is not accepting input",
        )),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A child in its own process group (like a PTY shell) running `script` under `sh`.
    fn spawn_group_leader(script: &str) -> Child {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", script]).process_group(0);
        let child = command.spawn().unwrap();
        // Give sh time to install its traps before it is signalled.
        thread::sleep(Duration::from_millis(100));
        child
    }

    #[test]
    fn shells_that_ignore_sigterm_stop_on_sighup_without_waiting_for_sigkill() {
        // Interactive shells ignore SIGTERM; a terminal closing sends SIGHUP.
        let mut child = spawn_group_leader("trap '' TERM; while :; do sleep 1; done");
        let started = Instant::now();
        stop(&mut child, SHELL_STOP_GRACE);
        assert!(child.try_wait().unwrap().is_some());
        assert!(
            started.elapsed() < SHELL_STOP_GRACE,
            "took {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn stopping_many_stubborn_shells_costs_one_grace_period() {
        let mut children: Vec<Child> = (0..6)
            .map(|_| spawn_group_leader("trap '' HUP TERM; while :; do sleep 1; done"))
            .collect();
        let started = Instant::now();
        stop_all(
            children
                .iter_mut()
                .map(|child| Stopping {
                    child,
                    grace: SHELL_STOP_GRACE,
                })
                .collect(),
        );
        let elapsed = started.elapsed();
        for child in &mut children {
            assert!(child.try_wait().unwrap().is_some());
        }
        // Sequential stops would take 6 × 500 ms.
        assert!(
            elapsed >= SHELL_STOP_GRACE && elapsed < SHELL_STOP_GRACE * 2,
            "took {elapsed:?}"
        );
    }

    #[test]
    fn each_child_is_killed_when_its_own_grace_runs_out() {
        let short = Duration::from_millis(200);
        let long = Duration::from_millis(1_000);
        let mut stubborn = spawn_group_leader("trap '' HUP TERM; while :; do sleep 1; done");
        // Exits on SIGTERM only after cleaning up for a while, like Pi saving its state. It
        // reports when its trap is installed, so the signal cannot beat it under load.
        let ready = std::env::temp_dir().join(format!("axo-stop-ready-{}", std::process::id()));
        let _ = std::fs::remove_file(&ready);
        let mut slow = spawn_group_leader(&format!(
            "trap 'sleep 0.5; exit 0' HUP TERM; : > '{}'; while :; do sleep 0.05; done",
            ready.display()
        ));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ready.exists() {
            assert!(
                Instant::now() < deadline,
                "the slow child never installed its trap"
            );
            thread::sleep(Duration::from_millis(10));
        }
        let _ = std::fs::remove_file(&ready);
        let started = Instant::now();
        stop_all(vec![
            Stopping {
                child: &mut stubborn,
                grace: short,
            },
            Stopping {
                child: &mut slow,
                grace: long,
            },
        ]);
        let elapsed = started.elapsed();
        assert!(elapsed < long, "took {elapsed:?}");
        assert!(stubborn.try_wait().unwrap().is_some());
        // Past the stubborn child's grace, yet not killed: it had its own, longer one.
        assert_eq!(
            slow.try_wait().unwrap().unwrap().code(),
            Some(0),
            "the slow child finished cleaning up"
        );
    }

    #[test]
    fn window_sizes_reject_zero_and_overflowing_dimensions() {
        assert_eq!(
            WindowSize::new(24, 80).map(|size| (size.rows(), size.columns())),
            Some((24, 80))
        );
        assert_eq!(WindowSize::new(0, 80), None);
        assert_eq!(WindowSize::new(24, 0), None);
        assert_eq!(WindowSize::new(65_536, 80), None);
        assert!(WindowSize::new(65_535, 65_535).is_some());
    }

    #[test]
    fn spawned_children_run_on_their_pty_as_session_leaders() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "tty; echo leader=$(ps -o sess= -p $$ | tr -d ' ')"]);
        let process = spawn(command, WindowSize::DEFAULT, &[]).unwrap();
        let (replay, subscriber) = process.output.subscribe(None);
        let mut seen = replay;
        let deadline = Instant::now() + Duration::from_secs(5);
        while !String::from_utf8_lossy(&seen).contains(&process.device) && Instant::now() < deadline
        {
            if let crate::output::NextOutput::Chunks(chunks) =
                subscriber.next(Duration::from_millis(100))
            {
                chunks
                    .iter()
                    .for_each(|chunk| seen.extend_from_slice(chunk));
            }
        }
        assert!(
            String::from_utf8_lossy(&seen).contains(&process.device),
            "{}",
            String::from_utf8_lossy(&seen)
        );
        let mut child = process.child;
        stop(&mut child, SHELL_STOP_GRACE);
    }
}
