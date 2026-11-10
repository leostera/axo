//! The runtime axo-pty's tasks run on: every PTY's output pump and every child's exit watch run
//! on the caller's (axod's, RFD0041), so axo-pty never starts threads of its own. A caller with
//! no runtime is refused. Tests, which are plain threads, get one runtime shared by all of them.

use std::io;

/// The runtime to spawn on: the caller's.
pub(crate) fn handle() -> io::Result<tokio::runtime::Handle> {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => Ok(handle),
        #[cfg(test)]
        Err(_) => Ok(shared()?.handle().clone()),
        #[cfg(not(test))]
        Err(_) => Err(io::Error::other(
            "axo-pty runs its tasks on the caller's tokio runtime, and there is none",
        )),
    }
}

/// The runtime tests that are not inside one spawn on.
#[cfg(test)]
pub(crate) fn shared() -> io::Result<&'static tokio::runtime::Runtime> {
    use std::sync::OnceLock;
    static SHARED: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    if let Some(runtime) = SHARED.get() {
        return Ok(runtime);
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("axo-pty-test")
        // IO for the pumps' descriptors, and the signal driver for SIGCHLD.
        .enable_io()
        .build()?;
    Ok(SHARED.get_or_init(|| runtime))
}

/// This process's thread count, as the kernel reports it.
#[cfg(test)]
pub(crate) fn thread_count() -> i32 {
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: `info` is writable for `size` bytes.
    let filled = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDTASKINFO,
            0,
            (&mut info as *mut libc::proc_taskinfo).cast(),
            size,
        )
    };
    assert_eq!(filled, size);
    info.pti_threadnum
}
