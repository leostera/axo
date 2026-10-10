//! Test-only process adapter around the production Manager/native PTY.
//! Not an installed endpoint, public RPC implementation, terminal parser or Pi harness.
use axod::{
    journal::Journal,
    model::*,
    runtime::{Manager, Sink},
    terminal::Frame,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::{Arc, Mutex, atomic::AtomicBool, mpsc},
    thread,
};
const LIMIT: u64 = 65_536;
type Output = Arc<Mutex<io::Stdout>>;
#[derive(Deserialize)]
#[serde(tag = "method", rename_all = "camelCase", deny_unknown_fields)]
enum Command {
    #[serde(rename_all = "camelCase")]
    Start {
        id: u64,
        command_id: CommandId,
        target: TerminalTarget,
        launch: TerminalLaunch,
    },
    Control {
        id: u64,
        runtime: RuntimeRef,
        request: Value,
    },
    List {
        id: u64,
    },
    Attach {
        id: u64,
        runtime: RuntimeRef,
    },
    Input {
        id: u64,
        attachment: AttachmentRef,
        text: String,
    },
    Resize {
        id: u64,
        attachment: AttachmentRef,
        rows: u16,
        columns: u16,
    },
    Detach {
        id: u64,
        attachment: AttachmentRef,
    },
    Stop {
        id: u64,
        runtime: RuntimeRef,
    },
    Shutdown {
        id: u64,
    },
}
fn emit(output: &Output, value: Value) {
    let mut output = output.lock().unwrap();
    if serde_json::to_writer(&mut *output, &value).is_ok() {
        let _ = output.write_all(b"\n");
        let _ = output.flush();
    }
}
fn main() -> io::Result<()> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or_else(|| io::Error::other("Fixture root required"))?,
    );
    let manager = Arc::new(Manager::new(Journal::open(&root)?));
    let mut signals = signal_hook::iterator::Signals::new([
        signal_hook::consts::SIGTERM,
        signal_hook::consts::SIGINT,
    ])?;
    let terminating = manager.clone();
    thread::spawn(move || {
        if signals.forever().next().is_some() {
            terminating.shutdown();
            std::process::exit(0);
        }
    });
    let outcome = drive(&manager);
    manager.shutdown();
    outcome
}
fn drive(manager: &Manager) -> io::Result<()> {
    let owner = ClientId::new();
    let output = Arc::new(Mutex::new(io::stdout()));
    let mut controls: BTreeMap<PaneId, (RuntimeRef, UnixStream)> = BTreeMap::new();
    let mut input = BufReader::new(io::stdin());
    loop {
        let mut bytes = Vec::new();
        let count = input
            .by_ref()
            .take(LIMIT + 1)
            .read_until(b'\n', &mut bytes)?;
        if count == 0 {
            break;
        }
        if count as u64 > LIMIT || bytes.last() != Some(&b'\n') {
            break;
        }
        let command: Command = serde_json::from_slice(&bytes)
            .map_err(|_| io::Error::other("Invalid fixture command"))?;
        let (id, result) = match command {
            Command::Start {
                id,
                command_id,
                target,
                launch,
            } => {
                let result = manager.start_with_control(command_id, target, &launch).map(
                    |(terminal, channel)| {
                        let runtime = terminal.runtime;
                        channel
                            .set_write_timeout(Some(std::time::Duration::from_millis(500)))
                            .expect("Owned channel write deadline");
                        let reader = channel.try_clone().expect("Owned channel clone");
                        let output = output.clone();
                        thread::spawn(move || {
                            let mut reader = BufReader::new(reader);
                            loop {
                                let mut bytes = Vec::new();
                                match reader
                                    .by_ref()
                                    .take(4 * 1024 * 1024 + 1)
                                    .read_until(b'\n', &mut bytes)
                                {
                                    Ok(0) | Err(_) => break,
                                    Ok(_)
                                        if bytes.len() > 4 * 1024 * 1024
                                            || bytes.last() != Some(&b'\n') =>
                                    {
                                        break;
                                    }
                                    _ => (),
                                }
                                let Ok(record) = serde_json::from_slice::<Value>(&bytes) else {
                                    break;
                                };
                                emit(
                                    &output,
                                    json!({"kind":"pi","runtime":runtime,"record":record}),
                                );
                            }
                            emit(&output, json!({"kind":"gap","runtime":runtime}));
                        });
                        controls.insert(target.pane_id, (runtime, channel));
                        json!(terminal)
                    },
                );
                (id, result)
            }
            Command::Control {
                id,
                runtime,
                request,
            } => {
                let result = controls
                    .get_mut(&runtime.target.pane_id)
                    .filter(|(reference, _)| *reference == runtime)
                    .ok_or(axod::terminal::ErrorCode::StaleRuntime)
                    .and_then(|(_, channel)| {
                        let mut raw = serde_json::to_vec(&request)
                            .map_err(|_| axod::terminal::ErrorCode::InvalidRequest)?;
                        if raw.len() > LIMIT as usize {
                            return Err(axod::terminal::ErrorCode::Capacity);
                        }
                        raw.push(b'\n');
                        channel
                            .write_all(&raw)
                            .map_err(|_| axod::terminal::ErrorCode::RecoveryRequired)?;
                        Ok(json!({"dispatched":true}))
                    });
                (id, result)
            }
            Command::List { id } => (id, Ok(json!(manager.list()))),
            Command::Attach { id, runtime } => {
                let (sender, receiver) = mpsc::sync_channel(16);
                let sink = Sink {
                    sender,
                    disconnected: Arc::new(AtomicBool::new(false)),
                };
                let result = manager.attach(runtime, owner, sink).map(|attached| {
                    let output = output.clone();
                    thread::spawn(move || { while let Ok(frame) = receiver.recv() { if let Frame::Output { data, .. } = frame { emit(&output, json!({"kind":"terminalBytes","runtime":runtime,"count":data.len()})); } } });
                    json!(attached.attachment)
                });
                (id, result)
            }
            Command::Input {
                id,
                attachment,
                text,
            } => (
                id,
                manager
                    .input(attachment, owner, text.as_bytes())
                    .map(|count| json!(count)),
            ),
            Command::Resize {
                id,
                attachment,
                rows,
                columns,
            } => (
                id,
                manager
                    .resize(attachment, owner, rows, columns)
                    .map(|_| json!(null)),
            ),
            Command::Detach { id, attachment } => {
                (id, manager.detach(attachment, owner).map(|_| json!(null)))
            }
            Command::Stop { id, runtime } => (id, manager.stop(runtime).map(|_| json!(null))),
            Command::Shutdown { id } => {
                manager.shutdown();
                emit(&output, json!({"id":id,"result":null}));
                break;
            }
        };
        let reply = match result {
            Ok(value) => json!({"id":id,"result":value}),
            Err(code) => json!({"id":id,"error":code}),
        };
        emit(&output, reply);
    }
    Ok(())
}
