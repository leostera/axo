//! Actual kernel-peer admission over attach v3, not a mocked desktop PID.
use crate::test_support::Fixture;
use axo_pty::attach;
use std::time::Duration;

const HELPER: &str = "scenarios::desktop::owned_desktop_attachment_client";

#[test]
fn owned_desktop_attachment_client() {
    let Some(root) = std::env::var_os("AXO_OWNED_DESKTOP_FIXTURE") else {
        return;
    };
    let root = std::path::PathBuf::from(root);
    let socket = std::env::var_os("AXO_OWNED_DESKTOP_SOCKET").unwrap();
    let shell_file = root.join("desktop-shells.json");
    for _ in 0..500 {
        if shell_file.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let shells: Vec<i64> = serde_json::from_slice(&std::fs::read(shell_file).unwrap()).unwrap();
    let denied = std::env::var_os("AXO_OWNED_DESKTOP_DESCENDANT").is_some();
    for shell in &shells {
        let result = attach::open_snapshot(std::path::Path::new(&socket), *shell);
        if denied {
            assert_eq!(
                result.err().unwrap().kind(),
                std::io::ErrorKind::PermissionDenied
            );
        } else {
            assert!(
                result.is_ok(),
                "managed workbench attachment failed: {:?}",
                result.err()
            );
        }
    }
    if !denied {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", HELPER, "--nocapture"])
            .env("AXO_OWNED_DESKTOP_DESCENDANT", "1")
            .status()
            .unwrap();
        assert!(
            status.success(),
            "the desktop's descendant must not inherit pane authority"
        );
        std::fs::write(root.join("desktop-complete"), shells.len().to_string()).unwrap();
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_managed_desktop_attaches_both_panes_of_existing_and_new_sessions() {
    let mut fixture = Fixture::new().await;
    fixture.listen_admitting(|core, peer, session| {
        let admitted = crate::callers::may_type_into(core, peer, session);
        if admitted {
            assert!(
                !crate::callers::is_the_person(peer),
                "pane control is not human authority"
            );
            assert!(
                crate::callers::session_of(core, peer).is_none(),
                "the desktop owns no Session"
            );
        }
        admitted
    });
    let existing = fixture.new_session().await;
    let mut command = tokio::process::Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", HELPER, "--nocapture"])
        .env("AXO_OWNED_DESKTOP_FIXTURE", &fixture.directory)
        .env("AXO_OWNED_DESKTOP_SOCKET", &fixture.core.attach_socket_path);
    fixture.core.desktop.open_test_program(command).unwrap();
    let new = fixture.new_session().await;
    let shells: Vec<i64> = existing
        .shells
        .iter()
        .chain(&new.shells)
        .map(|shell| shell.id.get())
        .collect();
    assert_eq!(shells.len(), 4);
    std::fs::write(
        fixture.directory.join("desktop-shells.json"),
        serde_json::to_vec(&shells).unwrap(),
    )
    .unwrap();
    fixture
        .until(
            "the actual managed desktop to attach four panes and refuse its descendant",
            || fixture.directory.join("desktop-complete").exists(),
        )
        .await;
    let socket = fixture.core.attach_socket_path.clone();
    let shell = shells[0];
    let refused =
        tokio::task::spawn_blocking(move || attach::open_snapshot(&socket, shell).err().unwrap())
            .await
            .unwrap();
    assert_eq!(
        refused.kind(),
        std::io::ErrorKind::PermissionDenied,
        "the desktop's launcher must not inherit authority"
    );
}
