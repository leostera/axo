//! Launches the actual packaged Mac application. The app, not this runner, starts axod.
#[allow(dead_code)] // Shared fixture exposes helpers used by other campaigns.
#[path = "../tests/support/model_fixture.rs"]
mod model_fixture;
use axod::ambient_pi::AmbientPi;
use serde_json::json;
use std::{
    fs,
    io::Read,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn private_json(path: &Path, value: &serde_json::Value) {
    fs::write(path, serde_json::to_vec(value).unwrap()).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn account_shell() -> std::path::PathBuf {
    let mut record: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0_u8; 65536];
    let status = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut record,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    assert!(
        status == 0 && !result.is_null() && !record.pw_shell.is_null(),
        "Account shell unavailable"
    );
    let path = unsafe { std::ffi::CStr::from_ptr(record.pw_shell) }
        .to_str()
        .unwrap();
    fs::canonicalize(path).unwrap()
}
fn main() {
    let ui_test = std::env::var("AXO_APP_SELF_TEST_CASE").as_deref() == Ok("ui");
    let unavailable = match std::env::var("AXO_APP_SELF_TEST_CASE").as_deref() {
        Ok("available") | Ok("ui") | Err(std::env::VarError::NotPresent) => false,
        Ok("unavailable") => true,
        _ => panic!("AXO_APP_SELF_TEST_CASE must be available, unavailable or ui"),
    };
    let app = std::env::args_os()
        .nth(1)
        .expect("Usage: app-startup-fixture /absolute/Axo.app");
    let app = fs::canonicalize(app).unwrap();
    let executable = app.join("Contents/MacOS/Axo");
    let adapter = app.join("Contents/Resources/pi-axo/index.mjs");
    assert!(
        executable.is_file() && adapter.is_file(),
        "Actual packaged app/adapter required"
    );
    let capability = Command::new("/usr/bin/plutil")
        .args(["-extract", "AxoSelfTestProtocolVersion", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .output()
        .unwrap();
    assert!(
        capability.status.success() && capability.stdout == b"2\n",
        "Bundle must support isolated self-test before launch"
    );
    if ui_test {
        let capability = Command::new("/usr/bin/plutil")
            .args(["-extract", "AxoUITestProtocolVersion", "raw", "-o", "-"])
            .arg(app.join("Contents/Info.plist"))
            .output()
            .unwrap();
        assert!(
            capability.status.success() && capability.stdout == b"3\n",
            "Bundle must explicitly support isolated UI testing before launch"
        );
    }
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let pi = AmbientPi::find(None).expect("Ambient interactive Pi required");
    let model = model_fixture::Fixture::new();
    let root = std::env::temp_dir().join(format!("axo-app-startup-{}", uuid::Uuid::new_v4()));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    for name in ["home", "sessions", "agent", "workspace"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(name))
            .unwrap();
    }
    let mut state = root.join("home");
    for component in ["Library", "Application Support", "Axo", "Axod"] {
        state.push(component);
        fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
    }
    let shell = account_shell();
    fs::write(
        root.join("expected-shell"),
        shell.as_os_str().as_encoded_bytes(),
    )
    .unwrap();
    fs::set_permissions(
        root.join("expected-shell"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    // Owned user startup files: prove the actual zsh login/interactive path loads
    // them, without sourcing or copying the operator's real dotfiles/history.
    for (name, contents) in [
        (
            ".zprofile",
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\nexport AXO_TEST_ZPROFILE=loaded\n",
        ),
        (".zshrc", "export AXO_TEST_ZSHRC=loaded\n"),
    ] {
        let path = root.join("home").join(name);
        fs::write(&path, contents).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    private_json(
        &root.join("provider.json"),
        &json!({"baseUrl": model.url()}),
    );
    private_json(&state.join("profiles.json"), &json!({"profiles": {}}));
    private_json(
        &state.join("pi.json"),
        &json!({"extension": adapter, "profiles": {}, "local": {
            "sessionDirectory": root.join("sessions"), "executable": if unavailable { root.join("missing-pi") } else { pi.executable },
            "arguments": ["--no-approve", "--offline", "--no-skills", "--no-themes", "--no-context-files", "--no-prompt-templates",
                "--extension", repo.join("pi-axo/tests/fixtures/provider.ts"), "--model", "axo-interactive-fixture/fixture",
                "--tools", "bash,axo_ask,axo_set_title"]
        }}),
    );
    let output = fs::File::create(root.join("app.log")).unwrap();
    fs::set_permissions(root.join("app.log"), fs::Permissions::from_mode(0o600)).unwrap();
    if ui_test {
        run_ui_tests(&app, &root, repo);
        verify_ui_workspace_history(&root);
        assert_eq!(
            model.requests(),
            1,
            "Exactly one UI-typed workspace Pi turn"
        );
        assert!(
            !state.join("local-endpoint.json").exists(),
            "Owned UI-test helper must be stopped on normal fixture quit"
        );
        fs::remove_dir_all(&root).unwrap();
        println!(
            "PASS: Xcode UI automation of packaged app selection/rename, native folder-picker workspace creation with initialized first session/real Pi turn before separate Command-T, cancel/exact-row/cross-workspace batch deletion and retained initial-session canonical history; one model request, isolated state and owned helper cleanup"
        );
        return;
    }
    // LaunchServices opens the signed bundle as a fresh application instance.
    let mut child = Command::new("/usr/bin/open")
        .args(["-n", "-W"])
        .arg(&app)
        .args(["--args", "-self-test"])
        .arg(&root)
        .stdin(Stdio::null())
        .stdout(output.try_clone().unwrap())
        .stderr(output)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            // Only reap our `open` launcher; never signal a discovered application PID.
            child.kill().unwrap();
            child.wait().unwrap();
            panic!(
                "Actual app self-test deadline; private fixture retained at {}",
                root.display()
            );
        }
        thread::sleep(Duration::from_millis(50));
    };
    assert!(
        status.success(),
        "Actual packaged app failed; private fixture retained at {}",
        root.display()
    );
    let expected = if unavailable {
        b"FAIL: Pi admission after independent shell input\n".as_slice()
    } else {
        b"PASS\n".as_slice()
    };
    assert_eq!(
        fs::read(root.join("result")).unwrap_or_default(),
        expected,
        "App must report its exact expected outcome; fixture retained at {}",
        root.display()
    );
    if unavailable {
        println!(
            "PASS: actual app negative control keeps shell input/output usable but refuses success with unavailable Pi; no model request"
        );
    } else {
        println!(
            "PASS: LaunchServices opened packaged Axo.app; actual delegate/window, bundled helper version, automatic single session, HOME cwd, account login shell/zsh startup files, Retina layer scale, header-free Pi-left/shell-right, window A-key/mouse routing and visible shell/Pi responses"
        );
    }
    assert_eq!(
        model.requests(),
        usize::from(!unavailable),
        "Exact typed Pi turn count; no startup model or replay"
    );
    assert!(
        !state.join("local-endpoint.json").exists(),
        "Owned app must release its test daemon discovery on exit"
    );
    fs::remove_dir_all(root).unwrap();
    println!(
        "PASS: actual app exit and owned daemon cleanup; no normal-service registration or live-state changes"
    );
}

#[derive(serde::Deserialize)]
struct UiWorkspace {
    record: axod::work::WorkspaceRecord,
}
#[derive(serde::Deserialize)]
struct UiReceipt {
    committed: axod::work::CommittedWork,
}
#[derive(serde::Deserialize)]
struct UiRecords {
    workspaces: std::collections::BTreeMap<axod::model::WorkspaceId, UiWorkspace>,
    sessions: std::collections::BTreeMap<axod::model::SessionId, axod::work::SessionRecord>,
    receipts: std::collections::BTreeMap<axod::model::CommandId, UiReceipt>,
    #[serde(default)]
    deletions:
        std::collections::BTreeMap<axod::model::CommandId, axod::work::SessionDeletionReceipt>,
}
fn read_ui_records(root: &Path) -> Option<UiRecords> {
    use std::os::unix::fs::MetadataExt;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(root.join("home/Library/Application Support/Axo/Axod/work-records.json"))
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.len() > 4 * 1024 * 1024
    {
        return None;
    }
    serde_json::from_reader(file.take(4 * 1024 * 1024 + 1)).ok()
}
fn ui_initial_workspace_session(records: &UiRecords) -> Option<&axod::work::SessionRecord> {
    records
        .receipts
        .values()
        .find_map(|receipt| match &receipt.committed.record {
            axod::work::WorkRecord::WorkspaceSession { workspace, session }
                if workspace.name == "UI Workspace" =>
            {
                Some(session)
            }
            _ => None,
        })
}
fn verify_ui_workspace_history(root: &Path) {
    let records = read_ui_records(root).expect("Owned committed UI records");
    let workspace = records
        .workspaces
        .values()
        .find(|workspace| workspace.record.name == "UI Workspace")
        .expect("Owned workspace setup");
    let sessions: Vec<_> = records
        .sessions
        .values()
        .filter(|session| session.workspace_id == Some(workspace.record.workspace_id))
        .collect();
    assert_eq!(
        sessions.len(),
        2,
        "Command-T must add exactly one session to the owned workspace"
    );
    let session = ui_initial_workspace_session(&records)
        .expect("Workspace creation's own initial session, not a Command-T replacement");
    assert!(
        sessions
            .iter()
            .any(|record| record.session_id == session.session_id)
    );
    assert_eq!(
        records.deletions.len(),
        2,
        "Cancel must not dispatch; single and batch deletion each commit once"
    );
    assert!(
        records
            .deletions
            .values()
            .all(|receipt| receipt.revision.is_some())
    );
    let deleted: std::collections::BTreeSet<_> = records
        .deletions
        .values()
        .flat_map(|receipt| {
            receipt
                .intent
                .sessions
                .iter()
                .map(|address| address.session_id)
        })
        .collect();
    assert_eq!(
        deleted.len(),
        3,
        "One clicked outside row and one selected cross-workspace pair"
    );
    assert!(
        deleted.contains(&session.session_id),
        "Workspace Pi was not part of the confirmed selected batch"
    );
    assert!(
        !records
            .sessions
            .values()
            .any(|record| record.name == "UI renamed" && deleted.contains(&record.session_id)),
        "Deletion retargeted the retained manual name"
    );
    let session_id = serde_json::to_value(session.session_id).unwrap();
    let directory = root
        .join("workspace/.axo/sessions")
        .join(session_id.as_str().unwrap());
    let metadata = fs::symlink_metadata(&directory).expect("Workspace-local session directory");
    assert!(metadata.is_dir() && !metadata.file_type().is_symlink());
    assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
    let histories = fs::read_dir(&directory)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "jsonl")
        })
        .count();
    assert_eq!(
        histories, 1,
        "Exactly one ambient-Pi canonical history in the work-session UUID folder"
    );
}

fn ui_history_snapshot(root: &Path) -> Option<(PathBuf, Vec<u8>)> {
    use std::os::unix::fs::MetadataExt;
    let records = read_ui_records(root)?;
    let session = ui_initial_workspace_session(&records)?;
    let id = serde_json::to_value(session.session_id).ok()?;
    let directory = root.join("workspace/.axo/sessions").join(id.as_str()?);
    let entry = fs::read_dir(directory)
        .ok()?
        .filter_map(Result::ok)
        .find(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "jsonl")
        })?;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(entry.path())
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.len() > 65536
    {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(65537).read_to_end(&mut bytes).ok()?;
    if bytes.len() > 65536
        || !std::str::from_utf8(&bytes)
            .ok()?
            .contains("Actual app Pi response")
    {
        return None;
    }
    Some((entry.path(), bytes))
}

fn run_ui_tests(app: &Path, root: &Path, repo: &Path) {
    // XCTest's launch() terminates existing instances by bundle ID. Never let
    // this isolated fixture silently stop a normal frontend.
    let safe = Command::new("/usr/bin/xcrun")
        .args(["swift", "-e", "import AppKit; if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == \"dev.leostera.axo.mac\" }) { exit(2) }"])
        .status().unwrap();
    assert!(
        safe.success(),
        "Close the live Axo frontend explicitly before UI automation; daemon work is not part of this fixture"
    );
    let log = fs::File::create(root.join("xcode-ui.log")).unwrap();
    fs::set_permissions(root.join("xcode-ui.log"), fs::Permissions::from_mode(0o600)).unwrap();
    let result_bundle = root.join("UI.xcresult");
    let mut child = Command::new("/usr/bin/xcrun")
        .arg("xcodebuild")
        .args(["test", "-project"])
        .arg(repo.join("apple/Axo.xcodeproj"))
        .args([
            "-scheme",
            "AxoMac",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
        ])
        .arg(repo.join("apple/DerivedData"))
        .args([
            "-only-testing:AxoMacUITests/SessionSidebarUITests",
            "-parallel-testing-enabled",
            "NO",
            "-resultBundlePath",
        ])
        .arg(&result_bundle)
        .arg(format!("AXO_UI_TEST_ROOT={}", root.display()))
        .arg(format!("AXO_UI_TEST_APP={}", app.display()))
        .args(["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES"])
        .stdin(Stdio::null())
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(600);
    let mut history_snapshot = None;
    loop {
        if history_snapshot.is_none() {
            history_snapshot = ui_history_snapshot(root);
        }
        if let Some(status) = child.try_wait().unwrap() {
            assert!(
                status.success(),
                "Xcode UI test failed; private fixture and xcresult retained at {}",
                root.display()
            );
            let (path, bytes) =
                history_snapshot.expect("Canonical Pi response captured before UI deletion");
            assert!(
                fs::read(path).unwrap() == bytes,
                "Deletion changed retained canonical history bytes"
            );
            break;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!(
                "Owned Xcode runner timed out; no discovered application PID was signaled; fixture retained at {}",
                root.display()
            );
        }
        thread::sleep(Duration::from_millis(100));
    }
}
