use super::*;
use crate::channel::nothing_while_running;
use std::time::Instant;

pub(crate) fn fake_opencode() -> PathBuf {
    std::fs::canonicalize(std::env::var_os("AXO_TEST_FAKE_OPENCODE").expect("set by Bazel")).unwrap()
}

fn request(directory: &Path, session_id: Option<&str>) -> OpenCodeLaunch {
    let work = directory.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let session = axo_protocol::new_uuid_v4().unwrap();
    OpenCodeLaunch {
        executable: fake_opencode(),
        paths: OpenCodePaths::new(directory, &session),
        initial_pwd: work,
        session_uuid: session,
        pane_id: "pane-1".into(),
        home: directory.to_owned(),
        environment: vec![("AXO_FAKE_OPENCODE_LOG", directory.join("opencode.log"))],
        session_id: session_id.map(str::to_owned),
        session_name: "Session 1".into(),
        mcp: Some(AxoMcp {
            axod: PathBuf::from("/opt/axo/axod"),
            socket: directory.join("axod.sock"),
            session_id: "s".into(),
        }),
        previous: None,
        size: WindowSize::DEFAULT,
    }
}

fn wait_for_log(directory: &Path, prefix: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let log = std::fs::read_to_string(directory.join("opencode.log")).unwrap_or_default();
        if log.lines().any(|line| line.starts_with(prefix)) {
            return log;
        }
        assert!(Instant::now() < deadline, "no `{prefix}` in:\n{log}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn stop(process: OpenCodeProcess) {
    axo_pty::process::signal(&process.pty.child, libc::SIGKILL);
    drop(process);
}

#[tokio::test]
async fn a_new_session_starts_a_server_a_session_and_the_tui_on_it() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, None);
    let paths = launch.paths.clone();
    let (lock, server, address) = start_server(&launch, &lifeline, nothing_while_running).unwrap();
    assert!(address.url.starts_with("http://127.0.0.1:"), "{address:?}");
    assert_eq!(address.password.len(), 64);
    assert!(paths.is_running().unwrap(), "the guard holds the lock");
    let process = attach(launch, lock, server, address.clone()).await.unwrap();
    assert_eq!(process.session_id, "ses_fake0001");
    let log = wait_for_log(&directory, "tui password=");
    assert!(log.contains(&format!("tui --server {} --session ses_fake0001", address.url)), "{log}");
    assert!(log.contains("tui password=true"), "{log}");
    assert!(log.contains(&format!("created ses_fake0001 title=Session 1 directory={}", directory.join("work").display())), "{log}");
    let config = log.lines().find_map(|line| line.strip_prefix("config ")).expect("configured");
    let config: serde_json::Value = serde_json::from_str(config).unwrap();
    assert_eq!(config["mcp"]["axo"]["command"], json!(["/opt/axo/axod", "mcp"]));
    assert_eq!(config["mcp"]["axo"]["environment"]["AXO_SESSION_ID"], "s");
    stop(process);
    let deadline = Instant::now() + Duration::from_secs(10);
    while paths.is_running().unwrap() {
        assert!(Instant::now() < deadline, "the server outlived its process");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::fs::remove_dir_all(&directory).unwrap();
}

#[tokio::test]
async fn a_known_session_is_rejoined_without_creating_another() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, Some("ses_known"));
    let (lock, server, address) = start_server(&launch, &lifeline, nothing_while_running).unwrap();
    let process = attach(launch, lock, server, address).await.unwrap();
    assert_eq!(process.session_id, "ses_known");
    let log = wait_for_log(&directory, "tui password=");
    assert!(!log.contains("created "), "{log}");
    assert!(log.contains("--session ses_known"), "{log}");
    stop(process);
    std::fs::remove_dir_all(&directory).unwrap();
}

#[tokio::test]
async fn a_second_launch_for_a_live_session_is_refused_unless_it_is_the_previous_server() {
    let directory = crate::test_directory();
    let lifeline = Lifeline::new().unwrap();
    let launch = request(&directory, None);
    let (lock, server, _) = start_server(&launch, &lifeline, nothing_while_running).unwrap();
    let identity = ProcessIdentity::of(server.id());
    drop(lock);
    // The first server still holds the lock through its guard.
    let refused = start_server(&launch, &lifeline, nothing_while_running).err().expect("refused");
    assert_eq!(refused.kind(), io::ErrorKind::WouldBlock);
    let mut again = launch.clone();
    again.previous = identity;
    let (_lock, second, _) = start_server(&again, &lifeline, nothing_while_running).expect("the previous server is killed");
    drop(second);
    drop(server);
    std::fs::remove_dir_all(&directory).unwrap();
}
