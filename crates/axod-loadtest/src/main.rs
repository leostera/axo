//! Load test for axod: drives an isolated daemon with background load (catalog and terminal-output
//! subscribers, output floods, attach churn, shell/session lifecycle) while probe threads measure
//! control-plane latency on persistent connections. Exits non-zero when any request fails or a
//! latency budget is exceeded.
//!
//! Never point this at a user's daemon: it always starts its own axod with a temporary HOME and
//! the Pi fixture.

mod client;
mod daemon;
mod metrics;
mod stats;

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use clap::{Parser, ValueEnum};

use client::{
    Client, ConfigGet, Layout, NextEvents, NoParams, PaneRole, Resize, Session, SessionList,
    SessionRef, SetLayout, Shell, ShellRef, Subscribe, Subscription, TerminalInput, base64,
};
use daemon::Daemon;
use stats::{Budget, Recorder, Report};

#[derive(Clone, Copy, Debug, ValueEnum)]
enum ProfileName {
    /// Seconds-long run with light load; checks correctness and a loose latency bound.
    Smoke,
    /// The pass bar: heavy background load, control-plane p99 under 10 ms.
    Heavy,
}

#[derive(Parser)]
#[command(about = "Load test an isolated axod")]
struct Args {
    #[arg(long, value_enum, default_value = "heavy")]
    profile: ProfileName,
    /// axod binary; defaults to $AXOD_BINARY.
    #[arg(long)]
    axod: Option<PathBuf>,
    /// Pi stand-in; defaults to $AXO_TEST_PI_EXECUTABLE.
    #[arg(long)]
    pi_fixture: Option<PathBuf>,
    /// Override the profile's duration in seconds.
    #[arg(long)]
    seconds: Option<u64>,
}

/// The shape of one run.
#[derive(Clone, Copy, Debug)]
struct Profile {
    sessions: usize,
    terminals_per_session: usize,
    catalog_subscribers: usize,
    stream_subscribers: usize,
    flooders: usize,
    attach_churners: usize,
    probes: usize,
    duration: Duration,
    control_plane_p99: Duration,
    lifecycle_p99: Duration,
}

impl Profile {
    fn named(name: ProfileName) -> Profile {
        match name {
            ProfileName::Smoke => Profile {
                sessions: 2,
                terminals_per_session: 2,
                catalog_subscribers: 4,
                stream_subscribers: 1,
                flooders: 1,
                attach_churners: 1,
                probes: 2,
                duration: Duration::from_secs(3),
                // Bazel runs tests in parallel on a busy machine; smoke guards against stalls.
                control_plane_p99: Duration::from_millis(250),
                lifecycle_p99: Duration::from_secs(2),
            },
            ProfileName::Heavy => Profile {
                sessions: 8,
                terminals_per_session: 3,
                catalog_subscribers: 32,
                stream_subscribers: 4,
                flooders: 4,
                attach_churners: 2,
                probes: 4,
                duration: Duration::from_secs(20),
                control_plane_p99: Duration::from_millis(10),
                lifecycle_p99: Duration::from_millis(100),
            },
        }
    }

    fn terminal_count(&self) -> usize {
        self.sessions * self.terminals_per_session
    }
}

/// Shells set aside for each kind of worker, so no two workers race on one shell's input
/// sequence.
struct Assignment {
    flood: Vec<(String, Shell)>,
    probe: Vec<(Session, Option<Shell>)>,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let mut profile = Profile::named(args.profile);
    if let Some(seconds) = args.seconds {
        profile.duration = Duration::from_secs(seconds);
    }
    match run(&args, profile) {
        Ok(report) => {
            print!("{report}");
            if report.passed() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Err(error) => {
            eprintln!("load test could not run: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &Args, profile: Profile) -> Result<Report, String> {
    let axod = path_argument(&args.axod, "AXOD_BINARY", "--axod")?;
    let pi_fixture = path_argument(&args.pi_fixture, "AXO_TEST_PI_EXECUTABLE", "--pi-fixture")?;
    let daemon = Daemon::start(&axod, &pi_fixture)?;
    let sessions = create_sessions(&daemon, profile)?;
    let assignment = assign_shells(&sessions, profile)?;
    let lifecycle_session = create_sessions(
        &daemon,
        Profile {
            sessions: 1,
            terminals_per_session: 0,
            ..profile
        },
    )?
    .remove(0);

    let stop = Arc::new(AtomicBool::new(false));
    let recorder = Recorder::default();
    let mut workers = Vec::new();

    for index in 0..profile.catalog_subscribers {
        workers.push(spawn(&format!("catalog-{index}"), {
            let (socket, stop, recorder) = (daemon.socket(), stop.clone(), recorder.clone());
            move || subscribe_until(socket, None, false, stop, recorder)
        }));
    }
    for index in 0..profile.stream_subscribers {
        let session_id = sessions[index % sessions.len()].id.clone();
        workers.push(spawn(&format!("stream-{index}"), {
            let (socket, stop, recorder) = (daemon.socket(), stop.clone(), recorder.clone());
            move || subscribe_until(socket, Some(session_id), true, stop, recorder)
        }));
    }
    for (session_id, shell) in assignment.flood.iter().cloned() {
        workers.push(spawn(&format!("flood-{}", shell.id), {
            let (socket, recorder) = (daemon.socket(), recorder.clone());
            move || start_flood(socket, session_id, shell.id, recorder)
        }));
    }
    for index in 0..profile.attach_churners {
        let shell = assignment.flood[index % assignment.flood.len()].1.clone();
        workers.push(spawn(&format!("attach-{index}"), {
            let (stop, recorder) = (stop.clone(), recorder.clone());
            move || churn_attachments(shell, stop, recorder)
        }));
    }
    workers.push(spawn("lifecycle", {
        let (socket, stop, recorder) = (daemon.socket(), stop.clone(), recorder.clone());
        move || cycle_lifecycle(socket, lifecycle_session.id, stop, recorder)
    }));

    // Let subscribers and floods reach steady state before measuring.
    thread::sleep(Duration::from_millis(500));
    let sampler = metrics::Sampler::start(daemon.pid());
    let deadline = Instant::now() + profile.duration;
    let probes: Vec<_> = assignment
        .probe
        .into_iter()
        .enumerate()
        .map(|(index, (session, input_shell))| {
            spawn(&format!("probe-{index}"), {
                let (socket, recorder) = (daemon.socket(), recorder.clone());
                move || probe_until(socket, session, input_shell, deadline, recorder)
            })
        })
        .collect();
    for probe in probes {
        let _ = probe.join();
    }
    let process = sampler.finish();
    stop.store(true, Ordering::Relaxed);
    for worker in workers {
        let _ = worker.join();
    }
    drop(daemon);

    Ok(recorder.report(
        process,
        Budget {
            control_plane_p99: profile.control_plane_p99,
            lifecycle_p99: profile.lifecycle_p99,
        },
    ))
}

fn path_argument(flag: &Option<PathBuf>, variable: &str, name: &str) -> Result<PathBuf, String> {
    flag.clone()
        .or_else(|| std::env::var_os(variable).map(PathBuf::from))
        .ok_or_else(|| format!("pass {name} or set ${variable}"))
}

fn spawn(name: &str, work: impl FnOnce() + Send + 'static) -> thread::JoinHandle<()> {
    thread::Builder::new()
        .name(name.to_owned())
        .spawn(work)
        .expect("spawning a load-test thread")
}

fn create_sessions(daemon: &Daemon, profile: Profile) -> Result<Vec<Session>, String> {
    let mut client = daemon.connect()?;
    let mut created = Vec::new();
    for _ in 0..profile.sessions {
        let session: Session = client
            .call("axo.session.create", &NoParams {})
            .map_err(|error| format!("axo.session.create: {error}"))?;
        created.push(session.id.clone());
        for _ in 0..profile.terminals_per_session {
            client
                .call::<_, Shell>(
                    "axo.shell.create",
                    &SessionRef {
                        session_id: session.id.clone(),
                    },
                )
                .map_err(|error| format!("axo.shell.create: {error}"))?;
        }
    }
    let list: SessionList = client
        .call("axo.session.list", &NoParams {})
        .map_err(|error| format!("axo.session.list: {error}"))?;
    // As listed now, with the shells just added.
    Ok(list
        .sessions
        .into_iter()
        .filter(|session| created.contains(&session.id))
        .collect())
}

fn assign_shells(sessions: &[Session], profile: Profile) -> Result<Assignment, String> {
    let mut terminals = sessions.iter().flat_map(|session| {
        session
            .shells
            .iter()
            .filter(|shell| shell.role == PaneRole::Terminal)
            .map(move |shell| (session.id.clone(), shell.clone()))
    });
    if profile.terminal_count() < profile.flooders + profile.probes || profile.flooders == 0 {
        return Err("profile needs at least one flood shell and one terminal per probe".to_owned());
    }
    let flood: Vec<_> = terminals.by_ref().take(profile.flooders).collect();
    let probe = (0..profile.probes)
        .map(|index| {
            let input = terminals.next().map(|(_, shell)| shell);
            let session_id = input
                .as_ref()
                .map_or(&sessions[index % sessions.len()].id, |shell| {
                    &sessions
                        .iter()
                        .find(|s| s.shells.iter().any(|t| t.id == shell.id))
                        .unwrap()
                        .id
                });
            let session = sessions
                .iter()
                .find(|s| &s.id == session_id)
                .unwrap()
                .clone();
            (session, input)
        })
        .collect();
    Ok(Assignment { flood, probe })
}

fn subscribe_until(
    socket: PathBuf,
    session_id: Option<String>,
    include_terminal_output: bool,
    stop: Arc<AtomicBool>,
    recorder: Recorder,
) {
    let label = if include_terminal_output {
        "stream"
    } else {
        "catalog"
    };
    let result = (|| -> Result<(), String> {
        let mut client =
            Client::connect(&socket, Duration::from_secs(30)).map_err(|e| e.to_string())?;
        let subscription: Subscription = client
            .call(
                "axo.session.subscribe",
                &Subscribe {
                    session_id,
                    include_terminal_output,
                },
            )
            .map_err(|e| e.to_string())?;
        while !stop.load(Ordering::Relaxed) {
            let batch: client::EventBatch = client
                .call(
                    "axo.session.events.next",
                    &NextEvents {
                        subscription_id: &subscription.subscription_id,
                        timeout_ms: 500,
                        max_events: 256,
                    },
                )
                .map_err(|e| e.to_string())?;
            for event in &batch.events {
                recorder.count_event(label, &event.kind);
            }
        }
        Ok(())
    })();
    if let Err(error) = result {
        recorder.error(&format!("{label}.subscriber"), error);
    }
}

fn start_flood(socket: PathBuf, session_id: String, shell_id: i64, recorder: Recorder) {
    let command = b"while :; do seq 1 20000; done\n";
    let result = Client::connect(&socket, Duration::from_secs(10))
        .map_err(|error| error.to_string())
        .and_then(|mut client| {
            client
                .call::<_, client::Ignored>(
                    "axo.terminal.input",
                    &TerminalInput {
                        session_id,
                        shell_id,
                        sequence: 0,
                        data: base64(command),
                    },
                )
                .map_err(|error| error.to_string())
        });
    if let Err(error) = result {
        recorder.error("flood.start", error);
    }
}

fn churn_attachments(shell: Shell, stop: Arc<AtomicBool>, recorder: Recorder) {
    while !stop.load(Ordering::Relaxed) {
        let started = Instant::now();
        match daemon::attach_once(&shell.attach_socket_path, shell.id) {
            Ok(()) => recorder.latency("attach.open", started.elapsed()),
            Err(error) => recorder.error("attach.open", error),
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn cycle_lifecycle(socket: PathBuf, session_id: String, stop: Arc<AtomicBool>, recorder: Recorder) {
    let Ok(mut client) = Client::connect(&socket, Duration::from_secs(30)) else {
        recorder.error("lifecycle.connect", "could not connect".to_owned());
        return;
    };
    while !stop.load(Ordering::Relaxed) {
        let started = Instant::now();
        let shell = match client.call::<_, Shell>(
            "axo.shell.create",
            &SessionRef {
                session_id: session_id.clone(),
            },
        ) {
            Ok(shell) => shell,
            Err(error) => return recorder.error("axo.shell.create", error.to_string()),
        };
        recorder.latency("axo.shell.create", started.elapsed());
        thread::sleep(Duration::from_millis(100));
        let started = Instant::now();
        match client.call::<_, client::Ignored>(
            "axo.shell.close",
            &ShellRef {
                session_id: session_id.clone(),
                shell_id: shell.id,
            },
        ) {
            Ok(_) => recorder.latency("axo.shell.close", started.elapsed()),
            Err(error) => return recorder.error("axo.shell.close", error.to_string()),
        }
        thread::sleep(Duration::from_millis(100));
    }
}

/// Measures every control-plane call on one persistent connection, round-robin, until
/// `deadline`. `input_shell` is owned by this probe alone (input sequences are per shell).
fn probe_until(
    socket: PathBuf,
    session: Session,
    input_shell: Option<Shell>,
    deadline: Instant,
    recorder: Recorder,
) {
    let Ok(mut client) = Client::connect(&socket, Duration::from_secs(10)) else {
        return recorder.error("probe.connect", "could not connect".to_owned());
    };
    let shell_ids: Vec<i64> = session.shells.iter().map(|shell| shell.id).collect();
    let any_shell = shell_ids[0];
    let mut sequence = 0_u64;
    let mut round = 0_u32;
    while Instant::now() < deadline {
        round += 1;
        measure(&recorder, "axo.session.list", || {
            client
                .call::<_, SessionList>("axo.session.list", &NoParams {})
                .map(drop)
        });
        measure(&recorder, "axo.shell.busy", || {
            client
                .call::<_, client::Ignored>(
                    "axo.shell.busy",
                    &ShellRef {
                        session_id: session.id.clone(),
                        shell_id: any_shell,
                    },
                )
                .map(drop)
        });
        measure(&recorder, "axo.config.get", || {
            client
                .call::<_, serde::de::IgnoredAny>(
                    "axo.config.get",
                    &ConfigGet {
                        key: "shell.command",
                    },
                )
                .map(drop)
        });
        let ratio = 0.3 + f64::from(round % 5) * 0.1;
        if let Some(layout) = Layout::chain(&shell_ids, ratio) {
            measure(&recorder, "axo.session.layout.set", || {
                client
                    .call::<_, client::Ignored>(
                        "axo.session.layout.set",
                        &SetLayout {
                            session_id: session.id.clone(),
                            layout: &layout,
                        },
                    )
                    .map(drop)
            });
        }
        if let Some(shell) = &input_shell {
            let rows = 24 + round % 8;
            measure(&recorder, "axo.terminal.resize", || {
                client
                    .call::<_, client::Ignored>(
                        "axo.terminal.resize",
                        &Resize {
                            session_id: session.id.clone(),
                            shell_id: shell.id,
                            rows,
                            columns: 80,
                        },
                    )
                    .map(drop)
            });
            let input = TerminalInput {
                session_id: session.id.clone(),
                shell_id: shell.id,
                sequence,
                data: base64(b":\n"),
            };
            measure(&recorder, "axo.terminal.input", || {
                client
                    .call::<_, client::Ignored>("axo.terminal.input", &input)
                    .map(drop)
            });
            sequence += 1;
        }
        // Today's app opens a connection per call; keep measuring that cost too.
        if round.is_multiple_of(10) {
            measure(&recorder, "connect+session.list", || {
                Client::connect(&socket, Duration::from_secs(10))
                    .map_err(client::CallError::Io)
                    .and_then(|mut fresh| {
                        fresh
                            .call::<_, SessionList>("axo.session.list", &NoParams {})
                            .map(drop)
                    })
            });
        }
    }
}

fn measure(
    recorder: &Recorder,
    method: &str,
    call: impl FnOnce() -> Result<(), client::CallError>,
) {
    let started = Instant::now();
    match call() {
        Ok(()) => recorder.latency(method, started.elapsed()),
        Err(error) => recorder.error(method, error.to_string()),
    }
}
