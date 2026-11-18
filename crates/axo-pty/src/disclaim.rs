//! Starting a program as its own responsible process (RFD0070, disclaimed children).
//!
//! macOS decides privacy grants (TCC: Accessibility, Screen Recording, ...) for the process
//! *responsible* for a program, which is normally the app that started it, all the way down a
//! process tree. Every program axod starts would otherwise use axod's grants, so an agent's shell
//! could press buttons and read the screen without the computer-use gate. A program started here
//! is its own responsible process: it holds no grant the person did not give it.
//!
//! [`exec_disclaimed`] adds a last `pre_exec` step that replaces the forked child with the
//! program through `posix_spawn(POSIX_SPAWN_SETEXEC)` with the disclaim attribute, the private
//! but stable libSystem call LLDB and Chromium use for the same reason. The path, arguments and
//! environment are prepared in the parent, so the child only makes that one call. If it fails,
//! the launch fails: there is no fallback to an ordinary exec.

use std::io;
use std::process::Command;

/// Makes `command` start disclaimed. Register it after every other `pre_exec` step: it replaces
/// the process, so nothing registered after it runs.
///
/// The program must be an absolute path. The child gets the parent's environment with the
/// command's `env`/`env_remove` changes applied; `env_clear` is not supported (nothing in axod
/// uses it, and it cannot be seen from a `Command`).
#[cfg(target_os = "macos")]
pub fn exec_disclaimed(command: &mut Command) -> io::Result<()> {
    use std::os::unix::process::CommandExt;
    let launch = imp::Launch::of(command)?;
    // SAFETY: the closure runs in the forked child before exec and only calls posix_spawn with
    // pointers prepared in the parent; on success it does not return.
    unsafe {
        command.pre_exec(move || Err(launch.exec()));
    }
    Ok(())
}

/// Elsewhere there is no TCC, so nothing to disclaim.
#[cfg(not(target_os = "macos"))]
pub fn exec_disclaimed(_command: &mut Command) -> io::Result<()> {
    Ok(())
}

/// The process macOS holds responsible for `pid`'s privacy checks.
#[cfg(target_os = "macos")]
pub fn responsible_pid(pid: u32) -> Option<u32> {
    unsafe extern "C" {
        fn responsibility_get_pid_responsible_for_pid(pid: libc::pid_t) -> libc::pid_t;
    }
    // SAFETY: a pure query on a pid; it answers -1 when the pid is unknown.
    let responsible = unsafe { responsibility_get_pid_responsible_for_pid(pid as libc::pid_t) };
    u32::try_from(responsible).ok().filter(|pid| *pid > 0)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::collections::BTreeMap;
    use std::ffi::{CString, OsString};
    use std::io;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;
    use std::process::Command;

    unsafe extern "C" {
        fn responsibility_spawnattrs_setdisclaim(
            attrs: *mut libc::posix_spawnattr_t,
            disclaim: libc::c_int,
        ) -> libc::c_int;
    }

    /// Everything the child's single `posix_spawn` needs, owned by the parent.
    pub(super) struct Launch {
        attrs: libc::posix_spawnattr_t,
        path: CString,
        _argv: Vec<CString>,
        argv: Vec<*mut libc::c_char>,
        _envp: Vec<CString>,
        envp: Vec<*mut libc::c_char>,
    }

    // SAFETY: the pointers point into the CStrings this value owns, and the attributes are only
    // read; the child uses them after fork, where no other thread exists.
    unsafe impl Send for Launch {}
    unsafe impl Sync for Launch {}

    impl Launch {
        pub(super) fn of(command: &Command) -> io::Result<Self> {
            let program = Path::new(command.get_program());
            if !program.is_absolute() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!(
                        "a disclaimed launch needs an absolute program path, not {}",
                        program.display()
                    ),
                ));
            }
            let path = c_string(program.as_os_str().as_bytes())?;
            let owned_argv = std::iter::once(program.as_os_str())
                .chain(command.get_args())
                .map(|argument| c_string(argument.as_bytes()))
                .collect::<io::Result<Vec<_>>>()?;
            let owned_envp = environment(command)
                .into_iter()
                .map(|(name, value)| {
                    let mut pair = name.as_bytes().to_vec();
                    pair.push(b'=');
                    pair.extend_from_slice(value.as_bytes());
                    c_string(&pair)
                })
                .collect::<io::Result<Vec<_>>>()?;
            let mut attrs: libc::posix_spawnattr_t = std::ptr::null_mut();
            // SAFETY: initializes the attribute object we own; destroyed in Drop.
            check(unsafe { libc::posix_spawnattr_init(&mut attrs) })?;
            let mut launch = Self {
                attrs,
                path,
                argv: pointers(&owned_argv),
                _argv: owned_argv,
                envp: pointers(&owned_envp),
                _envp: owned_envp,
            };
            // SAFETY: both act on the initialized attribute object.
            check(unsafe { responsibility_spawnattrs_setdisclaim(&mut launch.attrs, 1) })?;
            check(unsafe {
                libc::posix_spawnattr_setflags(&mut launch.attrs, libc::POSIX_SPAWN_SETEXEC as _)
            })?;
            Ok(launch)
        }

        /// Replaces this process with the program; returns only the error if it could not.
        pub(super) fn exec(&self) -> io::Error {
            let mut pid: libc::pid_t = 0;
            // SAFETY: every pointer is owned by `self` and NUL-terminated or null-terminated.
            let error = unsafe {
                libc::posix_spawn(
                    &mut pid,
                    self.path.as_ptr(),
                    std::ptr::null(),
                    &self.attrs,
                    self.argv.as_ptr(),
                    self.envp.as_ptr(),
                )
            };
            io::Error::from_raw_os_error(error)
        }
    }

    impl Drop for Launch {
        fn drop(&mut self) {
            // SAFETY: destroys the attribute object initialized in `of`.
            unsafe { libc::posix_spawnattr_destroy(&mut self.attrs) };
        }
    }

    /// The parent's environment with the command's own changes.
    fn environment(command: &Command) -> BTreeMap<OsString, OsString> {
        let mut environment: BTreeMap<OsString, OsString> = std::env::vars_os().collect();
        for (name, value) in command.get_envs() {
            match value {
                Some(value) => environment.insert(name.to_owned(), value.to_owned()),
                None => environment.remove(name),
            };
        }
        environment
    }

    fn pointers(strings: &[CString]) -> Vec<*mut libc::c_char> {
        strings
            .iter()
            .map(|string| string.as_ptr().cast_mut())
            .chain(std::iter::once(std::ptr::null_mut()))
            .collect()
    }

    fn c_string(bytes: &[u8]) -> io::Result<CString> {
        CString::new(bytes).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "a launch argument holds a NUL")
        })
    }

    fn check(code: libc::c_int) -> io::Result<()> {
        if code == 0 {
            Ok(())
        } else {
            Err(io::Error::from_raw_os_error(code))
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    fn sleeper() -> Command {
        let mut command = Command::new("/bin/sleep");
        command.arg("5");
        command
    }

    #[test]
    fn a_disclaimed_child_is_its_own_responsible_process() {
        let mut ordinary = sleeper().spawn().unwrap();
        let mut command = sleeper();
        exec_disclaimed(&mut command).unwrap();
        let mut disclaimed = command.spawn().unwrap();
        let mine = responsible_pid(std::process::id());
        assert_eq!(responsible_pid(ordinary.id()), mine, "an ordinary child is ours");
        assert_eq!(responsible_pid(disclaimed.id()), Some(disclaimed.id()));
        for child in [&mut ordinary, &mut disclaimed] {
            child.kill().unwrap();
            child.wait().unwrap();
        }
    }

    #[test]
    fn the_child_keeps_its_arguments_environment_and_directory() {
        let directory = std::env::temp_dir().canonicalize().unwrap();
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "printf '%s|%s|%s|%s' \"$0\" \"$AXO_DISCLAIM_TEST\" \"${HOME-unset}\" \"$PWD\"", "arg zero"])
            .env("AXO_DISCLAIM_TEST", "kept")
            .env_remove("HOME")
            .current_dir(&directory)
            .process_group(0);
        exec_disclaimed(&mut command).unwrap();
        let output = command.output().unwrap();
        assert!(output.status.success(), "{output:?}");
        let printed = String::from_utf8(output.stdout).unwrap();
        let [arg0, kept, home, pwd] = printed.split('|').collect::<Vec<_>>()[..] else {
            panic!("{printed}");
        };
        assert_eq!((arg0, kept, home), ("arg zero", "kept", "unset"));
        assert_eq!(std::path::Path::new(pwd).canonicalize().unwrap(), directory);
    }

    #[test]
    fn a_relative_program_is_refused_before_anything_runs() {
        let mut command = Command::new("sleep");
        let error = exec_disclaimed(&mut command).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    }

    #[test]
    fn a_program_that_cannot_start_fails_the_launch() {
        let mut command = Command::new("/nonexistent/axo-disclaim-test");
        exec_disclaimed(&mut command).unwrap();
        assert!(command.spawn().is_err());
    }
}
