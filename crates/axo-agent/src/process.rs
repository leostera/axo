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
        bsd_info(pid).map(|info| Self {
            pid,
            started: info.started,
        })
    }

    /// This process's parent now, while this is still this process. An orphan's is launchd's.
    pub fn parent(self) -> Option<Self> {
        let info = bsd_info(self.pid).filter(|info| info.started == self.started)?;
        Self::of(info.parent)
    }

    /// Whether this exact process is still running.
    pub fn is_running(self) -> bool {
        bsd_info(self.pid).is_some_and(|info| info.started == self.started)
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

/// What the kernel says of a running process: when it started, in microseconds since the
/// epoch, and its parent's pid.
struct BsdInfo {
    started: u64,
    parent: u32,
}

#[cfg(target_vendor = "apple")]
fn bsd_info(pid: u32) -> Option<BsdInfo> {
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
    (filled == size).then(|| BsdInfo {
        started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
        parent: info.pbi_ppid,
    })
}

#[cfg(target_os = "linux")]
fn bsd_info(pid: u32) -> Option<BsdInfo> {
    linux::info(pid)
}

#[cfg(target_os = "linux")]
mod linux {
    use std::sync::OnceLock;

    use super::BsdInfo;

    pub(super) fn info(pid: u32) -> Option<BsdInfo> {
        static BOOT_SECONDS: OnceLock<Option<u64>> = OnceLock::new();
        let boot = (*BOOT_SECONDS.get_or_init(|| {
            std::fs::read_to_string("/proc/stat")
                .ok()?
                .lines()
                .find_map(|line| line.strip_prefix("btime "))?
                .parse::<u64>()
                .ok()
        }))?;
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (parent, started) = fields(&stat)?;
        // SAFETY: sysconf takes no pointers; non-positive results are rejected.
        let ticks = u64::try_from(unsafe { libc::sysconf(libc::_SC_CLK_TCK) }).ok()?;
        let started = boot
            .checked_mul(1_000_000)?
            .checked_add(started.checked_mul(1_000_000)?.checked_div(ticks)?)?;
        Some(BsdInfo { started, parent })
    }

    /// The parent's pid (field 4) and the start time in clock ticks (field 22).
    fn fields(stat: &str) -> Option<(u32, u64)> {
        // comm (field 2) may contain spaces and parentheses: fields count from after it.
        let after = stat.rsplit_once(") ")?.1;
        let mut fields = after.split_whitespace();
        let parent = fields.nth(1)?.parse().ok()?;
        let started = fields.nth(17)?.parse().ok()?;
        Some((parent, started))
    }

    #[cfg(test)]
    mod tests {
        #[test]
        fn command_names_cannot_shift_the_parent_or_start_time_fields() {
            let mut fields = vec!["S", "7"];
            fields.extend(std::iter::repeat_n("0", 17));
            fields.push("1234");
            let stat = format!("42 (name with ) parentheses) {}", fields.join(" "));
            assert_eq!(super::fields(&stat), Some((7, 1234)));
            assert_eq!(super::fields("42 (truncated) S"), None);
            assert_eq!(super::fields("invalid"), None);
        }
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
fn bsd_info(_pid: u32) -> Option<BsdInfo> {
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

    #[test]
    fn a_process_knows_its_parent_only_while_it_is_that_process() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let identity = ProcessIdentity::of(child.id()).unwrap();
        assert_eq!(
            identity.parent(),
            ProcessIdentity::of(std::process::id()),
            "the test started it"
        );
        let someone_else = ProcessIdentity {
            started: identity.started + 1,
            ..identity
        };
        assert_eq!(someone_else.parent(), None);
        identity.kill();
        child.wait().unwrap();
        assert_eq!(
            identity.parent(),
            None,
            "a process that has gone has no parent"
        );
    }
}
