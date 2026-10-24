use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

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
        for process_id in &self.0 {
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

fn start_axod(directory: &std::path::Path, socket: &std::path::Path) -> ChildGuard {
    std::fs::create_dir_all(directory).unwrap();
    let fixture_pi = std::env::var_os("AXO_TEST_PI_EXECUTABLE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/pi-fixture.sh")
        });
    let child = Command::new(axod_binary())
        .env(
            "AXO_PI_EXECUTABLE",
            std::fs::canonicalize(fixture_pi).expect("declared Pi fixture executable"),
        )
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
    let mut stream = UnixStream::connect(socket).expect("daemon socket should accept connections");
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
    let deadline = Instant::now() + Duration::from_secs(5);
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
    let mut replay_length = [0_u8; std::mem::size_of::<u64>()];
    control.read_exact(&mut replay_length).unwrap();
    let replay_length = u64::from_be_bytes(replay_length) as usize;
    let mut replay = vec![0_u8; replay_length];
    control.read_exact(&mut replay).unwrap();

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

fn pty_contains(master: RawFd, needle: &[u8], timeout: Duration) -> bool {
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
            received.extend_from_slice(&bytes[..count as usize]);
            if received
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
                output.extend_from_slice(&chunk);
                if output.windows(needle.len()).any(|window| window == needle) {
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

#[test]
fn terminal_attach_subcommand_bridges_input_and_output() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::path::PathBuf::from("/tmp").join(format!("axoa-{}-{unique}", std::process::id()));
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session = create_session(&socket);
    let shell = &session["shells"][0];
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
    let status = wait_for_exit(&mut process, Duration::from_secs(5));
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
fn terminal_attach_replays_output_after_reconnect() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::path::PathBuf::from("/tmp").join(format!("axoa-{}-{unique}", std::process::id()));
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session = create_session(&socket);
    let shell = &session["shells"][0];
    let shell_id = shell["id"].as_i64().unwrap();
    let attach_socket = shell["attachSocketPath"].as_str().unwrap();

    let mut first = start_terminal_attach(attach_socket, shell_id);
    let first_output = output_channel(first.stdout.take().unwrap());
    writeln!(
        first.stdin.as_mut().unwrap(),
        "printf '\\033[2J\\033[H%s%s\\n' AXO_REPLAY_ SCREEN_9971; sleep 3"
    )
    .unwrap();
    let first_output_seen = output_contains(
        &first_output,
        b"AXO_REPLAY_SCREEN_9971",
        Duration::from_secs(5),
    );
    if !first_output_seen {
        eprintln!(
            "first attach logs: {}",
            std::fs::read_to_string(server_directory.join("stderr.log")).unwrap_or_default()
        );
    }
    assert!(first_output_seen);

    let mut second = start_terminal_attach(attach_socket, shell_id);
    let rejection_deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let log = std::fs::read_to_string(server_directory.join("stderr.log")).unwrap_or_default();
        if log.contains(&format!(
            "event=session.attach_rejected shell_id={shell_id}"
        )) {
            break;
        }
        assert!(
            Instant::now() < rejection_deadline,
            "daemon did not reject the overlapping attachment"
        );
        thread::sleep(Duration::from_millis(20));
    }
    first.kill().unwrap();
    let _ = wait_for_exit(&mut first, Duration::from_secs(3));

    let second_output = output_channel(second.stdout.take().unwrap());
    assert!(output_contains(
        &second_output,
        b"AXO_REPLAY_SCREEN_9971",
        Duration::from_secs(5),
    ));
    second.kill().unwrap();
    let _ = wait_for_exit(&mut second, Duration::from_secs(3));

    daemon.stop();
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn local_protocol_streams_events_and_controls_the_pty() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::path::PathBuf::from("/tmp").join(format!("axo-p-{}-{unique}", std::process::id()));
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let session = create_session(&socket);
    let session_id = session["id"].as_i64().unwrap();
    let shell = &session["shells"][0];
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
    let attach_deadline = Instant::now() + Duration::from_secs(3);
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
    assert!(output_contains(
        &output,
        b"AXO_REMOTE_INPUT_OK",
        Duration::from_secs(4)
    ));

    let event_deadline = Instant::now() + Duration::from_secs(3);
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
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let result = rpc_with_params(
                &socket,
                "axo.shell.busy",
                json!({ "sessionId": session_id, "shellId": shell_id }),
            )["result"]
                .clone();
            if result["busy"] == expected {
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
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::path::PathBuf::from("/tmp").join(format!("axo-lp-{}-{unique}", std::process::id()));
    let server_directory = root.join("server");
    let socket = root.join("axod.sock");
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);
    let session_id = create_session(&socket)["id"].as_i64().unwrap();

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
    let pollers: Vec<_> = (0..64)
        .map(|index| {
            let socket = socket.clone();
            let subscription = subscriptions[index % subscriptions.len()].clone();
            std::thread::spawn(move || {
                rpc_with_params(
                    &socket,
                    "axo.session.events.next",
                    json!({ "subscriptionId": subscription, "timeoutMs": 3000, "maxEvents": 256 }),
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
        assert!(response.get("result").is_some(), "{method} failed: {response}");
        assert!(
            elapsed < Duration::from_millis(250),
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
fn workspace_creation_validates_name_and_existing_directory_without_a_bookmark() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = std::path::Path::new("/tmp").join(format!(
        "axo-workspace-error-{}-{unique}",
        std::process::id()
    ));
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
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory =
        std::path::Path::new("/tmp").join(format!("axo-config-{}-{unique}", std::process::id()));
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
fn keeps_one_standalone_session_open_while_workspaces_exist() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = std::path::Path::new("/tmp").join(format!(
        "axo-standalone-invariant-{}-{unique}",
        std::process::id()
    ));
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");
    let workspace_directory = directory.join("workspace");
    std::fs::create_dir_all(&workspace_directory).unwrap();

    let mut cleanup = SessionProcessCleanup::default();
    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let home_session = active_sessions(&socket)
        .into_iter()
        .find(|session| session["workspaceId"].is_null())
        .expect("axod should start a standalone home Session");
    cleanup.track(&home_session);

    let workspace = rpc_with_params(
        &socket,
        "axo.workspace.create",
        json!({ "name": "Invariant", "directoryPath": workspace_directory }),
    );
    assert!(workspace["result"]["session"].is_object(), "{workspace}");
    cleanup.track(&workspace["result"]["session"]);

    let close_home = rpc_with_params(
        &socket,
        "axo.session.close",
        json!({ "sessionId": home_session["id"] }),
    );
    let mut standalone_replacement = close_home["result"]["replacement"].clone();
    assert!(
        standalone_replacement.is_object(),
        "closing the final standalone Session should create a replacement even when a Workspace Session is open: {close_home}"
    );
    cleanup.track(&standalone_replacement);

    let sessions = active_sessions(&socket);
    assert_eq!(
        sessions
            .iter()
            .filter(|session| session["workspaceId"].is_null())
            .count(),
        1
    );
    assert_eq!(
        sessions
            .iter()
            .filter(|session| !session["workspaceId"].is_null())
            .count(),
        1
    );

    let close_replacement = rpc_with_params(
        &socket,
        "axo.session.close",
        json!({ "sessionId": standalone_replacement["id"] }),
    );
    standalone_replacement = close_replacement["result"]["replacement"].clone();
    assert!(
        standalone_replacement.is_object(),
        "the standalone Session invariant should also hold on subsequent closes: {close_replacement}"
    );
    cleanup.track(&standalone_replacement);
    assert_eq!(
        active_sessions(&socket)
            .iter()
            .filter(|session| session["workspaceId"].is_null())
            .count(),
        1
    );

    daemon.stop();
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn daemon_starts_with_and_restores_a_default_pty_session_after_restart() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let mut cleanup = SessionProcessCleanup::default();
    let directory =
        std::path::Path::new("/tmp").join(format!("axo-e2e-{}-{unique}", std::process::id()));
    let server_directory = directory.join("server");
    let socket = directory.join("axod.sock");

    let mut daemon = start_axod(&server_directory, &socket);
    wait_for_socket(&socket, &mut daemon);

    let negotiated = rpc_with_params(
        &socket,
        "axo.protocol.negotiate",
        json!({ "protocolVersion": 1 }),
    );
    assert_eq!(negotiated["result"]["protocolVersion"], 1);
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
    assert!(session["workspaceId"].is_null());
    assert_eq!(session["shells"].as_array().unwrap().len(), 1);
    let shell = &session["shells"][0];
    assert_eq!(shell["initialPwd"], home);
    assert!(shell["ptyDevice"].as_str().unwrap().starts_with("/dev/"));
    assert!(server_directory.join("axo.db").exists());

    let (_attachment, master) = open_shell(shell);
    write_pty(master.as_raw_fd(), b"printf 'AXOD_PTY_E2E_OK\\n'\n");
    assert!(
        pty_contains(
            master.as_raw_fd(),
            b"AXOD_PTY_E2E_OK",
            Duration::from_secs(3)
        ),
        "the attached PTY should execute commands and return their output"
    );

    let session_id = session["id"].as_i64().unwrap();
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
        2
    );
    let layout = json!({
        "kind": "split",
        "id": "02a4c161-8143-4c9a-bbf2-1a625e8b8342",
        "direction": "down",
        "ratio": 0.63,
        "first": { "kind": "pane", "shellId": shell_id },
        "second": { "kind": "pane", "shellId": split_shell["id"] },
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
    assert_eq!(restored[0]["shells"].as_array().unwrap().len(), 2);
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
    assert!(pty_contains(
        restored_master.as_raw_fd(),
        b"AXOD_RESTORED_OK",
        Duration::from_secs(3)
    ));

    assert_ne!(split_shell["id"], shell_id);
    let grouped = active_sessions(&socket);
    assert_eq!(grouped.len(), 1, "a split stays in the current tab");
    assert_eq!(grouped[0]["id"], session_id);
    assert_eq!(grouped[0]["shells"].as_array().unwrap().len(), 2);

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
        1
    );
    assert_eq!(
        active_sessions(&socket)[0]["layout"],
        json!({ "kind": "pane", "shellId": shell_id })
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
    assert!(replacement["workspaceId"].is_null());
    assert_eq!(active_sessions(&socket).len(), 1);

    let replacement_id = replacement["id"].as_i64().unwrap();
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
