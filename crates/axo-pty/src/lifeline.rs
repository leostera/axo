//! The lifeline (RFD0041): a pipe whose write end only axod holds. Every Pi axod starts inherits
//! the read end and exits when it reads end of file, which the kernel delivers however axod ends,
//! `kill -9` included. So no Pi outlives the axod that started it.

use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// The environment variable that tells Pi which descriptor its lifeline is.
pub const LIFELINE_FD: &str = "AXO_LIFELINE_FD";

/// Two pipes, both ending with axod: one for programs that watch it themselves (Pi), one only
/// the guard shell reads. They must not share a pipe: a pipe's blocking mode belongs to the open
/// file description every inheritor shares, and Node (Pi's `net.Socket` on the descriptor) makes
/// it non-blocking. The guard's `read` then fails at once with `EAGAIN`, which it cannot tell
/// from the lifeline's end, and kills the program it guards.
#[derive(Debug)]
pub struct Lifeline {
    /// Inherited by each Pi; close-on-exec here, so only launches that ask for it pass it on.
    watched: Pipe,
    /// The guard shell's stdin, never handed to anything that could change its mode.
    guard: Pipe,
}

#[derive(Debug)]
struct Pipe {
    read: OwnedFd,
    /// Never written; closing it (axod ending) is the message.
    _write: OwnedFd,
}

impl Lifeline {
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            watched: Pipe::new()?,
            guard: Pipe::new()?,
        })
    }

    /// The descriptor a Pi inherits, at the same number.
    pub fn reader(&self) -> RawFd {
        self.watched.read.as_raw_fd()
    }
}

impl Pipe {
    fn new() -> io::Result<Self> {
        let mut ends = [0; 2];
        // SAFETY: `ends` holds two descriptors. Linux marks both CLOEXEC atomically so a
        // concurrent helper spawn cannot inherit a writer between pipe and fcntl.
        #[cfg(target_os = "linux")]
        let result = unsafe { libc::pipe2(ends.as_mut_ptr(), libc::O_CLOEXEC) };
        #[cfg(not(target_os = "linux"))]
        let result = unsafe { libc::pipe(ends.as_mut_ptr()) };
        if result == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: pipe returned two new descriptors, owned from here on.
        let (read, write) =
            unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
        crate::process::set_cloexec(read.as_raw_fd())?;
        crate::process::set_cloexec(write.as_raw_fd())?;
        Ok(Self {
            read,
            _write: write,
        })
    }
}

impl Lifeline {
    /// A command that runs `program` (with the arguments the caller adds) under a shell that
    /// kills it when this lifeline ends, for programs that cannot watch one themselves, such as
    /// llama.cpp's server. stdin belongs to the lifeline; the program gets /dev/null instead.
    /// With a lock, the guard keeps it on stdout and redirects the program's stdout to stderr.
    /// Do not replace stdin or (with a lock) stdout on the returned command.
    ///
    /// Standard-I/O mappings and process_group use posix_spawn without a pre_exec callback.
    /// fork is unsafe alongside macOS notification initialization, even before our callback:
    /// libSystem's atfork hook can abort with 'os_once_t is corrupt'.
    pub fn guarded(&self, program: &Path, lock: Option<&File>) -> io::Result<Command> {
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(GUARD)
            .arg("sh")
            .arg(if lock.is_some() { "locked" } else { "plain" })
            .arg(program)
            .stdin(Stdio::from(self.guard.read.try_clone()?))
            .process_group(0);
        if let Some(lock) = lock {
            command.stdout(Stdio::from(lock.try_clone()?));
        }
        Ok(command)
    }
}

/// `sh -c GUARD sh <locked|plain> <program> <args>...`: stdin is the lifeline; in locked mode
/// stdout holds the inherited lock. Kills the program on EOF or when the shell is stopped. A child may ignore SIGTERM; neither
/// loss of its owner nor stopping the guard is permission to survive. A trap also reaps the
/// child: a signal interrupts the outer `wait` before that wait necessarily saw the exit.
const GUARD: &str = r#"mode=$1
shift
# POSIX shells may replace stdin with /dev/null for background jobs. Preserve it first.
exec 3<&0
if [ "$mode" = locked ]; then
  "$@" </dev/null 3<&- >&2 &
else
  "$@" </dev/null 3<&- &
fi
child=$!
trap 'kill -KILL "$child" 2>/dev/null; wait "$child" 2>/dev/null' HUP INT TERM
{ read -r _; kill -KILL "$child" 2>/dev/null; } <&3 3<&- >/dev/null &
watcher=$!
exec 3<&-
wait "$child"
status=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
exit "$status"
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::process::{Command, Stdio};

    #[test]
    fn a_child_reading_the_lifeline_sees_its_end_when_the_lifeline_is_dropped() {
        let lifeline = Lifeline::new().unwrap();
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg("cat >/dev/null; echo ended")
            .stdin(Stdio::from(lifeline.watched.read.try_clone().unwrap()))
            .stdout(Stdio::piped());
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

    fn alive(pid: i32) -> bool {
        // SAFETY: signal 0 only asks whether the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// Starts `sleep` under the guard and returns the guard and the sleep's pid.
    fn guarded_sleep(lifeline: &Lifeline, directory: &Path) -> (std::process::Child, i32) {
        let pid_file = directory.join("pid");
        let mut guard = lifeline
            .guarded(Path::new("/bin/sh"), None)
            .unwrap()
            .arg("-c")
            .arg(format!(
                "trap '' TERM; echo $$ > {}; exec sleep 30",
                pid_file.display()
            ))
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if let Some(pid) = std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|text| text.trim().parse().ok())
            {
                return (guard, pid);
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the program never started"
            );
            assert!(guard.try_wait().unwrap().is_none());
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn directory(name: &str) -> std::path::PathBuf {
        let unique = format!("{}-{}", std::process::id(), name);
        let directory = std::path::PathBuf::from("/tmp").join(format!("axo-lifeline-{unique}"));
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn the_guard_keeps_the_lock_and_plain_programs_keep_their_stdout() {
        use std::fs::OpenOptions;
        let directory = directory("lock");
        let lock = File::create(directory.join("lock")).unwrap();
        // SAFETY: these descriptors are owned by this test.
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let lifeline = Lifeline::new().unwrap();
        let mut guard = lifeline
            .guarded(Path::new("/bin/sleep"), Some(&lock))
            .unwrap()
            .arg("30")
            .spawn()
            .unwrap();
        drop(lock);
        let second = OpenOptions::new()
            .write(true)
            .open(directory.join("lock"))
            .unwrap();
        assert_ne!(
            unsafe { libc::flock(second.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        drop(lifeline);
        guard.wait().unwrap();
        assert_eq!(
            unsafe { libc::flock(second.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let lifeline = Lifeline::new().unwrap();
        let output = lifeline
            .guarded(Path::new("/bin/echo"), None)
            .unwrap()
            .arg("hello")
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello\n");
        std::fs::remove_dir_all(directory).unwrap();
    }

    /// Pi's Node opens its lifeline as a `net.Socket`, which makes the pipe non-blocking for
    /// everyone sharing its file description. A guard must not read that as the end.
    #[test]
    fn a_guarded_program_survives_a_watcher_making_the_lifeline_non_blocking() {
        let directory = directory("nonblocking");
        let lifeline = Lifeline::new().unwrap();
        let reader = lifeline.reader();
        // SAFETY: `reader` is the lifeline's open read end; this changes only its status flags.
        unsafe {
            let flags = libc::fcntl(reader, libc::F_GETFL);
            assert_ne!(flags, -1);
            assert_ne!(
                libc::fcntl(reader, libc::F_SETFL, flags | libc::O_NONBLOCK),
                -1
            );
        }
        let (mut guard, pid) = guarded_sleep(&lifeline, &directory);
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert!(alive(pid), "the guard killed its program while axod lives");
        assert!(guard.try_wait().unwrap().is_none());
        drop(lifeline);
        guard.wait().unwrap();
        assert!(!alive(pid), "the program outlived its lifeline");
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn a_guarded_program_ends_with_the_lifeline() {
        let directory = directory("ends");
        let lifeline = Lifeline::new().unwrap();
        let (mut guard, pid) = guarded_sleep(&lifeline, &directory);
        assert!(alive(pid));
        drop(lifeline);
        guard.wait().unwrap();
        assert!(!alive(pid), "the program outlived its lifeline");
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn stopping_the_guard_stops_its_program_and_a_program_that_exits_ends_the_guard() {
        let directory = directory("stops");
        let lifeline = Lifeline::new().unwrap();
        let (mut guard, pid) = guarded_sleep(&lifeline, &directory);
        // SAFETY: signals the guard this test started.
        assert_eq!(unsafe { libc::kill(guard.id() as i32, libc::SIGTERM) }, 0);
        guard.wait().unwrap();
        assert!(!alive(pid));

        let _ = std::fs::remove_file(directory.join("pid"));
        let (mut guard, pid) = guarded_sleep(&lifeline, &directory);
        // SAFETY: signals the program this test started.
        assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
        let status = guard.wait().unwrap();
        assert!(!status.success());
        let _ = std::fs::remove_dir_all(directory);
    }
}
