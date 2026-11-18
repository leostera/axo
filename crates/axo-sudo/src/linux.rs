use super::*;
#[cfg(test)]
#[path = "linux_tests.rs"]
mod tests;
use std::{
    fs::{self, File},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::{
            fs::{DirBuilderExt, MetadataExt, PermissionsExt},
            net::UnixStream as BlockingStream,
        },
    },
    process::Stdio,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, unix::AsyncFd},
    net::{UnixListener, UnixStream},
    process::Command,
    sync::Semaphore,
    time::{Instant, timeout_at},
};

const SOCKET_ENV: &str = "AXO_SUDO_ASKPASS_SOCKET";
const NONCE_ENV: &str = "AXO_SUDO_ASKPASS_NONCE";
static ACTIVE: Semaphore = Semaphore::const_new(4);

fn failed(reason: Failure, may_have_run: bool) -> Receipt {
    Receipt::Failed {
        reason,
        may_have_run,
    }
}

struct Channel {
    directory: PathBuf,
    path: PathBuf,
    nonce: String,
    listener: UnixListener,
}
impl Channel {
    fn new() -> Result<Self, Failure> {
        let mut random = [0u8; 32];
        File::open("/dev/urandom")
            .and_then(|mut file| file.read_exact(&mut random))
            .map_err(|_| Failure::Unavailable)?;
        let nonce: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let directory = PathBuf::from(format!("/tmp/axo-sudo-{}", &nonce[..24]));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|_| Failure::Unavailable)?;
        let path = directory.join("input.sock");
        let listener = match UnixListener::bind(&path) {
            Ok(listener) => listener,
            Err(_) => {
                let _ = fs::remove_dir(&directory);
                return Err(Failure::Unavailable);
            }
        };
        let channel = Self {
            directory,
            path,
            nonce,
            listener,
        };
        fs::set_permissions(&channel.path, fs::Permissions::from_mode(0o600))
            .map_err(|_| Failure::Unavailable)?;
        Ok(channel)
    }
}
impl Drop for Channel {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
        let _ = fs::remove_dir(&self.directory);
    }
}

enum Ownership {
    RootSetuid,
    #[cfg(test)]
    OwnedFixture,
}
struct Prepared {
    directory: File,
    preview: String,
    helper: PathBuf,
    channel: Channel,
}
fn prepare(
    invocation: &Invocation,
    context: Context,
    sudo: &Path,
    ownership: Ownership,
) -> Result<Prepared, Failure> {
    let metadata = fs::metadata(sudo).map_err(|_| Failure::Unavailable)?;
    if !metadata.is_file() {
        return Err(Failure::Unavailable);
    }
    match ownership {
        Ownership::RootSetuid
            if metadata.uid() != 0
                || metadata.mode() & 0o4000 == 0
                || metadata.mode() & 0o022 != 0 =>
        {
            return Err(Failure::Unavailable);
        }
        _ => {}
    }
    let helper = fs::canonicalize(context.helper).map_err(|_| Failure::Unavailable)?;
    let metadata = fs::metadata(&helper).map_err(|_| Failure::Unavailable)?;
    if !metadata.is_file() || metadata.mode() & 0o111 == 0 {
        return Err(Failure::Unavailable);
    }
    let directory_path = fs::canonicalize(context.directory).map_err(|_| Failure::Unavailable)?;
    let directory = File::open(&directory_path).map_err(|_| Failure::Unavailable)?;
    if !directory
        .metadata()
        .map_err(|_| Failure::Unavailable)?
        .is_dir()
    {
        return Err(Failure::Unavailable);
    }
    let preview = invocation.preview(&directory_path)?;
    Ok(Prepared {
        directory,
        preview,
        helper,
        channel: Channel::new()?,
    })
}

pub(super) async fn run(
    invocation: Invocation,
    context: Context,
    prompter: &dyn Prompter,
    timeout: Duration,
) -> Receipt {
    run_with(
        invocation,
        context,
        prompter,
        timeout,
        Path::new("/usr/bin/sudo"),
        Ownership::RootSetuid,
    )
    .await
}

async fn run_with(
    invocation: Invocation,
    context: Context,
    prompter: &dyn Prompter,
    timeout: Duration,
    sudo: &Path,
    ownership: Ownership,
) -> Receipt {
    let Ok(_permit) = ACTIVE.try_acquire() else {
        return failed(Failure::Busy, false);
    };
    let prepared = match prepare(&invocation, context, sudo, ownership) {
        Ok(prepared) => prepared,
        Err(reason) => return failed(reason, false),
    };
    let deadline = Instant::now() + timeout.min(Duration::from_secs(300));
    let decision = timeout_at(
        deadline,
        prompter.confirm(
            &prepared.preview,
            deadline.saturating_duration_since(Instant::now()),
        ),
    )
    .await;
    match decision {
        Ok(Ok(Decision::Accept)) => {}
        Ok(Ok(Decision::Decline)) => {
            return Receipt::Declined {
                may_have_run: false,
            };
        }
        Ok(Ok(Decision::Cancel)) => {
            return Receipt::Cancelled {
                may_have_run: false,
            };
        }
        Ok(Err(reason)) => return failed(reason, false),
        Err(_) => return failed(Failure::TimedOut, false),
    }
    if Instant::now() >= deadline {
        return failed(Failure::TimedOut, false);
    }
    let mut command = Command::new(sudo);
    command
        .args(["-k", "-A", "--"])
        .args(&invocation.argv)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .env("SUDO_ASKPASS", &prepared.helper)
        .env(SOCKET_ENV, &prepared.channel.path)
        .env(NONCE_ENV, &prepared.channel.nonce)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let directory_fd = prepared.directory.as_raw_fd();
    // SAFETY: only async-signal-safe fchdir runs after fork; the parent retains this directory
    // handle until spawn has execed, pinning the directory the person was shown.
    unsafe {
        command.pre_exec(move || {
            if libc::fchdir(directory_fd) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => return failed(Failure::Unavailable, false),
    };
    let parent = child.id().expect("spawned child has an ID");
    let connection = tokio::select! {
        result = child.wait() => return exit_receipt(result, false),
        result = prepared.channel.listener.accept() => result.map(|(stream,_)|stream).map_err(|_|Failure::ChannelClosed),
        _ = tokio::time::sleep_until(deadline) => return failed(Failure::TimedOut, true),
    };
    let stream = match connection {
        Ok(stream) => stream,
        Err(reason) => return failed(reason, true),
    };
    let helper = timeout_at(
        deadline,
        BoundHelper::bind(stream, parent, &prepared.channel.nonce),
    )
    .await;
    let mut helper = match helper {
        Ok(Ok(helper)) => helper,
        Ok(Err(reason)) => return failed(reason, true),
        Err(_) => return failed(Failure::TimedOut, true),
    };
    let answer = tokio::select! {
        result = child.wait() => return exit_receipt(result, false),
        _ = helper.alive.readable() => return failed(Failure::TargetGone, true),
        result = timeout_at(deadline, prompter.password(&prepared.preview, deadline.saturating_duration_since(Instant::now()))) => result,
    };
    let password = match answer {
        Ok(Ok(PasswordAnswer::Accept(password))) => password,
        Ok(Ok(PasswordAnswer::Decline)) => return Receipt::Declined { may_have_run: true },
        Ok(Ok(PasswordAnswer::Cancel)) => return Receipt::Cancelled { may_have_run: true },
        Ok(Err(reason)) => return failed(reason, true),
        Err(_) => return failed(Failure::TimedOut, true),
    };
    if !helper.is_alive() || !matches!(child.try_wait(), Ok(None)) {
        return failed(Failure::TargetGone, true);
    }
    if timeout_at(deadline, helper.deliver(password))
        .await
        .is_err()
    {
        return failed(Failure::TimedOut, true);
    }
    if !helper.delivered {
        return failed(Failure::ChannelClosed, true);
    }
    // Exactly one password attempt. Later askpass invocations cannot reuse the socket.
    drop(helper);
    drop(prepared);
    tokio::select! {
        result = child.wait() => exit_receipt(result, true),
        _ = tokio::time::sleep_until(deadline) => failed(Failure::TimedOut, true),
    }
}
fn exit_receipt(
    result: std::io::Result<std::process::ExitStatus>,
    input_delivered: bool,
) -> Receipt {
    match result {
        Ok(status) => Receipt::Completed {
            input_delivered,
            exit_code: status.code(),
        },
        Err(_) => failed(Failure::TargetGone, true),
    }
}

struct BoundHelper {
    stream: UnixStream,
    alive: AsyncFd<OwnedFd>,
    delivered: bool,
}
impl BoundHelper {
    async fn bind(mut stream: UnixStream, parent: u32, nonce: &str) -> Result<Self, Failure> {
        let peer = stream.peer_cred().map_err(|_| Failure::ForeignHelper)?;
        let pid = peer
            .pid()
            .filter(|pid| *pid > 0)
            .ok_or(Failure::ForeignHelper)?;
        if peer.uid() != unsafe { libc::getuid() } {
            return Err(Failure::ForeignHelper);
        }
        // A pidfd pins the helper's process identity while the person is answering.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if fd < 0 {
            return Err(Failure::ForeignHelper);
        }
        let fd = unsafe { OwnedFd::from_raw_fd(fd as i32) };
        // SAFETY: this private OwnedFd stays open, unchanged and exclusively owned by
        // AsyncFd until deregistration; no code closes or replaces its raw descriptor.
        let alive = unsafe { AsyncFd::register(fd) }.map_err(|_| Failure::ForeignHelper)?;
        let stat =
            fs::read_to_string(format!("/proc/{pid}/stat")).map_err(|_| Failure::ForeignHelper)?;
        let after_name = stat
            .rsplit_once(')')
            .map(|(_, tail)| tail)
            .ok_or(Failure::ForeignHelper)?;
        let actual_parent = after_name
            .split_whitespace()
            .nth(1)
            .and_then(|value| value.parse::<u32>().ok());
        if actual_parent != Some(parent) {
            return Err(Failure::ForeignHelper);
        }
        let mut supplied = [0u8; 64];
        tokio::time::timeout(Duration::from_secs(2), stream.read_exact(&mut supplied))
            .await
            .map_err(|_| Failure::ForeignHelper)?
            .map_err(|_| Failure::ForeignHelper)?;
        if supplied != nonce.as_bytes() {
            return Err(Failure::ForeignHelper);
        }
        let helper = Self {
            stream,
            alive,
            delivered: false,
        };
        if !helper.is_alive() {
            return Err(Failure::TargetGone);
        }
        Ok(helper)
    }
    fn is_alive(&self) -> bool {
        let mut fd = libc::pollfd {
            fd: self.alive.get_ref().as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        unsafe { libc::poll(&mut fd, 1, 0) == 0 }
    }
    async fn deliver(&mut self, password: Password) {
        let bytes = password.0.as_bytes();
        if self
            .stream
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .await
            .is_ok()
            && self.stream.write_all(bytes).await.is_ok()
        {
            self.delivered = true;
        }
    }
}

pub(super) fn askpass() -> Result<(), ()> {
    // The helper is deliberately small and disables same-UID process-memory inspection.
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0) } != 0 {
        return Err(());
    }
    if unsafe { libc::isatty(libc::STDOUT_FILENO) } != 0 {
        return Err(());
    }
    let output = fs::read_link("/proc/self/fd/1").map_err(|_| ())?;
    if !output.to_string_lossy().starts_with("pipe:[") {
        return Err(());
    }
    let path = std::env::var_os(SOCKET_ENV).ok_or(())?;
    let nonce = std::env::var(NONCE_ENV).map_err(|_| ())?;
    if nonce.len() != 64 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(());
    }
    let mut stream = BlockingStream::connect(path).map_err(|_| ())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(300)))
        .map_err(|_| ())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|_| ())?;
    stream.write_all(nonce.as_bytes()).map_err(|_| ())?;
    let mut length = [0u8; 4];
    stream.read_exact(&mut length).map_err(|_| ())?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAX_PASSWORD_BYTES {
        return Err(());
    }
    // Reserve the terminator up front: appending must not reallocate plaintext.
    let mut password = Zeroizing::new(vec![0u8; length + 1]);
    stream.read_exact(&mut password[..length]).map_err(|_| ())?;
    if password[..length]
        .iter()
        .any(|byte| matches!(*byte, 0 | b'\n' | b'\r'))
    {
        return Err(());
    }
    password[length] = b'\n';
    // SAFETY: this single-threaded helper exclusively owns its verified pipe fd 1.
    // Bypass stdout’s global buffer; keep the complete bounded line in one write.
    let mut output = unsafe { File::from_raw_fd(libc::STDOUT_FILENO) };
    output.write_all(&password).map_err(|_| ())
}
