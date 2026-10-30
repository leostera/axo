use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// How long to wait for something a test needs before going on: a socket, a shell's output, a
/// process to start. Only a failing test waits this long; a loaded machine has needed over 4 s.
const READY_WAIT: Duration = Duration::from_secs(15);

struct ChildGuard(Child);

#[derive(Default)]
struct SessionProcessCleanup(Vec<libc::pid_t>);

impl SessionProcessCleanup {
    fn track(&mut self, session: &Value) {
        self.0.extend(
            session["shells"]
                .as_array()
                .unwrap()
                .iter()
                .map(|shell| shell["processId"].as_i64().unwrap() as libc::pid_t),
        );
    }
}

impl Drop for SessionProcessCleanup {
    fn drop(&mut self) {
        // An unavailable pane reports process 0, and kill(-0) would signal this test's group.
        for process_id in self.0.iter().filter(|process_id| **process_id > 0) {
            // SAFETY: these PIDs came from sessions created by this isolated test daemon.
            unsafe {
                libc::kill(-process_id, libc::SIGKILL);
                libc::kill(*process_id, libc::SIGKILL);
            }
        }
    }
}

impl ChildGuard {
    fn stop(&mut self) {
        if self.0.try_wait().ok().flatten().is_some() {
            return;
        }
        // SAFETY: this sends SIGTERM to only the daemon child created by this test.
        unsafe {
            libc::kill(self.0.id() as libc::pid_t, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = self.0.kill();
        let kill_deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < kill_deadline {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        panic!("axod did not exit within three seconds after SIGKILL");
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_some() {
            return;
        }
        // Let the daemon run its bounded PTY cleanup before falling back to SIGKILL.
        // SAFETY: this sends SIGTERM to only the daemon child created by this test.
        unsafe {
            libc::kill(self.0.id() as libc::pid_t, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = self.0.kill();
        let kill_deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < kill_deadline {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

fn axod_binary() -> std::path::PathBuf {
    if let Some(path) = std::env::var_os("AXOD_BINARY") {
        let path = std::path::PathBuf::from(path);
        if path.is_absolute() || path.exists() {
            return path;
        }

        let runfiles = std::env::var_os("RUNFILES_DIR")
            .or_else(|| std::env::var_os("TEST_SRCDIR"))
            .map(std::path::PathBuf::from)
            .expect("Bazel test should provide its runfiles directory");
        let workspace = std::env::var_os("TEST_WORKSPACE").unwrap_or_default();
        let candidates = [
            runfiles.join(&path),
            runfiles.join(&workspace).join(&path),
            runfiles.join("_main").join(&path),
        ];
        return candidates
            .into_iter()
            .find(|candidate| candidate.exists())
            .expect("axod should be present in the Bazel runfiles");
    }

    match option_env!("CARGO_BIN_EXE_axod") {
        Some(path) => std::path::PathBuf::from(path),
        None => panic!("Cargo or Bazel should provide the axod binary path"),
    }
}

/// A fresh directory path under `/tmp` (Unix socket paths are limited to 104 bytes). Tests in one
/// binary run concurrently and `SystemTime` has only microsecond resolution on macOS, so the
/// counter is what keeps two tests from sharing a directory, and with it axod's socket.
fn unique_test_directory(tag: &str) -> std::path::PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let index = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::path::PathBuf::from("/tmp").join(format!("{tag}-{}-{index}-{nanos}", std::process::id()))
}

fn start_axod(directory: &std::path::Path, socket: &std::path::Path) -> ChildGuard {
    let fixture_pi = std::env::var_os("AXO_TEST_PI_EXECUTABLE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/pi-fixture.sh")
        });
    start_axod_with_pi(
        directory,
        socket,
        &std::fs::canonicalize(fixture_pi).expect("declared Pi fixture executable"),
    )
}

fn start_axod_with_pi(
    directory: &std::path::Path,
    socket: &std::path::Path,
    pi: &std::path::Path,
) -> ChildGuard {
    std::fs::create_dir_all(directory).unwrap();
    let child = Command::new(axod_binary())
        .env("AXO_PI_EXECUTABLE", pi)
        .arg("--socket")
        .arg(socket)
        .arg("--server-dir")
        .arg(directory)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    ChildGuard(child)
}

fn rpc(socket: &std::path::Path, method: &str) -> Value {
    rpc_with_params(socket, method, json!({}))
}

fn rpc_with_params(socket: &std::path::Path, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(socket).unwrap_or_else(|error| {
        let log_path = socket.parent().unwrap().join("server/stderr.log");
        let log = std::fs::read_to_string(log_path).unwrap_or_default();
        panic!("daemon socket should accept connections: {error}\naxod log:\n{log}")
    });
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });
    writeln!(stream, "{request}").unwrap();
    let mut response = String::new();
    BufReader::new(stream)
        .read_line(&mut response)
        .unwrap_or_else(|error| panic!("RPC {method} did not respond before its timeout: {error}"));
    serde_json::from_str(&response).unwrap()
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> std::process::ExitStatus {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("external process did not exit within {timeout:?}");
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn wait_for_socket(socket: &std::path::Path, child: &mut ChildGuard) {
    let deadline = Instant::now() + READY_WAIT;
    loop {
        if UnixStream::connect(socket).is_ok() {
            return;
        }
        if let Some(status) = child.0.try_wait().unwrap() {
            let log_path = socket.parent().unwrap().join("server/stderr.log");
            let log = std::fs::read_to_string(log_path).unwrap_or_default();
            panic!("axod exited before listening with {status}: {log}");
        }
        assert!(
            Instant::now() < deadline,
            "daemon did not create its socket"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

fn open_shell(shell: &Value) -> (UnixStream, OwnedFd) {
    let mut control = UnixStream::connect(shell["attachSocketPath"].as_str().unwrap()).unwrap();
    control
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    control
        .set_write_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    writeln!(control, "{}", shell["id"].as_i64().unwrap()).unwrap();
    // Attach protocol v2: header, PTY descriptor, then replay and live output on the socket.
    let mut replay_length = [0_u8; std::mem::size_of::<u64>()];
    control.read_exact(&mut replay_length).unwrap();
    assert_ne!(
        u64::from_be_bytes(replay_length),
        u64::MAX,
        "attach was rejected"
    );

    let mut byte = 0_u8;
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    let control_size = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let mut control_buffer = vec![0_usize; control_size.div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: zeroed msghdr is a valid starting point before its fields are initialized.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control_buffer.as_mut_ptr().cast();
    message.msg_controllen = control_size as _;

    // SAFETY: message references writable byte and control buffers of the advertised sizes.
    let received = unsafe { libc::recvmsg(control.as_raw_fd(), &mut message, 0) };
    assert_eq!(
        received, 1,
        "attach handshake should return one byte and one descriptor"
    );
    assert_eq!(byte, b'1');

    // SAFETY: recvmsg returned a control message containing one SCM_RIGHTS descriptor.
    let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    assert!(
        !header.is_null(),
        "attach response should include a control message"
    );
    assert_eq!(unsafe { (*header).cmsg_level }, libc::SOL_SOCKET);
    assert_eq!(unsafe { (*header).cmsg_type }, libc::SCM_RIGHTS);
    // SAFETY: the validated ancillary message contains a single raw descriptor.
    let master = unsafe { std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<RawFd>()) };
    // SAFETY: recvmsg transferred ownership of this descriptor to the caller.
    (control, unsafe { OwnedFd::from_raw_fd(master) })
}

fn write_pty(master: RawFd, input: &[u8]) {
    let mut remaining = input;
    let deadline = Instant::now() + Duration::from_secs(3);
    while !remaining.is_empty() {
        let mut descriptor = libc::pollfd {
            fd: master,
            events: libc::POLLOUT,
            revents: 0,
        };
        // SAFETY: descriptor is a valid one-element poll array.
        let ready = unsafe { libc::poll(&mut descriptor, 1, 100) };
        if ready == 0 {
            assert!(
                Instant::now() < deadline,
                "timed out waiting to write to PTY"
            );
            continue;
        }
        assert!(
            ready > 0,
            "PTY poll failed: {}",
            std::io::Error::last_os_error()
        );
        // SAFETY: remaining contains initialized bytes and master is an open PTY descriptor.
        let written = unsafe { libc::write(master, remaining.as_ptr().cast(), remaining.len()) };
        if written == -1 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::WouldBlock {
                assert!(Instant::now() < deadline, "timed out writing to PTY");
                continue;
            }
            panic!("PTY write failed: {error}");
        }
        remaining = &remaining[written as usize..];
    }
}

/// Reads an attachment's output stream (never the PTY master, which Axod's pump owns).
fn stream_contains(stream: &UnixStream, needle: &[u8], timeout: Duration) -> bool {
    let master = stream.as_raw_fd();
    let deadline = Instant::now() + timeout;
    let mut received = Vec::new();
    while Instant::now() < deadline {
        let mut descriptor = libc::pollfd {
            fd: master,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: descriptor is a valid one-element poll array.
        let ready = unsafe { libc::poll(&mut descriptor, 1, 100) };
        if ready <= 0 {
            continue;
        }
        let mut bytes = [0_u8; 1024];
        // SAFETY: bytes is writable and master is open.
        let count = unsafe { libc::read(master, bytes.as_mut_ptr().cast(), bytes.len()) };
        if count > 0 {
            // Scan only the new bytes (and a needle's worth before), not all output again.
            let start = received.len().saturating_sub(needle.len() - 1);
            received.extend_from_slice(&bytes[..count as usize]);
            if received[start..]
                .windows(needle.len())
                .any(|window| window == needle)
            {
                return true;
            }
        }
    }
    false
}

fn start_terminal_attach(attach_socket: &str, shell_id: i64) -> Child {
    Command::new(axod_binary())
        .arg("terminal-attach")
        .arg("--attach-socket")
        .arg(attach_socket)
        .arg("--shell-id")
        .arg(shell_id.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("axod terminal-attach should start")
}

fn output_channel(mut stdout: ChildStdout) -> Receiver<Vec<u8>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match stdout.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(count) => {
                    if sender.send(buffer[..count].to_vec()).is_err() {
                        return;
                    }
                }
            }
        }
    });
    receiver
}

fn output_contains(receiver: &Receiver<Vec<u8>>, needle: &[u8], timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    let mut output = Vec::new();
    while Instant::now() < deadline {
        match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(chunk) => {
                // Scan only what could newly contain the needle: a replay of a large shell
                // history arrives in hundreds of chunks, and rescanning everything each time
                // was quadratic enough to outlast the timeout on a loaded machine.
                let start = output.len().saturating_sub(needle.len() - 1);
                output.extend_from_slice(&chunk);
                if output[start..]
                    .windows(needle.len())
                    .any(|window| window == needle)
                {
                    return true;
                }
            }
            Err(_) => return false,
        }
    }
    false
}

fn active_sessions(socket: &std::path::Path) -> Vec<Value> {
    rpc(socket, "axo.session.list")["result"]["sessions"]
        .as_array()
        .unwrap()
        .clone()
}

fn create_session(socket: &std::path::Path) -> Value {
    rpc(socket, "axo.session.create")["result"].clone()
}

/// A Session's pane with `role`; every new Session has a Pi pane and a terminal beside it.
fn pane_with_role<'a>(session: &'a Value, role: &str) -> &'a Value {
    session["shells"]
        .as_array()
        .unwrap()
        .iter()
        .find(|shell| shell["role"] == role)
        .unwrap_or_else(|| panic!("Session has no {role} pane: {session}"))
}

fn terminal_shell(session: &Value) -> &Value {
    pane_with_role(session, "terminal")
}

#[test]
fn terminal_attach_subcommand_bridges_input_and_output() {
    let root = unique_test_directory("axoa");
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session = create_session(&socket);
    let shell = terminal_shell(&session);
    let mut process = Command::new(axod_binary())
        .arg("terminal-attach")
        .arg("--attach-socket")
        .arg(shell["attachSocketPath"].as_str().unwrap())
        .arg("--shell-id")
        .arg(shell["id"].as_i64().unwrap().to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("axod terminal-attach should start");
    let mut stdin = process.stdin.take().unwrap();
    let mut stdout = process.stdout.take().unwrap();
    let output_reader = thread::spawn(move || {
        let mut output = String::new();
        std::io::Read::read_to_string(&mut stdout, &mut output).unwrap();
        output
    });

    writeln!(stdin, "printf 'AXO_TERMINAL_ATTACH_OK\\n'; exit").unwrap();
    drop(stdin);
    let status = wait_for_exit(&mut process, READY_WAIT);
    assert!(status.success(), "terminal-attach exited with {status}");
    let output = output_reader
        .join()
        .expect("PTY output reader should finish when the shell exits");
    assert!(
        output.contains("AXO_TERMINAL_ATTACH_OK"),
        "attached PTY output did not contain the marker: {output:?}"
    );

    daemon.stop();
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn terminal_attachments_share_output_and_shells_never_stall_unattached() {
    let root = unique_test_directory("axoa");
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session = create_session(&socket);
    let session_id = session["id"].as_str().unwrap().to_owned();
    let shell = terminal_shell(&session);
    let shell_id = shell["id"].as_i64().unwrap();
    let attach_socket = shell["attachSocketPath"].as_str().unwrap();

    // Two concurrent attachments both receive the replay and every live byte.
    let mut first = ChildGuard(start_terminal_attach(attach_socket, shell_id));
    let first_output = output_channel(first.0.stdout.take().unwrap());
    writeln!(
        first.0.stdin.as_mut().unwrap(),
        "printf '%s%s\\n' AXO_REPLAY_ SCREEN_9971"
    )
    .unwrap();
    assert!(output_contains(
        &first_output,
        b"AXO_REPLAY_SCREEN_9971",
        READY_WAIT,
    ));
    let mut second = ChildGuard(start_terminal_attach(attach_socket, shell_id));
    let second_output = output_channel(second.0.stdout.take().unwrap());
    assert!(
        output_contains(&second_output, b"AXO_REPLAY_SCREEN_9971", READY_WAIT,),
        "a concurrent attachment should replay earlier output"
    );
    writeln!(
        first.0.stdin.as_mut().unwrap(),
        "printf '%s%s\\n' AXO_SHARED_ LIVE_4412"
    )
    .unwrap();
    for output in [&first_output, &second_output] {
        assert!(output_contains(output, b"AXO_SHARED_LIVE_4412", READY_WAIT,));
    }
    first.0.kill().unwrap();
    let _ = wait_for_exit(&mut first.0, Duration::from_secs(3));
    second.0.kill().unwrap();
    let _ = wait_for_exit(&mut second.0, Duration::from_secs(3));

    // With nothing attached, far more output than a PTY buffer holds must not block the shell.
    let command = b"seq 1 100000 >/dev/tty; printf '%s%s\\n' AXO_UNATTACHED_ DONE_5521\n";
    let input = rpc_with_params(
        &socket,
        "axo.terminal.input",
        json!({
            "sessionId": session_id,
            "shellId": shell_id,
            "sequence": 0,
            "data": encode_base64(command),
        }),
    );
    assert_eq!(input["result"]["accepted"], true, "{input}");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut third = ChildGuard(start_terminal_attach(attach_socket, shell_id));
        let third_output = output_channel(third.0.stdout.take().unwrap());
        let finished = output_contains(
            &third_output,
            b"AXO_UNATTACHED_DONE_5521",
            Duration::from_millis(500),
        );
        third.0.kill().unwrap();
        let _ = wait_for_exit(&mut third.0, Duration::from_secs(3));
        if finished {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "an unattached shell stalled on PTY output"
        );
    }

    daemon.stop();
    let _ = std::fs::remove_dir_all(root);
}

fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::new();
    for chunk in bytes.chunks(3) {
        let value = chunk
            .iter()
            .enumerate()
            .fold(0_u32, |value, (index, byte)| {
                value | (u32::from(*byte) << (16 - 8 * index))
            });
        for index in 0..4 {
            if index <= chunk.len() {
                encoded.push(ALPHABET[(value >> (18 - 6 * index) & 0x3f) as usize] as char);
            } else {
                encoded.push('=');
            }
        }
    }
    encoded
}

#[test]
fn local_protocol_streams_events_and_controls_the_pty() {
    let root = unique_test_directory("axo-p");
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let session = create_session(&socket);
    let session_id = session["id"].as_str().unwrap().to_owned();
    let shell = terminal_shell(&session);
    let shell_id = shell["id"].as_i64().unwrap();
    let subscription = rpc_with_params(
        &socket,
        "axo.session.subscribe",
        json!({ "sessionId": session_id }),
    )["result"]["subscriptionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let initial = rpc_with_params(
        &socket,
        "axo.session.events.next",
        json!({ "subscriptionId": subscription, "timeoutMs": 1000 }),
    );
    assert_eq!(initial["result"]["event"]["type"], "session.snapshot");
    assert_eq!(initial["result"]["event"]["session"]["id"], session_id);

    let mut attach = ChildGuard(start_terminal_attach(
        shell["attachSocketPath"].as_str().unwrap(),
        shell_id,
    ));
    let output = output_channel(attach.0.stdout.take().unwrap());
    let attach_deadline = Instant::now() + READY_WAIT;
    loop {
        let event = rpc_with_params(
            &socket,
            "axo.session.events.next",
            json!({ "subscriptionId": subscription, "timeoutMs": 500 }),
        )["result"]["event"]
            .clone();
        if event["type"] == "shell.activity" && event["activity"] == "attached" {
            break;
        }
        assert!(
            Instant::now() < attach_deadline,
            "PTY attachment event was not delivered"
        );
    }

    let resize = rpc_with_params(
        &socket,
        "axo.terminal.resize",
        json!({ "sessionId": session_id, "shellId": shell_id, "rows": 42, "columns": 120 }),
    );
    assert_eq!(resize["result"]["accepted"], true);
    let command = rpc_with_params(
        &socket,
        "axo.terminal.input",
        json!({
            "sessionId": session_id,
            "shellId": shell_id,
            "sequence": 0,
            "data": "ZWNobyBBWE9fUkVNT1RFX0lOUFVUX09LCg=="
        }),
    );
    assert_eq!(command["result"]["accepted"], true);
    let duplicate = rpc_with_params(
        &socket,
        "axo.terminal.input",
        json!({
            "sessionId": session_id,
            "shellId": shell_id,
            "sequence": 0,
            "data": "ZWNobyBBWE9fUkVNT1RFX0lOUFVUX09LCg=="
        }),
    );
    assert_eq!(duplicate["result"]["accepted"], true);
    let out_of_order = rpc_with_params(
        &socket,
        "axo.terminal.input",
        json!({
            "sessionId": session_id,
            "shellId": shell_id,
            "sequence": 2,
            "data": "ZWNobyBBWE9fUkVNT1RFX0lOUFVUX09LCg=="
        }),
    );
    assert_eq!(out_of_order["error"]["code"], -32602);
    assert!(output_contains(&output, b"AXO_REMOTE_INPUT_OK", READY_WAIT));

    let event_deadline = Instant::now() + READY_WAIT;
    let mut output_event_seen = false;
    while Instant::now() < event_deadline {
        let event = rpc_with_params(
            &socket,
            "axo.session.events.next",
            json!({ "subscriptionId": subscription, "timeoutMs": 500 }),
        )["result"]["event"]
            .clone();
        if event["type"] == "terminal.output"
            && event["sessionId"] == session_id
            && event["shellId"] == shell_id
            && !event["data"].as_str().unwrap_or_default().is_empty()
        {
            output_event_seen = true;
            break;
        }
    }
    assert!(
        output_event_seen,
        "terminal output must be streamed through the event API"
    );

    let shell_busy = |expected: bool| {
        let deadline = Instant::now() + READY_WAIT;
        loop {
            let result = rpc_with_params(
                &socket,
                "axo.shell.busy",
                json!({ "sessionId": session_id, "shellId": shell_id }),
            )["result"]
                .clone();
            // A login shell can briefly run its own startup commands (e.g. `mv` for history), so
            // "busy" means our `sleep` is in the foreground.
            let settled = if expected {
                result["foregroundProcess"] == "sleep"
            } else {
                result["busy"] == false
            };
            if settled {
                return result;
            }
            assert!(
                Instant::now() < deadline,
                "shell busy state never became {expected}: {result}"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let idle = shell_busy(false);
    assert!(idle["foregroundProcess"].is_null());
    for (sequence, data) in [(1, "c2xlZXAgMzAK"), (2, "Aw==")] {
        if sequence == 2 {
            let busy = shell_busy(true);
            assert_eq!(busy["foregroundProcess"], "sleep");
        }
        let accepted = rpc_with_params(
            &socket,
            "axo.terminal.input",
            json!({ "sessionId": session_id, "shellId": shell_id, "sequence": sequence, "data": data }),
        );
        assert_eq!(accepted["result"]["accepted"], true);
    }
    shell_busy(false);

    attach.stop();
    let unsubscribed = rpc_with_params(
        &socket,
        "axo.session.unsubscribe",
        json!({ "subscriptionId": subscription }),
    );
    assert_eq!(unsubscribed["result"]["unsubscribed"], true);
    daemon.stop();
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn long_polls_never_delay_unrelated_requests() {
    let root = unique_test_directory("axo-lp");
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session_id = create_session(&socket)["id"].as_str().unwrap().to_owned();

    // Regression: axod used to serve requests one at a time, so each waiting long-poll delayed
    // every other request by up to its full timeout.
    let subscriptions: Vec<String> = (0..16)
        .map(|_| {
            let subscription = rpc_with_params(
                &socket,
                "axo.session.subscribe",
                json!({ "includeTerminalOutput": false }),
            )["result"]["subscriptionId"]
                .as_str()
                .unwrap()
                .to_owned();
            // Drain the initial snapshots so the next poll really waits.
            rpc_with_params(
                &socket,
                "axo.session.events.next",
                json!({ "subscriptionId": subscription, "timeoutMs": 1, "maxEvents": 256 }),
            );
            subscription
        })
        .collect();
    // Served one at a time, a request waits behind at least one whole 2.5 s poll; served
    // concurrently it takes well under the 1 s allowed even on a loaded machine (up to ~0.5 s
    // seen). Each poll outlasts the checks (200 ms + two requests under 1 s), so all 64 are
    // still waiting while they run.
    let pollers: Vec<_> = (0..64)
        .map(|index| {
            let socket = socket.clone();
            let subscription = subscriptions[index % subscriptions.len()].clone();
            std::thread::spawn(move || {
                rpc_with_params(
                    &socket,
                    "axo.session.events.next",
                    json!({ "subscriptionId": subscription, "timeoutMs": 2500, "maxEvents": 256 }),
                )
            })
        })
        .collect();
    std::thread::sleep(Duration::from_millis(200));

    for method in ["axo.session.list", "axo.shell.create"] {
        let started = Instant::now();
        let response = if method == "axo.shell.create" {
            rpc_with_params(&socket, method, json!({ "sessionId": session_id }))
        } else {
            rpc_with_params(&socket, method, json!({}))
        };
        let elapsed = started.elapsed();
        assert!(
            response.get("result").is_some(),
            "{method} failed: {response}"
        );
        assert!(
            elapsed < Duration::from_secs(1),
            "{method} waited {elapsed:?} behind long-polls"
        );
    }
    for poller in pollers {
        let response = poller.join().unwrap();
        assert!(response["result"]["events"].is_array(), "{response}");
    }
    daemon.stop();
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sharing_a_conversation_needs_a_mac_linked_to_its_axo_account() {
    let directory = unique_test_directory("axo-share-unlinked");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    std::fs::create_dir_all(&directory).unwrap();

    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let negotiated = rpc_with_params(
        &socket,
        "axo.protocol.negotiate",
        json!({ "protocolVersion": 2 }),
    );
    let methods = negotiated["result"]["methods"].as_array().unwrap();
    assert!(methods.iter().any(|method| method == "axo.session.share"));

    let malformed = rpc_with_params(&socket, "axo.session.share", json!({}));
    assert_eq!(malformed["error"]["code"], -32602);

    let unlinked = rpc_with_params(
        &socket,
        "axo.session.share",
        json!({ "snapshot": { "version": 1 } }),
    );
    assert_eq!(unlinked["error"]["code"], -32603);
    let message = unlinked["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("not connected to its Axo account"),
        "{message}"
    );

    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn workspace_creation_validates_name_and_existing_directory_without_a_bookmark() {
    let directory = unique_test_directory("axo-workspace-error");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    std::fs::create_dir_all(&directory).unwrap();

    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let invalid_name = rpc_with_params(
        &socket,
        "axo.workspace.create",
        json!({ "name": "", "directoryPath": directory }),
    );
    assert_eq!(invalid_name["error"]["code"], -32602);
    assert_eq!(
        invalid_name["error"]["message"],
        "Workspace name is invalid"
    );

    let missing_directory = rpc_with_params(
        &socket,
        "axo.workspace.create",
        json!({
            "name": "Workspace",
            "directoryPath": directory.join("missing"),
        }),
    );
    assert_eq!(missing_directory["error"]["code"], -32602);
    assert_eq!(
        missing_directory["error"]["message"],
        "Workspace directory no longer exists or is unavailable"
    );

    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn stores_validated_allowlisted_configuration_for_future_processes() {
    let directory = unique_test_directory("axo-config");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    std::fs::create_dir_all(&directory).unwrap();

    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let default_agent =
        rpc_with_params(&socket, "axo.config.get", json!({ "key": "agent.command" }));
    assert_eq!(default_agent["result"]["value"], "pi");
    let default_shell =
        rpc_with_params(&socket, "axo.config.get", json!({ "key": "shell.command" }));
    let default_shell_value = default_shell["result"]["value"]
        .as_str()
        .expect("default shell command should be a string");
    assert!(!default_shell_value.is_empty());
    if let Ok(current_shell) = std::env::var("SHELL") {
        let current_shell_path = std::path::Path::new(&current_shell);
        if current_shell_path.is_absolute() && current_shell_path.is_file() {
            assert_eq!(default_shell_value, current_shell);
        }
    }

    let configured_agent = "pi --model 'claude-sonnet-4-5'";
    let saved_agent = rpc_with_params(
        &socket,
        "axo.config.set",
        json!({ "key": "agent.command", "value": configured_agent }),
    );
    assert_eq!(saved_agent["result"]["value"], configured_agent);

    let configured_shell = "/bin/bash --noprofile";
    let saved_shell = rpc_with_params(
        &socket,
        "axo.config.set",
        json!({ "key": "shell.command", "value": configured_shell }),
    );
    assert_eq!(saved_shell["result"]["value"], configured_shell);
    let invalid_shell = rpc_with_params(
        &socket,
        "axo.config.set",
        json!({ "key": "shell.command", "value": "/bin/zsh 'unterminated" }),
    );
    assert_eq!(invalid_shell["error"]["code"], -32602);

    for invalid_agent in [
        "pi --session /tmp/other",
        "pi --continue",
        "pi --no-extensions",
        "pi --model 'unterminated",
        "",
    ] {
        let invalid = rpc_with_params(
            &socket,
            "axo.config.set",
            json!({ "key": "agent.command", "value": invalid_agent }),
        );
        assert_eq!(invalid["error"]["code"], -32602);
    }
    let unknown_key = rpc_with_params(
        &socket,
        "axo.config.get",
        json!({ "key": "arbitrary.database.key" }),
    );
    assert_eq!(unknown_key["error"]["code"], -32602);

    daemon.stop();
    let mut restarted = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut restarted);
    assert_eq!(
        rpc_with_params(&socket, "axo.config.get", json!({ "key": "agent.command" }),)["result"]["value"],
        configured_agent
    );
    assert_eq!(
        rpc_with_params(&socket, "axo.config.get", json!({ "key": "shell.command" }),)["result"]["value"],
        configured_shell
    );
    restarted.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn axod_starts_when_pi_cannot_launch() {
    let directory = unique_test_directory("axo-no-pi");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    std::fs::create_dir_all(&directory).unwrap();
    let broken_pi = directory.join("broken-pi");
    std::fs::write(&broken_pi, "not executable").unwrap();

    let mut daemon = start_axod_with_pi(&server_directory, &socket, &broken_pi);
    wait_for_socket(&socket, &mut daemon);
    assert_eq!(
        rpc(&socket, "axo.daemon.health")["result"]["status"],
        "running"
    );
    let workspaces = rpc(&socket, "axo.workspace.list")["result"]["workspaces"].clone();
    assert_eq!(
        workspaces[0]["home"], true,
        "Home exists even without a Session: {workspaces}"
    );
    assert!(active_sessions(&socket).is_empty());

    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

/// RFD0015: what a Session's agent uses to see and drive Axo.
#[test]
fn agents_can_find_transcripts_drive_panes_and_prompt_sessions() {
    let directory = unique_test_directory("axo-agents");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    std::fs::create_dir_all(&directory).unwrap();
    // A Pi that records its environment, then waits like the usual fixture.
    let environment = directory.join("pi-environment");
    let pi = directory.join("recording-pi");
    std::fs::write(
        &pi,
        format!(
            "#!/bin/sh\nenv > {}\nexec /bin/sleep 60\n",
            environment.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&pi, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();

    let mut cleanup = SessionProcessCleanup::default();
    let mut daemon = start_axod_with_pi(&server_directory, &socket, &pi);
    wait_for_socket(&socket, &mut daemon);
    let session = active_sessions(&socket).remove(0);
    cleanup.track(&session);

    // Pi is told where Axod listens and which axod to run for its MCP server.
    let deadline = Instant::now() + READY_WAIT;
    while !std::fs::read_to_string(&environment).is_ok_and(|text| text.contains("AXOD=")) {
        assert!(Instant::now() < deadline, "Pi did not start");
        thread::sleep(Duration::from_millis(20));
    }
    let recorded = std::fs::read_to_string(&environment).unwrap();
    assert!(
        recorded.contains(&format!("AXO_SOCKET={}\n", socket.display())),
        "{recorded}"
    );

    // Typing into the terminal pane and reading its screen back as plain text.
    let terminal = terminal_shell(&session);
    let ids = json!({ "sessionId": session["id"], "shellId": terminal["id"] });
    let written = rpc_with_params(
        &socket,
        "axo.terminal.write",
        json!({ "sessionId": session["id"], "shellId": terminal["id"], "text": "echo axo-$((6*7))\r" }),
    );
    assert_eq!(written["result"]["accepted"], true, "{written}");
    let deadline = Instant::now() + READY_WAIT;
    let screen = loop {
        let screen = rpc_with_params(&socket, "axo.terminal.screen", ids.clone());
        let text = screen["result"]["text"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if text.contains("axo-42") || Instant::now() > deadline {
            break text;
        }
        thread::sleep(Duration::from_millis(50));
    };
    assert!(
        screen.contains("axo-42") && !screen.contains('\x1b'),
        "{screen:?}"
    );
    let one_line = rpc_with_params(
        &socket,
        "axo.terminal.screen",
        json!({ "sessionId": session["id"], "shellId": terminal["id"], "lines": 1 }),
    );
    assert!(
        !one_line["result"]["text"].as_str().unwrap().contains('\n'),
        "{one_line}"
    );

    // A prompt for a Pi whose bridge never binds waits for it, and says so.
    let prompted = rpc_with_params(
        &socket,
        "axo.session.prompt",
        json!({ "sessionId": session["id"], "text": "hello", "fromSessionId": session["id"] }),
    );
    assert_eq!(
        prompted["result"],
        json!({ "accepted": true, "depth": 1, "queued": true })
    );
    let empty = rpc_with_params(
        &socket,
        "axo.session.prompt",
        json!({ "sessionId": session["id"], "text": " " }),
    );
    assert_eq!(empty["error"]["code"], -32602, "{empty}");

    // Archived Sessions stay findable, with their transcript paths.
    let created = create_session(&socket);
    cleanup.track(&created);
    let closed = rpc_with_params(
        &socket,
        "axo.session.close",
        json!({ "sessionId": created["id"] }),
    );
    assert!(closed["error"].is_null(), "{closed}");
    let catalog = rpc(&socket, "axo.session.catalog")["result"].clone();
    assert!(
        catalog["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|open| open["id"] == session["id"]),
        "{catalog}"
    );
    let archived = &catalog["archived"][0];
    assert_eq!(archived["id"], created["id"], "{catalog}");
    assert_eq!(archived["piSessionFile"], created["piSessionFile"]);

    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn axod_mcp_serves_one_sessions_agent_over_stdio() {
    let directory = unique_test_directory("axo-mcp");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    let mut cleanup = SessionProcessCleanup::default();
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session = active_sessions(&socket).remove(0);
    cleanup.track(&session);

    // An unknown Session is refused at startup.
    let refused = Command::new(axod_binary())
        .arg("mcp")
        .env("AXO_SOCKET", &socket)
        .env("AXO_SESSION_ID", "00000000-0000-4000-8000-000000000000")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!refused.status.success());

    let mut mcp = Command::new(axod_binary())
        .arg("mcp")
        .env("AXO_SOCKET", &socket)
        .env("AXO_SESSION_ID", session["id"].as_str().unwrap())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = mcp.stdin.take().unwrap();
    let mut output = BufReader::new(mcp.stdout.take().unwrap());
    let mut next_id = 0;
    let mut request = |method: &str, params: Value| -> Value {
        next_id += 1;
        let message =
            json!({ "jsonrpc": "2.0", "id": next_id, "method": method, "params": params });
        writeln!(input, "{message}").unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], next_id, "{response}");
        response["result"].clone()
    };

    let initialized = request(
        "initialize",
        json!({ "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": { "name": "test", "version": "1" } }),
    );
    assert!(
        initialized["instructions"]
            .as_str()
            .unwrap()
            .contains("piSessionFile")
    );
    let tools = request("tools/list", json!({}));
    let names: Vec<&str> = tools["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    for name in [
        "whoami",
        "session_catalog",
        "session_prompt",
        "terminal_write",
        "terminal_screen",
    ] {
        assert!(names.contains(&name), "{names:?}");
    }

    let call = |request: &mut dyn FnMut(&str, Value) -> Value, name: &str, arguments: Value| {
        let result = request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        assert_ne!(result["isError"], true, "{name}: {result}");
        result["structuredContent"].clone()
    };
    let me = call(&mut request, "whoami", json!({}));
    assert_eq!(me["sessionId"], session["id"]);
    assert_eq!(me["workspaceId"], session["workspaceId"]);

    // "self" reaches this Session's own terminal pane.
    let terminal = terminal_shell(&session)["id"].clone();
    call(
        &mut request,
        "terminal_write",
        json!({ "sessionId": "self", "shellId": terminal, "text": "echo mcp-$((40+2))\r" }),
    );
    let deadline = Instant::now() + READY_WAIT;
    loop {
        let screen = call(
            &mut request,
            "terminal_screen",
            json!({ "sessionId": "self", "shellId": terminal }),
        );
        if screen["text"].as_str().unwrap().contains("mcp-42") {
            break;
        }
        assert!(Instant::now() < deadline, "{screen}");
        thread::sleep(Duration::from_millis(50));
    }

    // A prompt always names this Session as its sender, so it counts toward the chain.
    let prompted = call(
        &mut request,
        "session_prompt",
        json!({ "sessionId": "self", "text": "remind me" }),
    );
    assert_eq!(prompted["depth"], 1, "{prompted}");
    let refused = request(
        "tools/call",
        json!({ "name": "session_prompt", "arguments": { "sessionId": "self", "text": "" } }),
    );
    assert_eq!(refused["isError"], true, "{refused}");

    drop(input);
    assert!(wait_for_exit(&mut mcp, READY_WAIT).success());
    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn closed_sessions_reopen_most_recent_first_with_the_panes_they_closed_with() {
    let directory = unique_test_directory("axo-reopen");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    let mut cleanup = SessionProcessCleanup::default();
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let nothing = rpc(&socket, "axo.session.reopen");
    assert_eq!(nothing["error"]["code"], -32005, "{nothing}");

    let first = active_sessions(&socket).remove(0);
    let second = create_session(&socket);
    cleanup.track(&first);
    cleanup.track(&second);

    // A terminal pane closed on its own stays closed when its Session comes back.
    let extra = rpc_with_params(
        &socket,
        "axo.shell.create",
        json!({ "sessionId": first["id"] }),
    )["result"]
        .clone();
    let closed_extra = rpc_with_params(
        &socket,
        "axo.shell.close",
        json!({ "sessionId": first["id"], "shellId": extra["id"] }),
    );
    assert!(closed_extra["error"].is_null(), "{closed_extra}");

    // Closing a Session's Pi pane (⌘W on it) closes the Session.
    for session in [&first, &second] {
        let closed = rpc_with_params(
            &socket,
            "axo.shell.close",
            json!({ "sessionId": session["id"], "shellId": pane_with_role(session, "pi")["id"] }),
        );
        assert_eq!(
            closed["result"]["archivedSessionId"], session["id"],
            "{closed}"
        );
    }

    // The most recently closed comes back first, then the one before it.
    for expected in [&second, &first] {
        let reopened = rpc(&socket, "axo.session.reopen")["result"].clone();
        cleanup.track(&reopened);
        assert_eq!(reopened["id"], expected["id"], "{reopened}");
        let mut pane_ids: Vec<_> = reopened["shells"]
            .as_array()
            .unwrap()
            .iter()
            .map(|shell| shell["id"].clone())
            .collect();
        let mut expected_ids: Vec<_> = expected["shells"]
            .as_array()
            .unwrap()
            .iter()
            .map(|shell| shell["id"].clone())
            .collect();
        pane_ids.sort_by_key(|id| id.as_i64());
        expected_ids.sort_by_key(|id| id.as_i64());
        assert_eq!(pane_ids, expected_ids, "{reopened}");
    }
    let open_ids: Vec<_> = active_sessions(&socket)
        .iter()
        .map(|session| session["id"].clone())
        .collect();
    assert!(open_ids.contains(&first["id"]) && open_ids.contains(&second["id"]));

    // Pi resumes in the reopened Session.
    let deadline = Instant::now() + READY_WAIT;
    loop {
        let sessions = active_sessions(&socket);
        let reopened = sessions
            .iter()
            .find(|session| session["id"] == first["id"])
            .unwrap();
        if pane_with_role(reopened, "pi")["available"] == true {
            cleanup.track(reopened);
            break;
        }
        assert!(Instant::now() < deadline, "Pi did not resume: {reopened}");
        thread::sleep(Duration::from_millis(50));
    }

    let exhausted = rpc(&socket, "axo.session.reopen");
    assert_eq!(exhausted["error"]["code"], -32005, "{exhausted}");
}

#[test]
fn the_home_workspace_always_has_a_session_and_cannot_be_archived() {
    let directory = unique_test_directory("axo-home-workspace");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");

    let mut cleanup = SessionProcessCleanup::default();
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let workspaces = rpc(&socket, "axo.workspace.list")["result"]["workspaces"].clone();
    let home = workspaces
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "Home")
        .unwrap_or_else(|| panic!("axod should create the Home Workspace: {workspaces}"))
        .clone();
    assert_eq!(home["directoryPath"], std::env::var("HOME").unwrap());
    assert_eq!(home["home"], true);
    let sessions = active_sessions(&socket);
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["workspaceId"], home["workspaceId"]);
    cleanup.track(&sessions[0]);

    // A Session created outside any other Workspace goes to Home.
    let created = create_session(&socket);
    cleanup.track(&created);
    assert_eq!(created["workspaceId"], home["workspaceId"]);
    assert!(
        active_sessions(&socket)
            .iter()
            .all(|session| !session["workspaceId"].is_null())
    );

    for session in [&sessions[0], &created] {
        let close = rpc_with_params(
            &socket,
            "axo.session.close",
            json!({ "sessionId": session["id"] }),
        );
        if let Some(replacement) = close["result"]["replacement"].as_object() {
            cleanup.track(&Value::Object(replacement.clone()));
        }
    }
    let remaining = active_sessions(&socket);
    assert_eq!(
        remaining.len(),
        1,
        "closing Home's last Session replaces it"
    );
    assert_eq!(remaining[0]["workspaceId"], home["workspaceId"]);

    let archive = rpc_with_params(
        &socket,
        "axo.workspace.archive",
        json!({ "workspaceId": home["workspaceId"] }),
    );
    assert_eq!(archive["error"]["code"], -32602, "{archive}");
    assert_eq!(active_sessions(&socket).len(), 1);

    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn daemon_starts_with_and_restores_a_default_pty_session_after_restart() {
    let mut cleanup = SessionProcessCleanup::default();
    let directory = unique_test_directory("axo-e2e");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");

    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let negotiated = rpc_with_params(
        &socket,
        "axo.protocol.negotiate",
        json!({ "protocolVersion": 2 }),
    );
    assert_eq!(negotiated["result"]["protocolVersion"], 2);
    for method in [
        "axo.session.subscribe",
        "axo.session.events.next",
        "axo.session.unsubscribe",
        "axo.session.pi.restart.force.v2",
        "axo.session.pi.restart.auto.v1",
        "axo.workspace.list",
        "axo.workspace.create",
        "axo.workspace.rename",
        "axo.workspace.archive",
        "axo.workspace.session.create",
        "axo.session.rename",
        "axo.shell.busy",
        "axo.terminal.input",
        "axo.terminal.resize",
        "axo.client.viewport.set",
    ] {
        assert!(
            negotiated["result"]["methods"]
                .as_array()
                .unwrap()
                .iter()
                .any(|advertised| advertised == method),
            "axod should advertise {method}"
        );
    }
    let unsupported = rpc_with_params(
        &socket,
        "axo.protocol.negotiate",
        json!({ "protocolVersion": 99 }),
    );
    assert_eq!(unsupported["error"]["code"], -32602);

    let health = rpc(&socket, "axo.daemon.health");
    assert_eq!(health["result"]["status"], "running");
    assert!(health["result"]["version"].as_str().is_some());
    assert!(health["result"]["buildNumber"].as_u64().is_some());

    let home = std::env::var("HOME").unwrap();
    let sessions = active_sessions(&socket);
    assert_eq!(sessions.len(), 1, "axod should start one default Session");
    let session = sessions[0].clone();
    cleanup.track(&session);
    assert_eq!(session["initialPwd"], home);
    let home_workspace_id = session["workspaceId"].clone();
    assert!(
        home_workspace_id.is_string(),
        "the default Session is in Home"
    );
    assert_eq!(
        session["shells"].as_array().unwrap().len(),
        2,
        "Pi and a terminal"
    );
    let pi_shell_id = pane_with_role(&session, "pi")["id"].as_i64().unwrap();
    let shell = terminal_shell(&session);
    assert_eq!(shell["initialPwd"], home);
    assert!(shell["ptyDevice"].as_str().unwrap().starts_with("/dev/"));
    assert!(server_directory.join("axo.db").exists());

    let (_attachment, master) = open_shell(shell);
    write_pty(master.as_raw_fd(), b"printf 'AXOD_PTY_E2E_OK\\n'\n");
    assert!(
        stream_contains(&_attachment, b"AXOD_PTY_E2E_OK", READY_WAIT),
        "the attached PTY should execute commands and return their output"
    );

    let session_id = session["id"].as_str().unwrap().to_owned();
    let shell_id = shell["id"].as_i64().unwrap();
    let original_process_id = shell["processId"].as_u64().unwrap();
    let split_shell = rpc_with_params(
        &socket,
        "axo.shell.create",
        json!({ "sessionId": session_id }),
    )["result"]
        .clone();
    cleanup
        .0
        .push(split_shell["processId"].as_i64().unwrap() as libc::pid_t);
    assert_eq!(
        active_sessions(&socket)[0]["shells"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    let layout = json!({
        "kind": "split",
        "id": "7d0e6a52-3f1c-4b8e-9a2d-6c4f1e8b9a10",
        "direction": "right",
        "ratio": 0.5,
        "first": { "kind": "pane", "shellId": pi_shell_id },
        "second": {
            "kind": "split",
            "id": "02a4c161-8143-4c9a-bbf2-1a625e8b8342",
            "direction": "down",
            "ratio": 0.63,
            "first": { "kind": "pane", "shellId": shell_id },
            "second": { "kind": "pane", "shellId": split_shell["id"] },
        },
    });
    let expected_layout = layout.clone();
    let saved_layout = rpc_with_params(
        &socket,
        "axo.session.layout.set",
        json!({ "sessionId": session_id, "layout": layout }),
    );
    assert_eq!(saved_layout["result"]["saved"], true, "{saved_layout}");
    let rejected_layout = rpc_with_params(
        &socket,
        "axo.session.layout.set",
        json!({
            "sessionId": session_id,
            "layout": { "kind": "pane", "shellId": shell_id },
        }),
    );
    assert_eq!(rejected_layout["error"]["code"], -32602);
    daemon.stop();
    drop(daemon);
    drop(master);

    let mut restarted = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut restarted);
    let restored = active_sessions(&socket);
    assert_eq!(restored.len(), 1);
    assert_eq!(
        restored[0]["id"], session_id,
        "restart should keep the logical session id"
    );
    assert_eq!(
        restored[0]["layout"], expected_layout,
        "restart should restore the session pane hierarchy"
    );
    assert_eq!(restored[0]["shells"].as_array().unwrap().len(), 3);
    let restored_shell = restored[0]["shells"]
        .as_array()
        .unwrap()
        .iter()
        .find(|restored_shell| restored_shell["id"] == shell_id)
        .unwrap();
    assert_ne!(
        restored_shell["processId"].as_u64().unwrap(),
        original_process_id,
        "restart should recreate the shell process"
    );
    let restored_split_shell = restored[0]["shells"]
        .as_array()
        .unwrap()
        .iter()
        .find(|restored_shell| restored_shell["id"] == split_shell["id"])
        .unwrap();
    assert_eq!(restored[0]["initialPwd"], home);
    assert_ne!(
        restored_split_shell["processId"], split_shell["processId"],
        "restart should recreate each shell process"
    );
    cleanup.track(&restored[0]);

    let (_attachment, restored_master) = open_shell(restored_shell);
    write_pty(
        restored_master.as_raw_fd(),
        b"printf 'AXOD_RESTORED_OK\\n'\n",
    );
    assert!(stream_contains(
        &_attachment,
        b"AXOD_RESTORED_OK",
        READY_WAIT
    ));

    assert_ne!(split_shell["id"], shell_id);
    let grouped = active_sessions(&socket);
    assert_eq!(grouped.len(), 1, "a split stays in the current tab");
    assert_eq!(grouped[0]["id"], session_id);
    assert_eq!(grouped[0]["shells"].as_array().unwrap().len(), 3);

    let close_shell = rpc_with_params(
        &socket,
        "axo.shell.close",
        json!({ "sessionId": session_id, "shellId": split_shell["id"] }),
    );
    assert_eq!(close_shell["result"]["archivedShellId"], split_shell["id"]);
    assert!(close_shell["result"]["archivedSessionId"].is_null());
    assert_eq!(
        active_sessions(&socket)[0]["shells"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        active_sessions(&socket)[0]["layout"],
        json!({
            "kind": "split",
            "id": "7d0e6a52-3f1c-4b8e-9a2d-6c4f1e8b9a10",
            "direction": "right",
            "ratio": 0.5,
            "first": { "kind": "pane", "shellId": pi_shell_id },
            "second": { "kind": "pane", "shellId": shell_id },
        })
    );

    let close = rpc_with_params(
        &socket,
        "axo.session.close",
        json!({ "sessionId": session_id }),
    );
    assert_eq!(close["result"]["archivedSessionId"], session_id);
    let replacement = &close["result"]["replacement"];
    assert!(
        replacement.is_object(),
        "closing the last session creates a replacement"
    );
    cleanup.track(replacement);
    assert_ne!(replacement["id"], session_id);
    assert_eq!(replacement["initialPwd"], home);
    assert_eq!(replacement["workspaceId"], home_workspace_id);
    assert_eq!(active_sessions(&socket).len(), 1);

    let replacement_id = replacement["id"].as_str().unwrap().to_owned();
    let replacement_shell_id = replacement["shells"][0]["id"].as_i64().unwrap();
    let close_last_shell = rpc_with_params(
        &socket,
        "axo.shell.close",
        json!({ "sessionId": replacement_id, "shellId": replacement_shell_id }),
    );
    assert_eq!(
        close_last_shell["result"]["archivedSessionId"],
        replacement_id
    );
    let final_replacement = &close_last_shell["result"]["replacement"];
    assert!(final_replacement.is_object());
    cleanup.track(final_replacement);
    assert_eq!(active_sessions(&socket).len(), 1);

    restarted.stop();
    drop(restarted);
    let _ = std::fs::remove_dir_all(directory);
}

fn pty_size(master: &OwnedFd) -> (u16, u16) {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: size is writable and the descriptor is an open PTY master.
    assert_eq!(
        unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCGWINSZ, &mut size) },
        0
    );
    (size.ws_row, size.ws_col)
}

#[test]
fn new_panes_start_at_the_latest_clients_viewport_across_restarts() {
    let mut cleanup = SessionProcessCleanup::default();
    let directory = unique_test_directory("axo-vp");
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    let viewport = json!({
        "terminalArea": { "width": 1000.0, "height": 600.0 },
        "backingScale": 2.0,
        "cell": { "width": 16, "height": 34 },
        "padding": { "top": 10, "bottom": 10, "left": 2, "right": 2 },
        "dividerThickness": 1.0
    });

    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let mut invalid = viewport.clone();
    invalid["backingScale"] = json!(0);
    assert_eq!(
        rpc_with_params(&socket, "axo.client.viewport.set", invalid)["error"]["code"],
        -32602
    );
    assert_eq!(
        rpc_with_params(&socket, "axo.client.viewport.set", viewport)["result"]["accepted"],
        true
    );
    let session = create_session(&socket);
    cleanup.track(&session);
    let (_control, master) = open_shell(terminal_shell(&session));
    // 2000x1200 px minus Ghostty's scaled padding, in 16x34 px cells, halved beside Pi.
    assert_eq!(pty_size(&master), (34, 61));
    drop(daemon);

    // The viewport outlives the daemon, so panes it starts before any client connects fit too.
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session = create_session(&socket);
    cleanup.track(&session);
    let (_control, master) = open_shell(terminal_shell(&session));
    assert_eq!(pty_size(&master), (34, 61));
}
