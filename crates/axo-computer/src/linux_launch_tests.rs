use cua_driver_core::launch_guard::{LaunchCommand, LaunchCommandError};
use serde_json::json;

#[test]
fn quoted_launches_preserve_literal_argv_without_a_shell() {
    let command = LaunchCommand::parse(
        r#""/opt/Axo apps/試す" "two words" '' "literal $HOME" "$(touch marker)""#,
        &["extra argument".into()],
    )
    .unwrap();
    assert_eq!(command.program(), "/opt/Axo apps/試す");
    assert_eq!(
        command.arguments(),
        [
            "two words",
            "",
            "literal $HOME",
            "$(touch marker)",
            "extra argument"
        ]
    );
    let operators = LaunchCommand::parse("/bin/echo ; touch marker", &[]).unwrap();
    assert_eq!(operators.arguments(), [";", "touch", "marker"]);
}

#[test]
fn malformed_or_protected_commands_are_rejected_after_decoding() {
    for command in ["", "  ", "''", "\"unfinished", "trailing\\", "echo\0bad"] {
        assert!(LaunchCommand::parse(command, &[]).is_err(), "{command:?}");
    }
    for command in [
        r#"chrome "--remote-debugging-"port=0"#,
        r#"chrome --remote-debugging-p\ipe"#,
        r#""/usr/bin/chrome" '--REMOTE-DEBUGGING-PIPE'"#,
    ] {
        assert_eq!(
            LaunchCommand::parse(command, &[]).unwrap_err(),
            LaunchCommandError::RemoteDebugging
        );
    }
    assert_eq!(
        LaunchCommand::parse("chrome", &["--remote-debugging-port=0".into()]).unwrap_err(),
        LaunchCommandError::RemoteDebugging
    );
}

#[test]
fn quoted_launcher_metadata_matches_the_executable_window_class() {
    let app = platform_linux::installed_apps::InstalledApp {
        name: "Owned fixture".into(),
        bundle_id: "owned.fixture".into(),
        launch_path: r#""/opt/has spaces/owned-browser" --new-window"#.into(),
        last_used: None,
        startup_wm_class: None,
    };
    assert!(app.owns_window_class("owned-browser"));
    assert!(!app.owns_window_class("spaces"));
}

#[test]
#[ignore = "requires private HOME/XDG_DATA_HOME and linux/computer-smoke.sh"]
fn real_installed_quoted_launcher_round_trips_without_expansion() {
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::env::var("AXO_LINUX_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    let root = std::path::PathBuf::from(std::env::var("AXO_LINUX_APP_FIXTURE").unwrap());
    assert!(root.starts_with(std::env::temp_dir()));
    assert_eq!(
        std::path::PathBuf::from(std::env::var_os("XDG_DATA_HOME").unwrap()),
        root.join("data")
    );
    let directory = root.join("app with spaces");
    std::fs::create_dir_all(&directory).unwrap();
    let program = directory.join("launcher");
    let window = root.join("owned_window.py");
    std::fs::write(&window, "import gi\ngi.require_version('Gtk','4.0')\nfrom gi.repository import Gtk,GLib\napp=Gtk.Application(application_id='dev.axo.OwnedLaunchFixture')\ndef activate(app):\n w=Gtk.ApplicationWindow(application=app,title='Owned launch fixture')\n w.set_default_size(240,120)\n w.present()\n GLib.timeout_add_seconds(10,app.quit)\napp.connect('activate',activate)\napp.run(None)\n").unwrap();
    std::fs::write(
        &program,
        format!("#!/bin/sh\nout=$1\nshift\nprintf '%s\\0' \"$@\" > \"$out\"\nexec /usr/bin/python3 \"{}\"\n",window.display()),
    ).unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = root.join("argv");
    let applications = root.join("data/applications");
    std::fs::create_dir_all(&applications).unwrap();
    std::fs::write(applications.join("axo-owned-launch.desktop"),format!(
        "[Desktop Entry]\nType=Application\nName=Axo Owned Launch Fixture\nExec=\"{}\" \"{}\" \"two words\" \"literal $HOME\" %U\n",
        program.display(),output.display())).unwrap();
    let side_effect = format!("$(touch {})", root.join("marker").display());
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let registry=platform_linux::tools::build_registry(false);
        let apps=registry.invoke("list_apps",json!({})).await;
        assert_ne!(apps.is_error,Some(true));
        let app=apps.structured_content.as_ref().unwrap()["apps"].as_array().unwrap().iter()
            .find(|app|app["bundle_id"]=="axo-owned-launch").unwrap();
        let result=registry.invoke("launch_app",json!({"launch_path":app["launch_path"],"additional_arguments":[side_effect.clone()]})).await;
        assert_ne!(result.is_error,Some(true),"{result:?}");
    });
    for _ in 0..100 {
        if output.exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(
        std::fs::read_to_string(output).unwrap(),
        format!("two words\0literal $HOME\0{side_effect}\0")
    );
    assert!(!root.join("marker").exists());
}
