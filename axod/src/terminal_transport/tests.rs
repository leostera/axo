use super::*;
use crate::{
    journal::Journal, local::LocalServer, profiles::Profiles, test_support::TestDirectory,
};
use std::net::TcpStream;
use tungstenite::{client::IntoClientRequest, stream::MaybeTlsStream};

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;
struct Fixture {
    root: TestDirectory,
    manager: Arc<Manager>,
    machine: MachineId,
    server: Option<LocalServer>,
}
impl Fixture {
    fn new() -> Self {
        let root = TestDirectory::new();
        let manager = Arc::new(Manager::new(Journal::open(root.path()).unwrap()));
        let machine = MachineId::new();
        let server = LocalServer::start(
            root.path(),
            machine,
            manager.clone(),
            Profiles(Default::default()),
            Arc::new(AtomicBool::new(false)),
        )
        .unwrap();
        Self {
            root,
            manager,
            machine,
            server: Some(server),
        }
    }
    fn discovery(&self, name: &str) -> Discovery {
        serde_json::from_slice(&std::fs::read(self.root.path().join(name)).unwrap()).unwrap()
    }
    fn socket(&self) -> Socket {
        let (mut socket, _) =
            tungstenite::connect(self.discovery("terminal-endpoint.json").endpoint).unwrap();
        match socket.get_mut() {
            MaybeTlsStream::Plain(stream) => stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap(),
            _ => panic!("Owned fixture must be plaintext loopback"),
        }
        socket
    }
    fn launch(&self, command: &str) -> RuntimeRef {
        self.manager
            .start(
                CommandId::new(),
                TerminalTarget {
                    session_id: SessionId::new(),
                    pane_id: PaneId::new(),
                },
                &TerminalLaunch {
                    directory: self.root.path().to_str().unwrap().into(),
                    argv: vec!["/bin/sh".into(), "-c".into(), command.into()],
                },
            )
            .unwrap()
            .runtime
    }
    fn attach(&self, socket: &mut Socket, runtime: RuntimeRef) -> AttachmentRef {
        send_command(
            socket,
            Command::Attach {
                version: 1,
                machine_id: self.machine,
                runtime,
            },
        );
        match next_event(socket) {
            Event::Attached {
                version: 1,
                machine_id,
                attachment,
                backlog,
                terminal,
            } => {
                assert_eq!(machine_id, self.machine);
                assert_eq!(terminal.runtime, runtime);
                assert_eq!(
                    backlog.next_offset - backlog.start_offset,
                    backlog.data.len() as u64
                );
                assert_eq!(backlog.truncated, backlog.start_offset != 0);
                send_command(
                    socket,
                    Command::Acknowledge {
                        attachment,
                        next_offset: backlog.next_offset,
                    },
                );
                attachment
            }
            _ => panic!("Expected captured attachment"),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        drop(self.server.take());
        self.manager.shutdown();
    }
}
fn send_command(socket: &mut Socket, command: Command) {
    socket
        .send(Message::Text(
            serde_json::to_string(&command).unwrap().into(),
        ))
        .unwrap();
}
fn next_event(socket: &mut Socket) -> Event {
    match socket.read().expect("Owned terminal event deadline") {
        Message::Text(raw) => serde_json::from_str(&raw).expect("Closed terminal event"),
        _ => panic!("Expected terminal event"),
    }
}
fn next_reply(socket: &mut Socket) -> Event {
    loop {
        match next_event(socket) {
            Event::Output {
                attachment,
                offset,
                data,
            } => send_command(
                socket,
                Command::Acknowledge {
                    attachment,
                    next_offset: offset + data.len() as u64,
                },
            ),
            event => return event,
        }
    }
}
fn eventually(mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !predicate() {
        assert!(
            Instant::now() < deadline,
            "Owned fixture condition deadline"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn separate_plane_input_resize_detach_reconnect_and_stale_attachment_do_not_launch() {
    let fixture = Fixture::new();
    let runtime = fixture.launch("stty raw -echo; printf ready; cat");
    let sibling = fixture.launch("sleep 30");
    let mut socket = fixture.socket();
    let attachment = fixture.attach(&mut socket, runtime);
    let mut second = fixture.socket();
    send_command(
        &mut second,
        Command::Attach {
            version: 1,
            machine_id: fixture.machine,
            runtime,
        },
    );
    assert!(matches!(
        next_event(&mut second),
        Event::Rejected {
            code: ErrorCode::AlreadyAttached
        }
    ));
    drop(second);
    send_command(
        &mut socket,
        Command::Input {
            attachment,
            sequence: 0,
            data: "hello λ\n".as_bytes().to_vec(),
        },
    );
    assert!(matches!(
        next_reply(&mut socket),
        Event::InputApplied {
            sequence: 0,
            accepted_bytes: 9,
            ..
        }
    ));
    send_command(
        &mut socket,
        Command::Resize {
            attachment,
            rows: 42,
            columns: 91,
        },
    );
    assert!(matches!(
        next_reply(&mut socket),
        Event::Resized {
            rows: 42,
            columns: 91,
            ..
        }
    ));
    send_command(&mut socket, Command::Detach { attachment });
    eventually(|| {
        !fixture
            .manager
            .list()
            .iter()
            .find(|terminal| terminal.runtime == runtime)
            .unwrap()
            .attached
    });
    drop(socket);
    let mut socket = fixture.socket();
    let replacement = fixture.attach(&mut socket, runtime);
    assert_ne!(attachment, replacement);
    send_command(
        &mut socket,
        Command::Input {
            attachment,
            sequence: 0,
            data: b"must not reach PTY".to_vec(),
        },
    );
    assert!(matches!(
        next_reply(&mut socket),
        Event::Rejected {
            code: ErrorCode::StaleAttachment
        }
    ));
    eventually(|| {
        !fixture
            .manager
            .list()
            .iter()
            .find(|terminal| terminal.runtime == runtime)
            .unwrap()
            .attached
    });
    assert_eq!(fixture.manager.list().len(), 2);
    assert!(
        fixture
            .manager
            .list()
            .iter()
            .any(|terminal| terminal.runtime == sibling
                && matches!(terminal.process, ProcessState::Running { .. }))
    );
}

#[test]
fn duplicate_input_sequence_is_rejected_and_terminal_eof_is_not_a_stop_receipt() {
    let fixture = Fixture::new();
    let runtime = fixture.launch("stty -echo; printf ready; read value; printf final");
    let mut socket = fixture.socket();
    let attachment = fixture.attach(&mut socket, runtime);
    send_command(
        &mut socket,
        Command::Input {
            attachment,
            sequence: 0,
            data: b"done\n".to_vec(),
        },
    );
    let mut applied = false;
    let mut final_output = false;
    loop {
        match next_event(&mut socket) {
            Event::InputApplied {
                sequence: 0,
                accepted_bytes: 5,
                ..
            } => applied = true,
            Event::Output {
                attachment,
                offset,
                data,
            } => {
                final_output |= data.windows(5).any(|chunk| chunk == b"final");
                send_command(
                    &mut socket,
                    Command::Acknowledge {
                        attachment,
                        next_offset: offset + data.len() as u64,
                    },
                );
            }
            Event::Exited { wait_status: 0, .. } => break,
            _ => panic!("Unexpected EOF fixture event"),
        }
    }
    assert!(applied && final_output);
    assert_eq!(fixture.manager.list().len(), 1);
    // Sequence fencing is connection-local; it never promises durable replay.
    let mut connection = Connection::new(attachment);
    connection.next_input = 1;
    assert!(matches!(
        connection.apply(
            Command::Input {
                attachment,
                sequence: 0,
                data: b"duplicate".to_vec()
            },
            &fixture.manager,
            ClientId::new()
        ),
        Err(ErrorCode::InvalidRequest)
    ));
}

#[test]
fn slow_terminal_reader_loses_only_its_lease_and_control_rpc_remains_available() {
    let fixture = Fixture::new();
    let runtime = fixture.launch("stty -echo; read value; yes z");
    let mut socket = fixture.socket();
    let attachment = fixture.attach(&mut socket, runtime);
    send_command(
        &mut socket,
        Command::Input {
            attachment,
            sequence: 0,
            data: b"go\n".to_vec(),
        },
    );
    // Withhold output acknowledgements, without pausing the daemon PTY drain.
    eventually(|| !fixture.manager.list()[0].attached);
    assert!(matches!(
        fixture.manager.list()[0].process,
        ProcessState::Running { .. }
    ));
    let control = fixture.discovery("local-endpoint.json");
    assert_ne!(
        control.endpoint,
        fixture.discovery("terminal-endpoint.json").endpoint
    );
    let (mut control, _) = tungstenite::connect(control.endpoint).unwrap();
    control.send(Message::Text(r#"{"jsonrpc":"2.0","id":1,"method":"axo.protocol.negotiate","params":{"protocolVersion":1}}"#.into())).unwrap();
    assert!(matches!(control.read().unwrap(), Message::Text(_)));
    assert_eq!(fixture.manager.list().len(), 1);
}

#[test]
fn browser_and_cross_plane_requests_are_rejected_and_discovery_is_private() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let fixture = Fixture::new();
    let discovery = fixture.discovery("terminal-endpoint.json");
    let metadata =
        std::fs::symlink_metadata(fixture.root.path().join("terminal-endpoint.json")).unwrap();
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    assert_eq!(metadata.nlink(), 1);
    let mut browser = discovery.endpoint.clone().into_client_request().unwrap();
    browser
        .headers_mut()
        .insert("origin", "https://example.invalid".parse().unwrap());
    assert!(tungstenite::connect(browser).is_err());
    assert!(tungstenite::connect(discovery.endpoint.replace(PATH, "/v1/rpc")).is_err());
    let runtime = fixture.launch("sleep 30");
    let mut socket = fixture.socket();
    send_command(
        &mut socket,
        Command::Attach {
            version: 1,
            machine_id: MachineId::new(),
            runtime,
        },
    );
    assert!(matches!(
        next_event(&mut socket),
        Event::Rejected {
            code: ErrorCode::StaleHost
        }
    ));
    let mut socket = fixture.socket();
    send_command(
        &mut socket,
        Command::Attach {
            version: 1,
            machine_id: fixture.machine,
            runtime: RuntimeRef {
                host_generation: HostGeneration::new(),
                ..runtime
            },
        },
    );
    assert!(matches!(
        next_event(&mut socket),
        Event::Rejected {
            code: ErrorCode::StaleHost
        }
    ));
    assert!(!fixture.manager.list()[0].attached);
}

#[test]
fn closed_codec_and_exact_credit_boundaries_reject_unknown_and_forged_fields() {
    assert!(serde_json::from_str::<Command>(r#"{"type":"axo.session.start"}"#).is_err());
    let attachment = AttachmentRef {
        runtime: RuntimeRef {
            host_generation: HostGeneration::new(),
            target: TerminalTarget {
                session_id: SessionId::new(),
                pane_id: PaneId::new(),
            },
            runtime_generation: RuntimeGeneration::new(),
        },
        attachment_id: AttachmentId::new(),
    };
    let raw = serde_json::to_value(Command::Detach { attachment }).unwrap();
    let mut extra = raw.clone();
    extra
        .as_object_mut()
        .unwrap()
        .insert("unexpected".into(), true.into());
    assert!(serde_json::from_value::<Command>(extra).is_err());
    let mut extra = raw;
    extra["attachment"]["runtime"]["unexpected"] = true.into();
    assert!(serde_json::from_value::<Command>(extra).is_err());
    let root = TestDirectory::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    let mut connection = Connection::new(attachment);
    let owner = ClientId::new();
    for data in [Vec::new(), vec![0; INPUT_BYTES + 1]] {
        assert!(matches!(
            connection.apply(
                Command::Input {
                    attachment,
                    sequence: 0,
                    data
                },
                &manager,
                owner
            ),
            Err(ErrorCode::InvalidRequest)
        ));
        assert_eq!(connection.next_input, 0);
    }
    assert!(matches!(
        connection.apply(
            Command::Resize {
                attachment,
                rows: 501,
                columns: 80
            },
            &manager,
            owner
        ),
        Err(ErrorCode::InvalidSize)
    ));
    let mut credits = Credits {
        outstanding: VecDeque::from([(10, 100), (20, 200)]),
        bytes: 300,
    };
    assert_eq!(credits.acknowledge(15), Err(ErrorCode::InvalidRequest));
    assert_eq!(credits.bytes, 300);
    credits.acknowledge(20).unwrap();
    assert_eq!(credits.bytes, 0);
    assert_eq!(credits.acknowledge(20), Err(ErrorCode::InvalidRequest));
    credits.bytes = DELIVERY_BYTES - FRAME_BYTES;
    assert!(credits.available());
    credits.bytes += 1;
    assert!(!credits.available());
}
