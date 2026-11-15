use super::*;

#[test]
fn attachment_is_explicit_and_never_falls_back_to_a_command() {
    let options = Options::try_parse_from([
        "AxoDesktop",
        "--attach-socket",
        "/tmp/fixture/attach.sock",
        "--shell",
        "105",
    ])
    .unwrap();
    assert!(matches!(
        options.source().unwrap(),
        WindowSource::Terminal(TerminalSource::Attached { shell: 105, .. })
    ));
    for arguments in [
        vec!["AxoDesktop", "--attach-socket", "/tmp/fixture/attach.sock"],
        vec!["AxoDesktop", "--shell", "105"],
        vec![
            "AxoDesktop",
            "--attach-socket",
            "/tmp/fixture/attach.sock",
            "--shell",
            "0",
        ],
        vec![
            "AxoDesktop",
            "--attach-socket",
            "/tmp/fixture/attach.sock",
            "--shell",
            "105",
            "--command",
            "sh",
        ],
    ] {
        assert!(Options::try_parse_from(arguments).is_err());
    }
}

#[test]
fn workbench_requires_an_explicit_rpc_socket_and_cannot_spawn_a_fallback() {
    let options =
        Options::try_parse_from(["AxoDesktop", "--socket", "/tmp/fixture/axod.sock"]).unwrap();
    assert!(matches!(
        options.source().unwrap(),
        WindowSource::Workbench { .. }
    ));
    for arguments in [
        vec![
            "AxoDesktop",
            "--socket",
            "/tmp/fixture/axod.sock",
            "--command",
            "sh",
        ],
        vec![
            "AxoDesktop",
            "--socket",
            "/tmp/fixture/axod.sock",
            "--attach-socket",
            "/tmp/fixture/attach.sock",
            "--shell",
            "1",
        ],
    ] {
        assert!(Options::try_parse_from(arguments).is_err());
    }
}

#[test]
fn standalone_mode_remains_a_distinct_choice() {
    let options = Options::try_parse_from(["AxoDesktop", "--command", "/bin/sh"]).unwrap();
    assert!(
        matches!(options.source().unwrap(), WindowSource::Terminal(TerminalSource::Standalone(Some(command))) if command == "/bin/sh")
    );
    let options = Options::try_parse_from(["AxoDesktop"]).unwrap();
    assert!(matches!(
        options.source().unwrap(),
        WindowSource::Terminal(TerminalSource::Standalone(None))
    ));
}
