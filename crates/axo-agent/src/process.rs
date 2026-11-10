//! Naming a process across axod's lifetimes (RFD0041): its pid and when it started, so a pid the
//! system has since given to another program is never mistaken for the Pi that had it.

use std::io;

/// A process, as of when it started.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProcessIdentity {
    pub pid: u32,
    /// Start time in microseconds since the epoch, as the kernel has it.
    pub started: u64,
}

impl ProcessIdentity {
    /// The running process `pid`, or `None` if there is none.
    pub fn of(pid: u32) -> Option<Self> {
        start_time(pid).map(|started| Self { pid, started })
    }

    /// Whether this exact process is still running.
    pub fn is_running(self) -> bool {
        start_time(self.pid) == Some(self.started)
    }

    /// Kills this process and its process group if it is still this process; `false` when it
    /// had already gone (or its pid is another program's now).
    pub fn kill(self) -> bool {
        if !self.is_running() {
            return false;
        }
        let pid = self.pid as libc::pid_t;
        // SAFETY: signals the verified process first (a leader that has moved groups), then the
        // group it leads, as a PTY session leader does.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
            libc::kill(-pid, libc::SIGKILL);
        }
        true
    }

    /// `pid:started`, as it is stored.
    pub fn to_stored(self) -> String {
        format!("{}:{}", self.pid, self.started)
    }

    pub fn parse(stored: &str) -> io::Result<Self> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidData, "stored process is malformed");
        let (pid, started) = stored.split_once(':').ok_or_else(invalid)?;
        Ok(Self {
            pid: pid.parse().map_err(|_| invalid())?,
            started: started.parse().map_err(|_| invalid())?,
        })
    }
}

#[cfg(target_vendor = "apple")]
fn start_time(pid: u32) -> Option<u64> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is writable for `size` bytes.
    let filled = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (filled == size).then(|| info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}

#[cfg(not(target_vendor = "apple"))]
fn start_time(_pid: u32) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_process_is_named_by_its_pid_and_start_and_killed_only_while_it_is_that_process() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let identity = ProcessIdentity::of(child.id()).unwrap();
        assert!(identity.is_running());
        assert_eq!(
            ProcessIdentity::parse(&identity.to_stored()).unwrap(),
            identity
        );
        let someone_else = ProcessIdentity {
            started: identity.started + 1,
            ..identity
        };
        assert!(!someone_else.kill(), "another start is another process");
        assert!(identity.kill());
        assert!(!child.wait().unwrap().success());
        assert!(!identity.is_running());
        assert!(ProcessIdentity::parse("nope").is_err());
    }
}
