//! Taking a transcript over from a Pi that still holds it: ask over the bridge, and on an
//! explicit restart escalate to signals aimed only at the verified Pi process group.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::io::{self, BufReader};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use axo_protocol::{SessionId, new_uuid_v4};

use crate::protocol::{Action, CommandResult, Outgoing, ProtocolVersion, Record};
use crate::{BridgeSocketPath, WriterLock, bridge, process_inspection};

const TAKEOVER_TIMEOUT: Duration = Duration::from_secs(10);
pub const BRIDGE_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
/// One budget for `lsof` and every following `ps`. They take ~0.16 s each on an idle Mac but
/// up to 1.6 s each while many processes are starting, and an explicit restart the user asked
/// for should not fail because the machine is busy. Cancellation still ends it early.
const OWNER_INSPECTION_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_LOCK_OWNERS: usize = 32;
/// How long an explicit restart waits for Pi to release its transcript before escalating: after
/// asking it to exit, then after SIGTERM, before SIGKILL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TakeoverGrace {
    pub before_terminate: Duration,
    pub before_kill: Duration,
}

impl Default for TakeoverGrace {
    fn default() -> Self {
        Self {
            before_terminate: Duration::from_secs(2),
            before_kill: Duration::from_secs(2),
        }
    }
}
const KILL_WAIT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VerifiedProcessId(libc::pid_t);

impl VerifiedProcessId {
    /// A PID a Pi reported, if it could name a Pi: above 1, a valid `pid_t`, and not Axod.
    pub fn new(pid: u64) -> io::Result<Self> {
        if pid <= 1 || pid > libc::pid_t::MAX as u64 || pid == u64::from(std::process::id()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi bridge process ID is outside the permitted range",
            ));
        }
        Ok(Self(pid as libc::pid_t))
    }

    pub fn get(self) -> libc::pid_t {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TakeoverPolicy {
    PreserveExistingProcess,
    ExplicitUserRestart,
}

// Keep the authenticated PID even if Pi rejects or misses the graceful-shutdown response.
// An explicit user restart may still terminate only this verified process group.
pub struct ShutdownAttempt {
    pub process_id: VerifiedProcessId,
    pub graceful_shutdown: io::Result<()>,
}

#[derive(Clone, Debug)]
struct LockOwner {
    process_id: libc::pid_t,
    user_id: libc::uid_t,
    process_group_id: libc::pid_t,
    command: String,
}

/// The exact Pi pane a bridge connection must prove it serves, and how to reach it.
#[derive(Clone, Copy)]
pub struct BridgeTarget<'a> {
    pub bridge_socket: &'a Path,
    pub token: &'a str,
    pub session_uuid: &'a str,
    pub pane_id: &'a str,
    pub initial_pwd: &'a Path,
    pub session_file: &'a Path,
}

/// The Session whose transcript is being taken over and how to reach its current Pi.
#[derive(Clone, Copy)]
pub struct TakeoverTarget<'a> {
    pub session_id: SessionId,
    pub initial_pwd: &'a Path,
    pub session_file: &'a Path,
    pub bridge_socket: &'a BridgeSocketPath,
    pub session_uuid: &'a str,
    pub pane_id: &'a str,
    /// The current Pi's bridge credential; `None` for a Pi Axo cannot address.
    pub previous_token: Option<&'a str>,
}

/// Acquires the Session's writer lock, taking it over from the running Pi if needed.
/// `PreserveExistingProcess` only asks an idle Pi to exit; `ExplicitUserRestart` may terminate
/// the verified Pi process group. `signal` must re-check cancellation before signalling.
pub fn take_over(
    target: TakeoverTarget<'_>,
    takeover_policy: TakeoverPolicy,
    grace: TakeoverGrace,
    check_current: &impl Fn() -> io::Result<()>,
    signal: &impl Fn(VerifiedProcessId, libc::c_int) -> io::Result<()>,
) -> io::Result<WriterLock> {
    let TakeoverTarget {
        session_id,
        initial_pwd,
        session_file,
        bridge_socket,
        session_uuid,
        pane_id,
        previous_token,
    } = target;
    check_current()?;
    match WriterLock::acquire_settled(session_file, check_current) {
        Ok(lock) => Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            log::info!(
                "event=session.pi_takeover_requested session_id={}",
                session_id.get()
            );
            let shutdown_attempt = match previous_token {
                Some(token) => match request_shutdown(
                    BridgeTarget {
                        bridge_socket: bridge_socket.as_path(),
                        token,
                        session_uuid,
                        pane_id,
                        initial_pwd,
                        session_file,
                    },
                    takeover_policy,
                    check_current,
                ) {
                    Ok(attempt) => attempt,
                    Err(error)
                        if takeover_policy == TakeoverPolicy::ExplicitUserRestart
                            && bridge_unavailable_for_restart(&error) =>
                    {
                        check_current()?;
                        shutdown_attempt_from_lock(session_id, session_file, error, check_current)?
                    }
                    Err(error) => return Err(error),
                },
                None if takeover_policy == TakeoverPolicy::ExplicitUserRestart => {
                    check_current()?;
                    shutdown_attempt_from_lock(
                        session_id,
                        session_file,
                        io::Error::new(
                            io::ErrorKind::ConnectionRefused,
                            "Pi bridge credential is unavailable",
                        ),
                        check_current,
                    )?
                }
                None => {
                    return Err(io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "Pi transcript is held by a legacy writer that cannot be controlled by RPC",
                    ));
                }
            };
            let lock = match takeover_policy {
                TakeoverPolicy::PreserveExistingProcess => {
                    shutdown_attempt.graceful_shutdown?;
                    WriterLock::wait(session_file, TAKEOVER_TIMEOUT, check_current)?
                }
                TakeoverPolicy::ExplicitUserRestart => {
                    if let Err(error) = &shutdown_attempt.graceful_shutdown {
                        log::warn!(
                            "event=session.pi_shutdown_unconfirmed session_id={} error_kind={:?}",
                            session_id.get(),
                            error.kind()
                        );
                    }
                    wait_then_terminate(
                        session_file,
                        shutdown_attempt.process_id,
                        grace,
                        check_current,
                        signal,
                    )?
                }
            };
            log::info!(
                "event=session.pi_takeover_completed session_id={}",
                session_id.get()
            );
            Ok(lock)
        }
        Err(error) => Err(error),
    }
}

fn wait_then_terminate(
    session_file: &Path,
    process_id: VerifiedProcessId,
    grace: TakeoverGrace,
    check_current: &impl Fn() -> io::Result<()>,
    signal: &impl Fn(VerifiedProcessId, libc::c_int) -> io::Result<()>,
) -> io::Result<WriterLock> {
    match WriterLock::wait(session_file, grace.before_terminate, check_current) {
        Ok(lock) => return Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
        Err(error) => return Err(error),
    }
    match WriterLock::acquire(session_file) {
        Ok(lock) => return Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
        Err(error) => return Err(error),
    }

    log::warn!(
        "event=session.pi_force_termination_started pid={}",
        process_id.0
    );
    signal(process_id, libc::SIGTERM)?;
    match WriterLock::wait(session_file, grace.before_kill, check_current) {
        Ok(lock) => {
            log::info!("event=session.pi_force_termination_completed signal=term");
            return Ok(lock);
        }
        Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
        Err(error) => return Err(error),
    }
    match WriterLock::acquire(session_file) {
        Ok(lock) => return Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
        Err(error) => return Err(error),
    }

    signal(process_id, libc::SIGKILL)?;
    let lock = WriterLock::wait(session_file, KILL_WAIT, check_current).map_err(|error| {
        if error.kind() == io::ErrorKind::TimedOut {
            io::Error::new(
                io::ErrorKind::TimedOut,
                "Pi still holds its transcript lock after termination",
            )
        } else {
            error
        }
    })?;
    log::info!("event=session.pi_force_termination_completed signal=kill");
    Ok(lock)
}

fn connect_to_bridge(
    target: BridgeTarget<'_>,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<(BufReader<UnixStream>, VerifiedProcessId)> {
    let BridgeTarget {
        bridge_socket,
        token,
        session_uuid,
        pane_id,
        initial_pwd,
        session_file,
    } = target;
    let mut stream = bridge::connect_until(bridge_socket, deadline, check_current)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    bridge::write_record(
        &mut stream,
        &Outgoing::Authenticate {
            protocol_version: ProtocolVersion,
            token,
        },
    )?;
    let mut reader = BufReader::new(stream);
    let mut authenticated = false;
    loop {
        match bridge::read_record_until(&mut reader, deadline, check_current)? {
            Record::Authenticated { .. } => authenticated = true,
            Record::Hello { identity, .. } if authenticated => {
                let process_id = VerifiedProcessId::new(identity.process_id)?;
                let exact_identity = identity.axo_session_id == session_uuid
                    && identity.axo_pane_id == pane_id
                    && identity.session_file.as_deref() == Some(session_file)
                    && identity.cwd == initial_pwd;
                if !exact_identity {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "Pi bridge identity did not match the Session being taken over",
                    ));
                }
                return Ok((reader, process_id));
            }
            Record::ProtocolError { .. } => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Pi bridge rejected takeover authentication",
                ));
            }
            Record::Event { .. } => {}
            Record::Hello { .. } | Record::CommandResult { .. } => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Pi bridge sent an invalid takeover handshake",
                ));
            }
        }
    }
}

fn request_shutdown(
    target: BridgeTarget<'_>,
    takeover_policy: TakeoverPolicy,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<ShutdownAttempt> {
    let session_uuid = target.session_uuid;
    check_current()?;
    let deadline = Instant::now() + BRIDGE_REQUEST_TIMEOUT;
    let (mut reader, process_id) = connect_to_bridge(target, deadline, check_current)?;
    check_current()?;
    let request_id = format!("takeover-{}", new_uuid_v4()?);
    let action = match takeover_policy {
        TakeoverPolicy::PreserveExistingProcess => Action::ShutdownIfIdle,
        TakeoverPolicy::ExplicitUserRestart => Action::Shutdown,
    };
    let command = Outgoing::Command {
        request_id: &request_id,
        axo_session_id: session_uuid,
        action,
    };
    let graceful_shutdown = bridge::write_record(reader.get_mut(), &command).and_then(|()| {
        loop {
            match bridge::read_record_until(&mut reader, deadline, check_current)? {
                Record::CommandResult {
                    request_id: answered,
                    result,
                } if answered == request_id => {
                    return match result {
                        CommandResult::Accepted => Ok(()),
                        CommandResult::Rejected(_) => Err(io::Error::new(
                            io::ErrorKind::WouldBlock,
                            "Pi did not accept the graceful takeover request",
                        )),
                    };
                }
                _ => continue,
            }
        }
    });
    Ok(ShutdownAttempt {
        process_id,
        graceful_shutdown,
    })
}

/// Sends one command to the Pi behind `target` on a connection of its own and returns Pi's
/// answer. The worker's long-lived connection only listens; commands never share it.
pub fn send_command(
    target: BridgeTarget<'_>,
    action: Action<'_>,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<CommandResult> {
    let deadline = Instant::now() + BRIDGE_REQUEST_TIMEOUT;
    let (mut reader, _) = connect_to_bridge(target, deadline, check_current)?;
    let request_id = format!("axod-{}", new_uuid_v4()?);
    bridge::write_record(
        reader.get_mut(),
        &Outgoing::Command {
            request_id: &request_id,
            axo_session_id: target.session_uuid,
            action,
        },
    )?;
    loop {
        if let Record::CommandResult {
            request_id: answered,
            result,
        } = bridge::read_record_until(&mut reader, deadline, check_current)?
            && answered == request_id
        {
            return Ok(result);
        }
    }
}

pub fn signal_verified_process(
    process_id: VerifiedProcessId,
    signal: libc::c_int,
) -> io::Result<()> {
    // Pi is launched as a new session, so its authenticated PID must still lead its own group.
    // SAFETY: getpgid only inspects the validated PID returned by the Pi bridge.
    let process_group = unsafe { libc::getpgid(process_id.0) };
    if process_group == -1 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        return Err(error);
    }
    if process_group != process_id.0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "authenticated Pi process is no longer its own session leader",
        ));
    }

    // SAFETY: the group ID equals the PID from the exact authenticated session/pane identity.
    if unsafe { libc::kill(-process_id.0, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Ok(());
    }
    Err(error)
}

fn shutdown_attempt_from_lock(
    session_id: SessionId,
    session_file: &Path,
    error: io::Error,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<ShutdownAttempt> {
    let started = Instant::now();
    let process_id = writer_process_id_from_lock(session_file, check_current).inspect_err(|error| {
        log::info!(
            "event=session.pi_lock_inspection_rejected session_id={} elapsed_ms={} error_kind={:?}",
            session_id.get(), started.elapsed().as_millis(), error.kind()
        );
    })?;
    log::warn!(
        "event=session.pi_process_verified_by_lock session_id={} pid={} elapsed_ms={}",
        session_id.get(),
        process_id.0,
        started.elapsed().as_millis()
    );
    Ok(ShutdownAttempt {
        process_id,
        graceful_shutdown: Err(error),
    })
}

fn bridge_unavailable_for_restart(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::TimedOut
            | io::ErrorKind::WouldBlock
            | io::ErrorKind::UnexpectedEof
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotFound
    )
}

fn writer_process_id_from_lock(
    session_file: &Path,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<VerifiedProcessId> {
    let deadline = Instant::now() + OWNER_INSPECTION_TIMEOUT;
    let lock_path = session_file.with_extension("jsonl.lock");
    let output = process_inspection::run(
        Command::new("/usr/sbin/lsof")
            .args(["-n", "-P", "-t"])
            .arg(&lock_path),
        deadline,
        check_current,
    )?;
    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no process owns the Pi transcript lock",
        ));
    }

    let process_ids = parse_lock_process_ids(&output.stdout)?;

    let mut owners = Vec::with_capacity(process_ids.len());
    for process_id in process_ids {
        let output = process_inspection::run(
            Command::new("/bin/ps").args([
                "-p",
                &process_id.to_string(),
                "-o",
                "uid=",
                "-o",
                "pgid=",
                "-o",
                "comm=",
            ]),
            deadline,
            check_current,
        )?;
        if !output.status.success() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi transcript lock owner exited during verification",
            ));
        }
        owners.push(parse_lock_owner(process_id, &output.stdout)?);
    }

    check_current()?;
    if Instant::now() >= deadline {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Pi owner inspection timed out",
        ));
    }
    let process_id = verified_lock_owner(&owners, unsafe { libc::getuid() })?;
    // SAFETY: getpgid inspects the process that lsof and ps identified as this user's Pi lock owner.
    if unsafe { libc::getpgid(process_id.0) } != process_id.0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi transcript lock owner is no longer its own process-group leader",
        ));
    }
    match WriterLock::acquire(session_file) {
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(process_id),
        Ok(lock) => {
            drop(lock);
            Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi released its transcript lock during process verification",
            ))
        }
        Err(error) => Err(error),
    }
}

fn parse_lock_process_ids(output: &[u8]) -> io::Result<HashSet<libc::pid_t>> {
    if output.len() > process_inspection::MAX_INSPECTION_OUTPUT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner list exceeds its size limit",
        ));
    }
    let output = std::str::from_utf8(output)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Pi owner list is not UTF-8"))?;
    let mut process_ids = HashSet::new();
    for line in output.lines() {
        let process_id = line
            .parse::<libc::pid_t>()
            .ok()
            .filter(|pid| *pid > 1 && *pid != std::process::id() as libc::pid_t)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "lsof returned an invalid process ID",
                )
            })?;
        process_ids.insert(process_id);
        if process_ids.len() > MAX_LOCK_OWNERS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi transcript has too many lock owners",
            ));
        }
    }
    if process_ids.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no process owns the Pi transcript lock",
        ));
    }
    Ok(process_ids)
}

fn parse_lock_owner(process_id: libc::pid_t, output: &[u8]) -> io::Result<LockOwner> {
    if output.len() > process_inspection::MAX_INSPECTION_OUTPUT_BYTES || output.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner record is invalid",
        ));
    }
    let output = std::str::from_utf8(output)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Pi owner record is not UTF-8"))?
        .trim();
    if output.lines().count() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner record must contain exactly one process",
        ));
    }
    let mut fields = output.split_whitespace();
    let user_id = fields
        .next()
        .and_then(|value| value.parse::<libc::uid_t>().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Pi owner UID is invalid"))?;
    let process_group_id = fields
        .next()
        .and_then(|value| value.parse::<libc::pid_t>().ok())
        .filter(|pid| *pid > 1)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi owner process group is invalid",
            )
        })?;
    let command = fields.collect::<Vec<_>>().join(" ");
    if command.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner command is missing",
        ));
    }
    Ok(LockOwner {
        process_id,
        user_id,
        process_group_id,
        command,
    })
}

fn verified_lock_owner(
    owners: &[LockOwner],
    current_user_id: libc::uid_t,
) -> io::Result<VerifiedProcessId> {
    let mut process_groups = owners.iter().map(|owner| owner.process_group_id);
    let Some(process_group) = process_groups.next() else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no Pi process owns the transcript lock",
        ));
    };
    if owners
        .iter()
        .any(|owner| owner.user_id != current_user_id || owner.process_group_id != process_group)
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "transcript lock is shared outside one user-owned process group",
        ));
    }
    let leaders = owners.iter().filter(|owner| {
        owner.process_id == process_group
            && Path::new(&owner.command).file_name() == Some(OsStr::new("pi"))
    });
    let mut leaders = leaders;
    let Some(leader) = leaders.next() else {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "transcript lock owner is not a Pi process-group leader",
        ));
    };
    if leaders.next().is_some() || process_group <= 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "transcript lock has an ambiguous Pi process-group owner",
        ));
    }
    Ok(VerifiedProcessId(leader.process_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn an_explicit_restart_gives_pi_two_seconds_before_each_escalation() {
        assert_eq!(
            TakeoverGrace::default(),
            TakeoverGrace {
                before_terminate: Duration::from_secs(2),
                before_kill: Duration::from_secs(2),
            }
        );
    }

    #[test]
    fn a_lock_still_copied_into_a_forking_child_is_not_mistaken_for_a_live_pi() {
        // Regression: a recovery that ran while another thread was launching a process saw the
        // transcript lock as held, asked a nonexistent Pi to shut down over its bridge socket,
        // and failed with NotFound.
        let directory = crate::test_directory();
        let session_file = directory.join("session.jsonl");
        let session_uuid = axo_protocol::new_uuid_v4().unwrap();
        let bridge_socket = BridgeSocketPath::for_session(&directory, &session_uuid).unwrap();
        let lock = WriterLock::acquire(&session_file).unwrap();
        let child = crate::PausedBeforeExec::fork();
        drop(lock);
        let spawning = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            child.exec()
        });
        let target = TakeoverTarget {
            session_id: SessionId::new(1).unwrap(),
            initial_pwd: &directory,
            session_file: &session_file,
            bridge_socket: &bridge_socket,
            session_uuid: &session_uuid,
            pane_id: "pane",
            previous_token: Some("token"),
        };
        take_over(
            target,
            TakeoverPolicy::PreserveExistingProcess,
            TakeoverGrace::default(),
            &|| Ok(()),
            &|_, _| panic!("no Pi to signal"),
        )
        .unwrap();
        assert!(spawning.join().unwrap().success());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_command_is_answered_on_its_own_connection() {
        use std::io::{BufRead, Write};
        let directory = crate::test_directory();
        let session_uuid = axo_protocol::new_uuid_v4().unwrap();
        let socket = BridgeSocketPath::for_session(&directory, &session_uuid).unwrap();
        let listener = std::os::unix::net::UnixListener::bind(socket.as_path()).unwrap();
        let session_file = directory.join("session.jsonl");
        let identity = serde_json::json!({
            "axoSessionId": session_uuid,
            "axoPaneId": "pane",
            "piSessionId": "pi",
            "sessionFile": session_file,
            "cwd": directory,
            "processId": 4242,
        });
        let pi = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("\"authenticate\""), "{line}");
            for record in [
                serde_json::json!({ "type": "authenticated", "protocolVersion": 1 }),
                serde_json::json!({ "type": "hello", "protocolVersion": 1, "identity": identity }),
            ] {
                writeln!(writer, "{record}").unwrap();
            }
            line.clear();
            reader.read_line(&mut line).unwrap();
            let command: serde_json::Value = serde_json::from_str(&line).unwrap();
            let answer = serde_json::json!({
                "type": "commandResult",
                "requestId": command["requestId"],
                "result": { "accepted": true },
            });
            writeln!(writer, "{answer}").unwrap();
            command["action"].clone()
        });
        let target = BridgeTarget {
            bridge_socket: socket.as_path(),
            token: "token",
            session_uuid: &session_uuid,
            pane_id: "pane",
            initial_pwd: &directory,
            session_file: &session_file,
        };
        let action = Action::Send {
            text: "check the build",
            delivery: Some(crate::protocol::QueuedDelivery::Steer),
        };
        assert_eq!(
            send_command(target, action, &|| Ok(())).unwrap(),
            CommandResult::Accepted
        );
        assert_eq!(
            pi.join().unwrap(),
            serde_json::json!({ "kind": "send", "text": "check the build", "delivery": "steer" })
        );
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn authenticated_pi_process_ids_reject_invalid_or_self_targets() {
        for pid in [
            0,
            1,
            u64::MAX,
            libc::pid_t::MAX as u64 + 1,
            u64::from(std::process::id()),
        ] {
            assert!(VerifiedProcessId::new(pid).is_err());
        }
        assert_eq!(VerifiedProcessId::new(4242).unwrap().get(), 4242);
    }

    #[test]
    fn pi_lock_owner_pid_parser_is_bounded_and_rejects_unsafe_values() {
        let ids = (0..MAX_LOCK_OWNERS)
            .map(|index| format!("{}\n", 1_000_000 + index))
            .collect::<String>();
        assert_eq!(
            parse_lock_process_ids(ids.as_bytes()).unwrap().len(),
            MAX_LOCK_OWNERS
        );
        assert_eq!(
            parse_lock_process_ids(b"2000000\n2000000\n").unwrap().len(),
            1
        );
        let too_many = format!("{ids}2000000\n");
        assert_eq!(
            parse_lock_process_ids(too_many.as_bytes())
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        let self_id = std::process::id().to_string();
        for input in [
            b"0".as_slice(),
            b"1",
            b"-2",
            b"2147483648",
            b"pid",
            b"2\n\n3",
            b"2\0",
            &[0xff],
            self_id.as_bytes(),
        ] {
            assert_eq!(
                parse_lock_process_ids(input).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
        assert_eq!(
            parse_lock_process_ids(b"").unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            parse_lock_process_ids(&vec![
                b'2';
                process_inspection::MAX_INSPECTION_OUTPUT_BYTES + 1
            ])
            .unwrap_err()
            .kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn pi_lock_owner_record_parser_requires_one_complete_process_record() {
        let owner = parse_lock_owner(123, b"  501  123 /fixture/My Tools/pi\n").unwrap();
        assert_eq!(owner.user_id, 501);
        assert_eq!(owner.process_group_id, 123);
        assert_eq!(
            Path::new(&owner.command).file_name(),
            Some(OsStr::new("pi"))
        );
        for input in [
            b"".as_slice(),
            b"501",
            b"501 123",
            b"x 123 pi",
            b"501 -1 pi",
            b"501 0 pi",
            b"501 1 pi",
            b"501 123 pi\n501 123 other",
            b"501 123 pi\0",
            &[0xff],
        ] {
            assert_eq!(
                parse_lock_owner(123, input).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
        assert!(
            parse_lock_owner(
                123,
                &vec![b' '; process_inspection::MAX_INSPECTION_OUTPUT_BYTES + 1]
            )
            .is_err()
        );
    }

    #[test]
    fn pi_lock_owner_inspection_cancellation_cannot_authorize_takeover() {
        let directory = crate::test_directory();
        let session_file = directory.join("session.jsonl");
        let lock = WriterLock::acquire(&session_file).unwrap();
        let checks = AtomicUsize::new(0);
        let error = writer_process_id_from_lock(&session_file, &|| {
            if checks.fetch_add(1, Ordering::Relaxed) == 0 {
                Ok(())
            } else {
                Err(io::Error::from(io::ErrorKind::Interrupted))
            }
        })
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(checks.load(Ordering::Relaxed) >= 2);
        drop(lock);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn pi_lock_fallback_requires_one_user_owned_pi_process_group() {
        let owners = [
            LockOwner {
                process_id: 42,
                user_id: 501,
                process_group_id: 42,
                command: "/opt/homebrew/bin/pi".to_owned(),
            },
            LockOwner {
                process_id: 43,
                user_id: 501,
                process_group_id: 42,
                command: "node".to_owned(),
            },
        ];
        assert_eq!(verified_lock_owner(&owners, 501).unwrap().0, 42);

        let mut foreign_group = owners.clone();
        foreign_group[1].process_group_id = 44;
        assert!(verified_lock_owner(&foreign_group, 501).is_err());

        let mut foreign_user = owners.clone();
        foreign_user[0].user_id = 502;
        assert!(verified_lock_owner(&foreign_user, 501).is_err());

        let mut non_pi_leader = owners;
        non_pi_leader[0].command = "shell".to_owned();
        assert!(verified_lock_owner(&non_pi_leader, 501).is_err());
    }

    #[test]
    fn bridge_fallback_is_limited_to_unavailable_transport_errors() {
        for kind in [
            io::ErrorKind::ConnectionRefused,
            io::ErrorKind::TimedOut,
            io::ErrorKind::WouldBlock,
            io::ErrorKind::UnexpectedEof,
            io::ErrorKind::BrokenPipe,
            io::ErrorKind::ConnectionReset,
            io::ErrorKind::NotFound,
        ] {
            assert!(bridge_unavailable_for_restart(&io::Error::from(kind)));
        }
        assert!(!bridge_unavailable_for_restart(&io::Error::from(
            io::ErrorKind::PermissionDenied
        )));
        assert!(!bridge_unavailable_for_restart(&io::Error::from(
            io::ErrorKind::InvalidData
        )));
    }
}
