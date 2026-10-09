use crate::model::{ChildPid, TerminalSize};
use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::Path;

pub struct ChildTerminal {
    pub pid: ChildPid,
    pub controller: File,
}

pub fn spawn(cwd: &str, argv: &[String]) -> io::Result<ChildTerminal> {
    validate_launch(cwd, argv)?;
    let directory = c_string(cwd)?;
    let arguments: Vec<CString> = argv
        .iter()
        .map(|arg| c_string(arg))
        .collect::<io::Result<_>>()?;
    let argument_pointers = null_terminated_pointers(&arguments);
    let environment = child_environment()?;
    let environment_pointers = null_terminated_pointers(&environment);
    let mut size = libc::winsize {
        ws_row: 30,
        ws_col: 100,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let executable = arguments[0].as_ptr();
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

fn validate_launch(cwd: &str, argv: &[String]) -> io::Result<()> {
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

fn child_environment() -> io::Result<Vec<CString>> {
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
