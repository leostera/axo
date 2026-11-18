use super::*;
use std::time::{Duration, Instant};

const THREAD: &str = "01a1eea8-952a-7271-8b55-c2708a01c6ff";
const SESSION: &str = "5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f";

fn fake_codex() -> PathBuf {
    std::fs::canonicalize(std::env::var_os("AXO_TEST_FAKE_CODEX").expect("set by Bazel")).unwrap()
}

fn request(directory: &Path, thread_id: Option<&str>) -> CodexLaunch {
    let work = directory.join("work");
    std::fs::create_dir_all(&work).unwrap();
    // Each its own Session: the socket may fall back to a path in /tmp named after it.
    let session = axo_protocol::new_uuid_v4().unwrap();
    CodexLaunch {
        executable: fake_codex(),
        paths: CodexPaths::new(directory, &session).unwrap(),
        initial_pwd: work,
        session_uuid: session,
        pane_id: "pane-1".into(),
        home: directory.to_owned(),
        environment: vec![("AXO_FAKE_CODEX_LOG", directory.join("codex.log"))],
        thread_id: thread_id.map(str::to_owned),
        thread_name: "Session 1".into(),
        instructions: Some("<axo>brief</axo>".into()),
        mcp: Some(AxoMcp {
            axod: PathBuf::from("/opt/axo/axod"),
            socket: directory.join("axod.sock"),
            session_id: "s".into(),
        }),
        previous: None,
        size: WindowSize::DEFAULT,
    }
}

/// The fake's log once it has a line starting with `prefix`.
fn wait_for_log(directory: &Path, prefix: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let log = std::fs::read_to_string(directory.join("codex.log")).unwrap_or_default();
        if log.lines().any(|line| line.starts_with(prefix)) {
            return log;
        }
        assert!(Instant::now() < deadline, "no `{prefix}` in:\n{log}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Removes the test's directory and any socket its servers left in /tmp.
fn clean(directory: &Path) {
    let log = std::fs::read_to_string(directory.join("codex.log")).unwrap_or_default();
    for socket in log.lines().filter_map(|line| line.strip_prefix("listening ")) {
        let _ = std::fs::remove_file(socket);
    }
    std::fs::remove_dir_all(directory).unwrap();
}

fn stop(process: CodexProcess) {
    axo_pty::process::signal(&process.pty.child, libc::SIGKILL);
    drop(process);
}

#[tokio::test]
async fn a_new_session_starts_a_server_a_written_thread_and_the_tui_on_it() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, None);
    let paths = launch.paths.clone();
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    let process = attach(launch, lock, server).await.unwrap();
    assert_eq!(process.thread_id, THREAD);
    let log = wait_for_log(&directory, "tui ");
    let socket = paths.socket().display().to_string();
    let requests: Vec<&str> = log
        .lines()
        .filter_map(|line| line.strip_prefix("request "))
        .map(|line| line.split(' ').next().unwrap())
        .collect();
    assert_eq!(requests, ["initialize", "initialized", "thread/start", "thread/name/set"]);
    assert!(log.contains("\"developerInstructions\":\"<axo>brief</axo>\""), "{log}");
    assert!(log.contains("config mcp_servers.axo.command=\"/opt/axo/axod\""), "{log}");
    let work = std::fs::canonicalize(directory.join("work")).unwrap();
    assert!(
        log.contains(&format!("tui unix://{socket} {THREAD} cwd={}", work.display())),
        "{log}"
    );
    assert!(paths.is_running().unwrap());
    stop(process);
    assert!(!paths.is_running().unwrap(), "the lock goes with the server");
    clean(&directory);
}

#[tokio::test]
async fn an_existing_thread_is_resumed_without_starting_another() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, Some("existing-thread"));
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    let process = attach(launch, lock, server).await.unwrap();
    assert_eq!(process.thread_id, "existing-thread");
    let log = wait_for_log(&directory, "tui ");
    assert!(!log.contains("thread/start"), "{log}");
    assert!(log.contains(" existing-thread cwd="), "{log}");
    stop(process);
    clean(&directory);
}

#[tokio::test]
async fn a_second_codex_for_the_session_is_refused_while_the_first_runs() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, None);
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    let process = attach(launch.clone(), lock, server).await.unwrap();
    let refused = start_server(&launch, &lifeline).err().unwrap();
    assert_eq!(refused.kind(), io::ErrorKind::WouldBlock);
    stop(process);
    // Once it is gone the socket it left is cleared and the next one starts.
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    drop((server, lock));
    clean(&directory);
}

#[tokio::test]
async fn a_server_an_earlier_axod_left_is_killed_and_its_session_launches() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let mut launch = request(&directory, Some(THREAD));
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    wait_for_log(&directory, "listening ");
    // The earlier axod is gone; its server is not, and still holds the lock.
    let leftover = ProcessIdentity::of(server.id()).unwrap();
    std::mem::forget(server);
    drop(lock);
    launch.previous = Some(leftover);
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    // The lock was free again, so the leftover and its server are gone; reap the guard, which
    // this test, standing in for the earlier axod, started.
    // SAFETY: waits for a child of this process.
    assert_eq!(unsafe { libc::waitpid(leftover.pid as i32, std::ptr::null_mut(), 0) }, leftover.pid as i32);
    assert!(!leftover.is_running(), "the leftover was killed");
    drop((server, lock));
    // A holder axod does not know is never signalled.
    let holder = WriterLock::acquire(&launch.paths.lock_base).unwrap();
    launch.previous = None;
    assert_eq!(start_server(&launch, &lifeline).err().unwrap().kind(), io::ErrorKind::WouldBlock);
    drop(holder);
    clean(&directory);
}

#[tokio::test]
async fn ending_axods_lifeline_ends_the_server() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, Some(THREAD));
    let paths = launch.paths.clone();
    let (lock, server) = start_server(&launch, &lifeline).unwrap();
    wait_for_log(&directory, "listening ");
    drop(lock);
    assert!(paths.is_running().unwrap(), "the guard holds it");
    drop(lifeline);
    let deadline = Instant::now() + Duration::from_secs(10);
    while paths.is_running().unwrap() {
        assert!(Instant::now() < deadline, "the server outlived the lifeline");
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(server);
    clean(&directory);
}

#[test]
fn a_socket_path_too_long_to_bind_falls_back_to_tmp_and_beyond_that_is_refused() {
    let long = PathBuf::from("/tmp").join("d".repeat(80));
    let paths = CodexPaths::new(&long, SESSION).unwrap();
    assert_eq!(paths.socket(), Path::new(&format!("/tmp/axo-codex-{SESSION}.sock")));
    assert_eq!(paths.lock_base, long.join(format!("{SESSION}.jsonl")), "the lock stays put");
    assert_eq!(
        CodexPaths::new(&long, &"s".repeat(100)).unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
}

#[test]
fn only_a_socket_or_a_link_is_cleared_from_the_socket_path() {
    let directory = crate::test_directory();
    let path = directory.join("s.sock");
    remove_abandoned_socket(&path).unwrap();
    std::os::unix::fs::symlink("/nowhere", &path).unwrap();
    remove_abandoned_socket(&path).unwrap();
    assert!(std::fs::symlink_metadata(&path).is_err());
    std::fs::write(&path, "not a socket").unwrap();
    assert_eq!(
        remove_abandoned_socket(&path).unwrap_err().kind(),
        io::ErrorKind::AlreadyExists
    );
    clean(&directory);
}
