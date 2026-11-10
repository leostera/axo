//! The lifeline (RFD0041): a pipe whose write end only axod holds. Every Pi axod starts inherits
//! the read end and exits when it reads end of file, which the kernel delivers however axod ends,
//! `kill -9` included. So no Pi outlives the axod that started it.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// The environment variable that tells Pi which descriptor its lifeline is.
pub const LIFELINE_FD: &str = "AXO_LIFELINE_FD";

#[derive(Debug)]
pub struct Lifeline {
    /// Inherited by each Pi; close-on-exec here, so only launches that ask for it pass it on.
    read: OwnedFd,
    /// Never written; closing it (axod ending) is the message.
    _write: OwnedFd,
}

impl Lifeline {
    pub fn new() -> io::Result<Self> {
        let mut ends = [0; 2];
        // SAFETY: `ends` is writable storage for the two descriptors pipe returns.
        if unsafe { libc::pipe(ends.as_mut_ptr()) } == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: pipe returned two new descriptors, owned from here on.
        let (read, write) =
            unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
        axo_pty::process::set_cloexec(read.as_raw_fd())?;
        axo_pty::process::set_cloexec(write.as_raw_fd())?;
        Ok(Self {
            read,
            _write: write,
        })
    }

    /// The descriptor a Pi inherits, at the same number.
    pub fn reader(&self) -> RawFd {
        self.read.as_raw_fd()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::process::{Command, Stdio};

    #[test]
    fn a_child_reading_the_lifeline_sees_its_end_when_the_lifeline_is_dropped() {
        let lifeline = Lifeline::new().unwrap();
        let fd = lifeline.reader();
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(format!("cat <&{fd} >/dev/null; echo ended"))
            .stdout(Stdio::piped());
        // SAFETY: the closure only clears close-on-exec on one open descriptor.
        unsafe {
            std::os::unix::process::CommandExt::pre_exec(&mut command, move || {
                if libc::fcntl(fd, libc::F_SETFD, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = command.spawn().unwrap();
        drop(lifeline);
        let mut output = String::new();
        child
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut output)
            .unwrap();
        assert_eq!(output.trim(), "ended");
        assert!(child.wait().unwrap().success());
    }
}
