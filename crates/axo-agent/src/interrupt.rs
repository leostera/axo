//! Waits that can be called off without looking again every few milliseconds (RFD0037).
//!
//! Work such as a Pi takeover may stop being wanted at any moment: its pane closes, or a newer
//! recovery replaces it. That is a question (`check`), and the answer can only change when
//! something happens, which a descriptor (`wake`) says: it turns readable each time. A waiter
//! sleeps on what it waits for and on `wake` together, until its deadline, and asks `check` only
//! when woken. So cancellation is seen at once and an idle wait costs nothing.

use std::io::{self, Read};
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::time::Instant;

/// What can call off a wait.
pub struct Interrupt<'a> {
    check: &'a dyn Fn() -> io::Result<()>,
    wake: Option<BorrowedFd<'a>>,
}

impl<'a> Interrupt<'a> {
    /// `check` fails (with `Interrupted`, usually) once the work is no longer wanted; `wake`
    /// turns readable whenever its answer may have changed. The waiter drains `wake`.
    pub fn new(check: &'a dyn Fn() -> io::Result<()>, wake: Option<BorrowedFd<'a>>) -> Self {
        Self { check, wake }
    }

    /// For work nothing calls off.
    pub fn never() -> Interrupt<'static> {
        Interrupt {
            check: &|| Ok(()),
            wake: None,
        }
    }

    pub fn check(&self) -> io::Result<()> {
        (self.check)()
    }

    /// Waits until one of `waiting` (descriptor, `poll` events) is ready, and returns each one's
    /// `revents`; fails with `check`'s error once the work is called off, or with `TimedOut`
    /// (saying `what`) at `deadline`. `None` waits for as long as it takes.
    pub fn wait(
        &self,
        waiting: &[(RawFd, libc::c_short)],
        deadline: Option<Instant>,
        what: &str,
    ) -> io::Result<Vec<libc::c_short>> {
        let mut wake = self.wake.map(|fd| fd.as_raw_fd());
        loop {
            self.check()?;
            let timeout = match deadline {
                None => -1,
                Some(deadline) => {
                    let left = deadline.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Err(io::Error::new(io::ErrorKind::TimedOut, what.to_owned()));
                    }
                    // Rounded up, so the wait never ends just before its deadline.
                    left.as_micros()
                        .div_ceil(1000)
                        .min(libc::c_int::MAX as u128) as libc::c_int
                }
            };
            let mut descriptors: Vec<libc::pollfd> = waiting
                .iter()
                .map(|&(fd, events)| libc::pollfd {
                    fd,
                    events,
                    revents: 0,
                })
                .collect();
            descriptors.push(libc::pollfd {
                // A descriptor of -1 is ignored.
                fd: wake.unwrap_or(-1),
                events: libc::POLLIN,
                revents: 0,
            });
            // SAFETY: poll reads and writes `descriptors`, all initialized, for the call only.
            let ready = unsafe {
                libc::poll(
                    descriptors.as_mut_ptr(),
                    descriptors.len() as libc::nfds_t,
                    timeout,
                )
            };
            if ready == -1 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            let woken = descriptors.pop().map_or(0, |wake| wake.revents);
            if descriptors.iter().any(|descriptor| descriptor.revents != 0) {
                return Ok(descriptors.iter().map(|d| d.revents).collect());
            }
            if woken != 0 && !drain(wake.unwrap_or(-1)) {
                // Its writer has gone: nothing will wake this wait again but its deadline.
                wake = None;
            }
        }
    }
}

/// Reads what is waiting on `fd` without blocking; false once its writer has gone.
fn drain(fd: RawFd) -> bool {
    // SAFETY: the stream is only borrowed for these reads and never closes `fd` (forgotten).
    let mut stream = std::mem::ManuallyDrop::new(unsafe { UnixStream::from_raw_fd(fd) });
    let mut bytes = [0_u8; 64];
    loop {
        let mut readable = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one initialized pollfd; a zero timeout never blocks.
        if unsafe { libc::poll(&mut readable, 1, 0) } <= 0 {
            return true;
        }
        match stream.read(&mut bytes) {
            Ok(0) => return false,
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return true,
        }
    }
}

/// A wake a waiter can sleep on: writing to `Waker` makes `fd` readable.
pub fn wake_pair() -> io::Result<(Waker, UnixStream)> {
    let (writer, reader) = UnixStream::pair()?;
    writer.set_nonblocking(true)?;
    reader.set_nonblocking(true)?;
    Ok((Waker(writer), reader))
}

/// Wakes whoever sleeps on the other end of a [`wake_pair`]. Never blocks.
#[derive(Debug)]
pub struct Waker(UnixStream);

impl Waker {
    pub fn wake(&self) {
        // A full buffer already wakes the reader.
        let _ = io::Write::write(&mut &self.0, &[1]);
    }

    pub fn try_clone(&self) -> io::Result<Self> {
        self.0.try_clone().map(Self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsFd;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    #[test]
    fn a_wait_ends_when_what_it_waits_for_is_ready() {
        let (waiting, mut ready) = UnixStream::pair().unwrap();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            io::Write::write_all(&mut ready, b"x").unwrap();
        });
        let revents = Interrupt::never()
            .wait(
                &[(waiting.as_raw_fd(), libc::POLLIN)],
                Some(Instant::now() + Duration::from_secs(5)),
                "never",
            )
            .unwrap();
        assert_ne!(revents[0] & libc::POLLIN, 0);
    }

    #[test]
    fn a_called_off_wait_ends_when_woken_however_far_its_deadline() {
        let (waiting, _quiet) = UnixStream::pair().unwrap();
        let (waker, wake) = wake_pair().unwrap();
        let called_off = Arc::new(AtomicBool::new(false));
        let calling = Arc::clone(&called_off);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            calling.store(true, Ordering::SeqCst);
            waker.wake();
        });
        let check = || {
            if called_off.load(Ordering::SeqCst) {
                Err(io::Error::from(io::ErrorKind::Interrupted))
            } else {
                Ok(())
            }
        };
        let started = Instant::now();
        let error = Interrupt::new(&check, Some(wake.as_fd()))
            .wait(
                &[(waiting.as_raw_fd(), libc::POLLIN)],
                Some(Instant::now() + Duration::from_secs(60)),
                "never",
            )
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_wake_that_changes_nothing_only_costs_one_look() {
        let (waiting, _quiet) = UnixStream::pair().unwrap();
        let (waker, wake) = wake_pair().unwrap();
        waker.wake();
        waker.wake();
        drop(waker);
        let looks = std::sync::atomic::AtomicUsize::new(0);
        let check = || {
            looks.fetch_add(1, Ordering::SeqCst);
            Ok(())
        };
        let error = Interrupt::new(&check, Some(wake.as_fd()))
            .wait(
                &[(waiting.as_raw_fd(), libc::POLLIN)],
                Some(Instant::now() + Duration::from_millis(100)),
                "the quiet end",
            )
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert_eq!(error.to_string(), "the quiet end");
        // The first look, one after the wakes (and its writer going), one at the deadline.
        assert!(looks.load(Ordering::SeqCst) <= 3, "{looks:?}");
    }
}
