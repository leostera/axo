//! Linux PTYs and descriptor inheritance. Requires Linux 5.11+ for CLOSE_RANGE_CLOEXEC.

use std::ffi::CStr;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

use crate::process::{OpenedPty, WindowSize};

pub(crate) fn open_pty(size: WindowSize) -> io::Result<OpenedPty> {
    // SAFETY: posix_openpt returns a new owned descriptor or -1; flags request atomic CLOEXEC.
    let descriptor = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    if descriptor == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the descriptor was just opened and has no other owner.
    let master = unsafe { OwnedFd::from_raw_fd(descriptor) };
    // SAFETY: both calls operate on our open PTY master.
    if unsafe { libc::grantpt(descriptor) } == -1 || unsafe { libc::unlockpt(descriptor) } == -1 {
        return Err(io::Error::last_os_error());
    }
    let mut name = [0 as libc::c_char; 128];
    // SAFETY: ptsname_r writes at most name.len() bytes into the initialized buffer.
    let error = unsafe { libc::ptsname_r(descriptor, name.as_mut_ptr(), name.len()) };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    // SAFETY: successful ptsname_r NUL-terminated the buffer, which remains alive here.
    let name = unsafe { CStr::from_ptr(name.as_ptr()) };
    let device = name
        .to_str()
        .map_err(|_| io::Error::other("PTY path is not UTF-8"))?
        .to_owned();
    // SAFETY: name is a live NUL-terminated path; open returns an owned descriptor or -1.
    let descriptor = unsafe {
        libc::open(
            name.as_ptr(),
            libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC,
        )
    };
    if descriptor == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: this newly opened descriptor has no other owner.
    let slave = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let size = size.to_winsize();
    // SAFETY: the master is open and size is initialized for TIOCSWINSZ.
    if unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ, &size) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(OpenedPty {
        master,
        slave,
        device,
    })
}

/// Called only in the forked child: mark the entire descriptor range, not a racy snapshot.
/// Fail closed on unsupported kernels rather than leaking daemon sockets into an agent.
pub(crate) fn cloexec_descriptors() -> io::Result<()> {
    // SAFETY: close_range with CLOEXEC changes flags only in this child and takes no pointers.
    let result = unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3u32,
            u32::MAX,
            libc::CLOSE_RANGE_CLOEXEC,
        )
    };
    if result == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
