use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
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

fn rpc(socket: &std::path::Path, method: &str) -> serde_json::Value {
    let mut stream = UnixStream::connect(socket).expect("daemon socket should accept connections");
    writeln!(stream, r#"{{"jsonrpc":"2.0","id":1,"method":"{method}"}}"#).unwrap();
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response).unwrap();
    serde_json::from_str(&response).unwrap()
}

#[test]
fn daemon_serves_json_rpc_health_and_standard_method_errors() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = std::env::temp_dir().join(format!("axod-rpc-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let socket = directory.join("axod.sock");
    let child = Command::new(axod_binary())
        .arg("--socket")
        .arg(&socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut child = ChildGuard(child);

    let deadline = Instant::now() + Duration::from_secs(5);
    let health = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            drop(stream);
            break rpc(&socket, "axo.daemon.health");
        }
        assert!(
            Instant::now() < deadline,
            "daemon did not create its socket"
        );
        thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(health["jsonrpc"], "2.0");
    assert_eq!(health["result"]["status"], "running");
    assert!(health["result"]["buildNumber"].as_u64().is_some());

    let unknown_method = rpc(&socket, "axo.unknown");
    assert_eq!(unknown_method["error"]["code"], -32601);

    child.0.kill().unwrap();
    child.0.wait().unwrap();
    let _ = std::fs::remove_dir_all(directory);
}
