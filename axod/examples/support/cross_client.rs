//! Rust owns the disposable simulator, application configuration and filesystem checks.
use serde_json::Value;
use std::{
    fs,
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub fn private_bytes(path: &Path, limit: u64) -> Vec<u8> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .unwrap();
    let attributes = file.metadata().unwrap();
    assert!(
        attributes.is_file()
            && attributes.uid() == unsafe { libc::geteuid() }
            && attributes.nlink() == 1
            && attributes.mode() & 0o777 == 0o600
            && attributes.len() <= limit,
        "Owned private fixture file required"
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes.len() as u64, attributes.len(), "Fixture file changed");
    bytes
}
fn run(mut command: Command, log: &Path, seconds: u64) {
    let output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(log)
        .unwrap();
    let mut child = command
        .stdin(Stdio::null())
        .stdout(output.try_clone().unwrap())
        .stderr(output)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(
                status.success(),
                "Fixture command failed; private log: {}",
                log.display()
            );
            return;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!(
                "Owned fixture command deadline; private log: {}",
                log.display()
            );
        }
        thread::sleep(Duration::from_millis(100));
    }
}
fn simctl(arguments: &[&str]) -> Command {
    let mut command = Command::new("/usr/bin/xcrun");
    command.arg("simctl").args(arguments);
    command
}
fn directory(path: &Path) {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => (),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let metadata = fs::symlink_metadata(path).unwrap();
            assert!(
                metadata.is_dir() && metadata.uid() == unsafe { libc::geteuid() },
                "Owned simulator directory required"
            );
        }
        Err(error) => panic!("Private simulator directory: {error}"),
    }
}
pub struct Phone {
    device: String,
    products: PathBuf,
    run_file: PathBuf,
}
impl Phone {
    pub fn prepare(root: &Path, repo: &Path, coordination: &Path) -> Self {
        let output = simctl(&["list", "runtimes", "--json"]).output().unwrap();
        assert!(output.status.success());
        let runtimes: Value = serde_json::from_slice(&output.stdout).unwrap();
        let runtime = runtimes["runtimes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|value| {
                value["isAvailable"] == true
                    && value["identifier"]
                        .as_str()
                        .is_some_and(|id| id.contains("SimRuntime.iOS-"))
            })
            .expect("Available iOS simulator runtime required")["identifier"]
            .as_str()
            .unwrap();
        let created = simctl(&[
            "create",
            "Axo cross-client disposable fixture",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            runtime,
        ])
        .output()
        .unwrap();
        assert!(
            created.status.success(),
            "Disposable simulator creation refused"
        );
        let device = String::from_utf8(created.stdout).unwrap().trim().to_owned();
        uuid::Uuid::parse_str(&device).expect("New simulator identity required");
        let derived = repo.join("apple/DerivedData");
        let products = derived.join("Build/Products");
        let phone = Self {
            device,
            products,
            run_file: root.join("phone.xctestrun"),
        };
        run(
            simctl(&["boot", &phone.device]),
            &root.join("phone-boot.log"),
            30,
        );
        run(
            simctl(&["bootstatus", &phone.device, "-b"]),
            &root.join("phone-bootstatus.log"),
            120,
        );
        run(
            simctl(&[
                "keychain",
                &phone.device,
                "add-root-cert",
                coordination.join("certificate.pem").to_str().unwrap(),
            ]),
            &root.join("phone-trust.log"),
            30,
        );
        let mut build = Command::new("/usr/bin/xcodebuild");
        build
            .args(["-project"])
            .arg(repo.join("apple/Axo.xcodeproj"))
            .args([
                "-scheme",
                "AxoPhone",
                "-configuration",
                "Debug",
                "-destination",
            ])
            .arg(format!("platform=iOS Simulator,id={}", phone.device))
            .arg("-derivedDataPath")
            .arg(&derived)
            .arg("build-for-testing");
        run(build, &root.join("phone-build.log"), 360);
        run(
            simctl(&[
                "install",
                &phone.device,
                phone
                    .products
                    .join("Debug-iphonesimulator/AxoPhone.app")
                    .to_str()
                    .unwrap(),
            ]),
            &root.join("phone-install.log"),
            30,
        );
        let container = simctl(&[
            "get_app_container",
            &phone.device,
            "dev.leostera.axo.phone",
            "data",
        ])
        .output()
        .unwrap();
        assert!(
            container.status.success(),
            "Owned simulator app container required"
        );
        let container = PathBuf::from(String::from_utf8(container.stdout).unwrap().trim());
        assert!(
            container.is_absolute()
                && container
                    .components()
                    .any(|part| part.as_os_str() == phone.device.as_str()),
            "Container must belong to the newly created device"
        );
        let support = container.join("Library/Application Support");
        directory(&support);
        let bytes = private_bytes(&coordination.join("phone.json"), 16384);
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(support.join("control-plane-e2e.json"))
            .unwrap();
        file.write_all(&bytes).unwrap();
        file.sync_all().unwrap();
        phone
    }
    pub fn check(&self, root: &Path) {
        let ready = root.join("cross-client-ready.json");
        let deadline = Instant::now() + Duration::from_secs(65);
        while !ready.exists() {
            if root.join("result").exists() || Instant::now() >= deadline {
                panic!(
                    "Packaged Mac readiness failed; private fixture retained at {}",
                    root.display()
                );
            }
            thread::sleep(Duration::from_millis(100));
        }
        let source: Value = serde_json::from_slice(&private_bytes(&ready, 4096)).unwrap();
        thread::sleep(Duration::from_millis(500));
        let records_path = root.join("home/Library/Application Support/Axo/Axod/work-records.json");
        let records_before = private_bytes(&records_path, 4 * 1024 * 1024);
        let histories = history_files(&root.join("sessions"));
        assert_eq!(histories.len(), 1, "Pi alone created one canonical JSONL");
        let canonical_before = private_bytes(&histories[0], 128 * 1024);
        let run_source = fs::read_dir(&self.products)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "xctestrun")
                    && path
                        .file_name()
                        .unwrap()
                        .to_string_lossy()
                        .starts_with("AxoPhone_")
            })
            .expect("Phone test run configuration required");
        let mut configure = Command::new("/usr/bin/python3");
        configure
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/support/configure_phone.py"))
            .arg(run_source)
            .arg(&self.run_file)
            .arg(&ready);
        run(configure, &root.join("phone-configure.log"), 10);
        let mut test = Command::new("/usr/bin/xcodebuild");
        test.args(["test-without-building", "-xctestrun"]).arg(&self.run_file).arg("-destination")
            .arg(format!("platform=iOS Simulator,id={}", self.device)).arg("-parallel-testing-enabled").arg("NO")
            .arg("-only-testing:AxoPhoneUITests/CrossClientControlPlaneUITests/testPackagedMacSessionThroughRealAPIAndReconnect")
            .arg("-only-testing:AxoPhoneUITests/PrivateMachineBrowserUITests/testPreviewKeepsWorkSessionsDistinctAndOfflineCatalogExplicit")
            .arg("-resultBundlePath").arg(root.join("phone.xcresult"));
        run(test, &root.join("phone-ui.log"), 150);
        let summary = Command::new("/usr/bin/xcrun")
            .args([
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--compact",
                "--path",
            ])
            .arg(root.join("phone.xcresult"))
            .output()
            .unwrap();
        assert!(
            summary.status.success() && summary.stdout.len() <= 65536,
            "Bounded XCTest report required"
        );
        let summary: Value = serde_json::from_slice(&summary.stdout).unwrap();
        assert!(
            summary["totalTestCount"] == 2
                && summary["passedTests"] == 2
                && summary["failedTests"] == 0
                && summary["skippedTests"] == 0,
            "Both actual phone UI tests must execute and pass; skipped/empty results are not acceptance"
        );
        assert!(
            private_bytes(&records_path, 4 * 1024 * 1024) == records_before,
            "Phone discovery/reconnect cannot mutate work records"
        );
        assert_eq!(
            history_files(&root.join("sessions")),
            histories,
            "No second canonical writer"
        );
        assert!(
            private_bytes(&histories[0], 128 * 1024) == canonical_before,
            "Read-only phone reconnect cannot replay Pi work"
        );
        assert!(
            source["runtimeGenerations"]
                .as_array()
                .is_some_and(|values| values.len() == 2)
        );
        println!(
            "PASS: actual iOS simulator discovered the packaged Mac's exact machine/host/session/two runtime identities through isolated API and TLS; reconnect retained identities and unchanged records/canonical history"
        );
    }
}
impl Drop for Phone {
    fn drop(&mut self) {
        // Only this newly minted simulator; never an operator-selected existing device.
        let _ = simctl(&["shutdown", &self.device]).output();
        let _ = simctl(&["delete", &self.device]).output();
    }
}
fn history_files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(root).unwrap() {
        let entry = entry.unwrap();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            files.extend(history_files(&entry.path()));
        } else if kind.is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "jsonl")
        {
            files.push(entry.path());
        }
    }
    files.sort();
    files
}
