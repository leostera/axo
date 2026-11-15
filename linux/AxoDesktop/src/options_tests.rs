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
        TerminalSource::Attached { shell: 105, .. }
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
fn standalone_mode_remains_a_distinct_choice() {
    let options = Options::try_parse_from(["AxoDesktop", "--command", "/bin/sh"]).unwrap();
    assert!(
        matches!(options.source().unwrap(), TerminalSource::Standalone(Some(command)) if command == "/bin/sh")
    );
    let options = Options::try_parse_from(["AxoDesktop"]).unwrap();
    assert!(matches!(
        options.source().unwrap(),
        TerminalSource::Standalone(None)
    ));
}
