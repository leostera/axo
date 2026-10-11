//! Launches the actual packaged Mac application. The app, not this runner, starts axod.
#[allow(dead_code)] // Shared fixture exposes helpers used by other campaigns.
#[path = "../tests/support/model_fixture.rs"]
mod model_fixture;
use axod::ambient_pi::AmbientPi;
use serde_json::json;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::Path,
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
    let unavailable = match std::env::var("AXO_APP_SELF_TEST_CASE").as_deref() {
        Ok("available") | Err(std::env::VarError::NotPresent) => false,
        Ok("unavailable") => true,
        _ => panic!("AXO_APP_SELF_TEST_CASE must be available or unavailable"),
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
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let pi = AmbientPi::find(None).expect("Ambient interactive Pi required");
    let model = model_fixture::Fixture::new();
    let root = std::env::temp_dir().join(format!("axo-app-startup-{}", uuid::Uuid::new_v4()));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    for name in ["home", "sessions", "agent"] {
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
