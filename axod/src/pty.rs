use crate::model::{ChildPid, TerminalSize};
use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;

pub struct ChildTerminal {
    pub pid: ChildPid,
    pub controller: File,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct CapturedEnvironment<'a> {
    pub normal_path: Option<&'a std::ffi::OsStr>,
    pub login_shell: Option<&'a std::ffi::OsStr>,
}
pub(crate) fn spawn_with_path(
    cwd: &str,
    argv: &[String],
    environment: CapturedEnvironment<'_>,
) -> io::Result<ChildTerminal> {
    spawn_inner(cwd, argv, None, environment)
}

/// Explicit managed launch only. The private worker endpoint becomes fd 3;
/// all other nonstandard inherited descriptors are still closed before exec.
pub(crate) fn spawn_with_control_path(
    cwd: &str,
    argv: &[String],
    environment: CapturedEnvironment<'_>,
) -> io::Result<(ChildTerminal, UnixStream)> {
    let (controller, worker) = UnixStream::pair()?;
    let child = spawn_inner(cwd, argv, Some(&worker), environment)?;
    drop(worker);
    Ok((child, controller))
}
fn spawn_inner(
    cwd: &str,
    argv: &[String],
    control: Option<&UnixStream>,
    captured: CapturedEnvironment<'_>,
) -> io::Result<ChildTerminal> {
    validate_launch(cwd, argv)?;
    let directory = c_string(cwd)?;
    let arguments: Vec<CString> = argv
        .iter()
        .map(|arg| c_string(arg))
        .collect::<io::Result<_>>()?;
    let argument_pointers = null_terminated_pointers(&arguments);
    let environment = child_environment(captured)?;
    let environment_pointers = null_terminated_pointers(&environment);
    let mut size = libc::winsize {
        ws_row: 30,
        ws_col: 100,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let descriptor_ceiling = child_descriptor_ceiling()?;
    let executable = arguments[0].as_ptr();
    let control_fd = control.map(AsRawFd::as_raw_fd);
    let mut controller_fd = -1;
    // Prepare all Rust-owned memory BEFORE fork. The child calls only libc then exec/_exit:
    // no allocator, mutex, logging, or Rust destructor after a multithreaded fork.
    let pid = unsafe {
        libc::forkpty(
            &mut controller_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        unsafe {
            // Library-created descriptors may lack CLOEXEC (e.g. Darwin's cached netsrc socket).
            // Close the inherited nonstandard table, not just descriptors this manager created.
            if let Some(descriptor) = control_fd
                && (libc::dup2(descriptor, 3) < 0 || libc::fcntl(3, libc::F_SETFD, 0) < 0)
            {
                libc::_exit(126);
            }
            let first_closed = if control_fd.is_some() { 4 } else { 3 };
            for descriptor in first_closed..descriptor_ceiling {
                while libc::close(descriptor) < 0 {
                    let error = *libc::__error();
                    if error == libc::EBADF {
                        break;
                    }
                    if error != libc::EINTR {
                        libc::_exit(126);
                    }
                }
            }
            if libc::chdir(directory.as_ptr()) != 0 {
                libc::_exit(126);
            }
            libc::execve(
                executable,
                argument_pointers.as_ptr(),
                environment_pointers.as_ptr(),
            );
            libc::_exit(127);
        }
    }
    // SAFETY: forkpty returned this owned descriptor only in the parent.
    let controller = unsafe { File::from_raw_fd(controller_fd) };
    if let Err(error) = configure_controller(&controller) {
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
            // The child may not have completed forkpty's session/group setup yet.
            libc::kill(pid, libc::SIGKILL);
            libc::waitpid(pid, std::ptr::null_mut(), 0);
        }
        return Err(error);
    }
    Ok(ChildTerminal {
        pid: ChildPid::try_from(pid).expect("Positive forkpty parent result"),
        controller,
    })
}

pub fn resize(controller: &File, dimensions: TerminalSize) -> io::Result<()> {
    let size = libc::winsize {
        ws_row: dimensions.rows(),
        ws_col: dimensions.columns(),
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe { libc::ioctl(controller.as_raw_fd(), libc::TIOCSWINSZ, &size) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn child_descriptor_ceiling() -> io::Result<libc::c_int> {
    let mut ceiling: libc::c_int = 0;
    let mut size = std::mem::size_of_val(&ceiling);
    // Use Darwin's allocation ceiling, not a soft rlimit that may have been lowered
    // below already-open inherited descriptors. This daemon never changes kernel limits.
    if unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            std::ptr::addr_of_mut!(ceiling).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    // Fail before fork rather than perform unbounded work or leave higher descriptors open.
    if size != std::mem::size_of_val(&ceiling) || !(3..=1_048_576).contains(&ceiling) {
        return Err(io::Error::other("Unsupported child descriptor limit"));
    }
    Ok(ceiling)
}

pub(crate) fn validate_launch(cwd: &str, argv: &[String]) -> io::Result<()> {
    if cwd.len() > 4096 || !Path::new(cwd).is_absolute() || !Path::new(cwd).is_dir() {
        return Err(io::Error::other(
            "Working directory must be an existing absolute directory",
        ));
    }
    if argv.is_empty()
        || argv.len() > 64
        || !Path::new(&argv[0]).is_absolute()
        || argv.iter().map(String::len).sum::<usize>() > 32 * 1024
    {
        return Err(io::Error::other(
            "Provide an absolute executable and bounded argument list",
        ));
    }
    Ok(())
}

fn child_environment(captured: CapturedEnvironment<'_>) -> io::Result<Vec<CString>> {
    // Bindings come from an explicit managed launch, never the parent's active turn.
    let mut environment: Vec<CString> = std::env::vars_os()
        .filter(|(key, _)| {
            !key.as_encoded_bytes().starts_with(b"AXO_") && key != "TERM" && key != "COLORTERM"
        })
        .map(|(key, value)| {
            let mut entry = key.as_encoded_bytes().to_vec();
            entry.push(b'=');
            entry.extend_from_slice(value.as_encoded_bytes());
            CString::new(entry).map_err(|_| io::Error::other("Invalid child environment"))
        })
        .collect::<io::Result<_>>()?;
    if let Some(shell) = captured.login_shell {
        environment.retain(|entry| !entry.to_bytes().starts_with(b"SHELL="));
        let mut value = b"SHELL=".to_vec();
        value.extend_from_slice(shell.as_bytes());
        environment
            .push(CString::new(value).map_err(|_| io::Error::other("Invalid captured shell"))?);
    }
    if let Some(path) = captured.normal_path {
        environment.retain(|entry| !entry.to_bytes().starts_with(b"PATH="));
        let mut value = b"PATH=".to_vec();
        value.extend_from_slice(path.as_bytes());
        environment
            .push(CString::new(value).map_err(|_| io::Error::other("Invalid captured PATH"))?);
    }
    environment.push(c_string("TERM=xterm-256color")?);
    environment.push(c_string("COLORTERM=truecolor")?);
    Ok(environment)
}

fn configure_controller(controller: &File) -> io::Result<()> {
    let descriptor = controller.as_raw_fd();
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
    let descriptor_flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    // Future children must not inherit another pane's controller descriptor.
    if flags < 0
        || descriptor_flags < 0
        || unsafe {
            libc::fcntl(
                descriptor,
                libc::F_SETFD,
                descriptor_flags | libc::FD_CLOEXEC,
            )
        } < 0
        || unsafe { libc::fcntl(descriptor, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn c_string(value: &str) -> io::Result<CString> {
    CString::new(value).map_err(|_| io::Error::other("NUL is not permitted"))
}

fn null_terminated_pointers(values: &[CString]) -> Vec<*const libc::c_char> {
    values
        .iter()
        .map(|value| value.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controlled_launch_keeps_only_the_explicit_socket_and_real_terminal_streams() {
        use std::io::{Read, Write};
        use std::time::Duration;
        let source = File::open("/dev/null").unwrap();
        let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(descriptor >= 200);
        let inherited = unsafe { File::from_raw_fd(descriptor) };
        let script = format!(
            "import os,sys\nassert os.isatty(0) and os.isatty(1) and os.isatty(2)\ntry: os.fstat({descriptor})\nexcept OSError: pass\nelse: sys.exit(9)\nos.write(3,b'ready')\nsys.exit(0 if os.read(3,1)==b'x' else 8)\n"
        );
        let (terminal, mut channel) = spawn_with_control_path(
            "/tmp",
            &["/usr/bin/python3".into(), "-c".into(), script],
            CapturedEnvironment::default(),
        )
        .unwrap();
        assert_ne!(
            unsafe { libc::fcntl(channel.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        channel
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut ready = [0; 5];
        channel.read_exact(&mut ready).unwrap();
        assert_eq!(&ready, b"ready");
        channel.write_all(b"x").unwrap();
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(terminal.pid.as_raw(), &mut status, 0) },
            terminal.pid.as_raw()
        );
        assert!(libc::WIFEXITED(status));
        assert_eq!(libc::WEXITSTATUS(status), 0);
        drop(inherited);
    }
    #[test]
    fn child_environment_uses_the_captured_login_shell_and_path() {
        let environment = child_environment(CapturedEnvironment {
            normal_path: Some(std::ffi::OsStr::new("/usr/bin:/bin")),
            login_shell: Some(std::ffi::OsStr::new("/bin/zsh")),
        })
        .unwrap();
        let shells: Vec<_> = environment
            .iter()
            .filter(|entry| entry.to_bytes().starts_with(b"SHELL="))
            .collect();
        assert_eq!(shells.len(), 1);
        assert_eq!(shells[0].to_bytes(), b"SHELL=/bin/zsh");
        assert!(
            environment
                .iter()
                .any(|entry| entry.to_bytes() == b"PATH=/usr/bin:/bin")
        );
    }
    #[test]
    fn child_closes_inheritable_descriptors_not_created_by_the_runtime() {
        let source = File::open("/dev/null").unwrap();
        let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(descriptor >= 200);
        let inherited = unsafe { File::from_raw_fd(descriptor) };
        let script = format!(
            "import os,sys\ntry: os.fstat({descriptor})\nexcept OSError: sys.exit(0)\nsys.exit(1)\n"
        );
        let terminal = spawn_with_path(
            "/tmp",
            &["/usr/bin/python3".into(), "-c".into(), script],
            CapturedEnvironment::default(),
        )
        .unwrap();
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(terminal.pid.as_raw(), &mut status, 0) },
            terminal.pid.as_raw()
        );
        assert!(libc::WIFEXITED(status));
        assert_eq!(libc::WEXITSTATUS(status), 0);
        drop(inherited);
    }
}
