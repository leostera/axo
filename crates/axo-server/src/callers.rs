//! Which Session a local caller belongs to (RFD0073): the Session whose pane it runs under.
//!
//! Any process running as the person can reach the socket and name any Session, so a request's
//! own word for whom it acts is no proof. What it cannot change is its ancestry: every Pi and
//! terminal is a child axod started, and an agent's tools (`axod mcp`, the CLI, a script from
//! Pi's shell) run under it. A caller belongs to a Session when it, or a process it descends
//! from, is one of that Session's panes, still axod's child.
//!
//! A pane's pid cannot pass to another process while axod has not reaped it, which is why the
//! pane must still be axod's child. The caller's own pid is the one the kernel gave when it
//! connected; a process started after that is a later one with a reused pid, and is no caller.
//! A process that left its pane's tree (a daemon reparented to launchd) belongs to no Session.
//!
//! Typing into a pane is acting in its Session, as the person at its keyboard: only the person
//! (the signed Axo.app, or the account through the relay) or that Session's own processes may.
//! A pane showing another Mac's Session belongs to that Session.
//!
//! Codex and OpenCode run their tools, `axod mcp` among them, under a server axod starts for the
//! Session beside its pane (RFD0072); while it runs, that server counts as one of its panes.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axo_agent::process::ProcessIdentity;
use axo_ipc::peer::{Peer, Signer};
use axo_protocol::SessionId;
use axo_protocol::rpc::error_code;
use jsonrpc_core::{Error as RpcError, ErrorCode};

use crate::core::Core;

/// How far up a caller's ancestry a pane is looked for: a shell, a runtime and a tool or two
/// deep is typical; a chain this long is no agent's.
const MAX_ANCESTRY: usize = 64;

/// The Session `peer` belongs to, if any.
pub(crate) fn session_of(core: &Core, peer: &Peer) -> Option<SessionId> {
    let caller = caller_process(peer)?;
    let panes = local_panes(core);
    pane_ancestor(caller, &panes, ProcessIdentity::of(std::process::id())?)
}

/// Refuses a request from `peer` that acts as `claimed` unless it belongs to that Session.
pub(crate) fn act_as(core: &Core, peer: &Peer, claimed: SessionId) -> Result<(), RpcError> {
    if session_of(core, peer) == Some(claimed) {
        return Ok(());
    }
    log::warn!("event=caller.refused claimed_session_id={claimed}");
    Err(not_that_session())
}

/// Whether `peer` is the person: the signed Axo.app here, or the account through the relay.
pub(crate) fn is_the_person(peer: &Peer) -> bool {
    matches!(peer, Peer::Relay) || peer.is(Signer::AxoApp)
}

/// Pane control: the person or the Session's own processes, plus Linux's exact
/// daemon-managed desktop for open local Sessions (RFD0086), never its descendants.
pub(crate) fn may_type_into(core: &Core, peer: &Peer, session: SessionId) -> bool {
    #[cfg(target_os = "linux")]
    if core.registry.contains(session)
        && caller_process(peer).is_some_and(|caller| core.desktop.owns(caller))
    {
        return true;
    }
    is_the_person(peer) || session_of(core, peer) == Some(session)
}

/// Refuses typing into `session`'s panes unless [`may_type_into`].
pub(crate) fn type_into(core: &Core, peer: &Peer, session: SessionId) -> Result<(), RpcError> {
    if may_type_into(core, peer, session) {
        return Ok(());
    }
    log::warn!("event=caller.input_refused session_id={session}");
    Err(not_that_session())
}

pub(crate) fn not_that_session() -> RpcError {
    RpcError {
        code: ErrorCode::ServerError(error_code::NOT_THAT_SESSION),
        message: "a Session acts only as itself: this caller does not run in that Session".into(),
        data: None,
    }
}

/// The process that connected, unless its pid now names a later one.
fn caller_process(peer: &Peer) -> Option<ProcessIdentity> {
    let connected = peer.process()?;
    still_the_process(connected.pid, connected.connected_at)
}

/// The process `pid` names now, if it was already running at `connected_at`.
fn still_the_process(pid: u32, connected_at: SystemTime) -> Option<ProcessIdentity> {
    let process = ProcessIdentity::of(pid)?;
    let connected_at = connected_at.duration_since(UNIX_EPOCH).ok()?;
    (Duration::from_micros(process.started) <= connected_at).then_some(process)
}

/// The agents' servers axod started for Sessions, by the pid of the process axod spawned.
#[derive(Debug, Default)]
pub(crate) struct AgentServers(Mutex<HashMap<u32, SessionId>>);

impl AgentServers {
    /// Counts `pid` as a pane of `session` until the registration is dropped, which must not
    /// come after axod reaps it.
    pub(crate) fn register(self: &Arc<Self>, pid: u32, session: SessionId) -> ServerRegistration {
        self.lock().insert(pid, session);
        ServerRegistration {
            servers: Arc::clone(self),
            pid,
        }
    }

    pub(crate) fn processes(&self) -> Vec<(u32, SessionId)> {
        self.lock().iter().map(|(pid, id)| (*pid, *id)).collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u32, SessionId>> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// A server counted as its Session's pane while this lives.
#[derive(Debug)]
pub(crate) struct ServerRegistration {
    servers: Arc<AgentServers>,
    pid: u32,
}

impl Drop for ServerRegistration {
    fn drop(&mut self) {
        self.servers.lock().remove(&self.pid);
    }
}

/// Every running pane by pid: open local Sessions', the agents' servers beside them, and those
/// showing other Macs' Sessions. A pid two Sessions claim (one's record is stale) is no one's.
fn local_panes(core: &Core) -> HashMap<u32, Option<SessionId>> {
    let mut claims = core.peers.pane_processes();
    claims.extend(core.agent_servers.processes());
    for (id, entry) in &core.catalog.view().sessions {
        if core.registry.contains(*id) {
            claims.extend(
                entry
                    .record
                    .shells
                    .iter()
                    .filter(|shell| shell.process_id > 0)
                    .map(|shell| (shell.process_id, *id)),
            );
        }
    }
    let mut panes = HashMap::new();
    for (pid, id) in claims {
        panes
            .entry(pid)
            .and_modify(|owner: &mut Option<SessionId>| {
                if *owner != Some(id) {
                    *owner = None;
                }
            })
            .or_insert(Some(id));
    }
    panes
}

/// The Session of the nearest pane `caller` is or descends from, while that pane is still
/// `axod`'s child.
fn pane_ancestor(
    caller: ProcessIdentity,
    panes: &HashMap<u32, Option<SessionId>>,
    axod: ProcessIdentity,
) -> Option<SessionId> {
    let mut process = caller;
    for _ in 0..MAX_ANCESTRY {
        let parent = process.parent()?;
        if let Some(owner) = panes.get(&process.pid)
            && parent == axod
        {
            return *owner;
        }
        if parent.pid <= 1 {
            return None;
        }
        process = parent;
    }
    None
}

#[cfg(test)]
mod tests {
    use std::process::{Child, Command};

    use super::*;

    fn identity(child: &Child) -> ProcessIdentity {
        ProcessIdentity::of(child.id()).unwrap()
    }

    fn this_process() -> ProcessIdentity {
        ProcessIdentity::of(std::process::id()).unwrap()
    }

    /// `sh` (a pane, the test's child) starts `sleep` (a tool the agent runs).
    fn pane_with_a_tool() -> (Child, ProcessIdentity) {
        let pane = Command::new("/bin/sh")
            .args(["-c", "/bin/sleep 30; :"])
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let tool = Command::new("/usr/bin/pgrep")
                .args(["-P", &pane.id().to_string()])
                .output()
                .unwrap();
            if let Some(pid) = String::from_utf8_lossy(&tool.stdout)
                .lines()
                .next()
                .and_then(|line| line.trim().parse().ok())
            {
                return (pane, ProcessIdentity::of(pid).unwrap());
            }
            assert!(std::time::Instant::now() < deadline, "sh started no tool");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn a_tool_under_a_pane_belongs_to_its_session_and_nothing_else_does() {
        let (mut pane, tool) = pane_with_a_tool();
        let (mine, other) = (SessionId::from_u128(1), SessionId::from_u128(2));
        let panes = HashMap::from([(pane.id(), Some(mine))]);
        let axod = this_process();
        assert_eq!(pane_ancestor(tool, &panes, axod), Some(mine));
        assert_eq!(
            pane_ancestor(identity(&pane), &panes, axod),
            Some(mine),
            "the pane itself"
        );
        assert_eq!(
            pane_ancestor(axod, &panes, axod),
            None,
            "axod's own caller, the test, runs under no pane"
        );
        let elsewhere = HashMap::from([(pane.id(), Some(other))]);
        assert_eq!(pane_ancestor(tool, &elsewhere, axod), Some(other));
        let contested = HashMap::from([(pane.id(), None)]);
        assert_eq!(pane_ancestor(tool, &contested, axod), None);
        // A process named like a pane but not this axod's child is not one.
        let not_axod = ProcessIdentity {
            started: axod.started + 1,
            ..axod
        };
        assert_eq!(pane_ancestor(tool, &panes, not_axod), None);
        pane.kill().unwrap();
        pane.wait().unwrap();
    }

    #[test]
    fn a_server_counts_as_its_sessions_pane_only_while_registered() {
        let servers = Arc::new(AgentServers::default());
        let session = SessionId::from_u128(1);
        let registration = servers.register(41, session);
        assert_eq!(servers.processes(), vec![(41, session)]);
        drop(registration);
        assert!(servers.processes().is_empty());
    }

    #[test]
    fn a_caller_whose_pid_names_a_later_process_is_no_caller() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let started = UNIX_EPOCH + Duration::from_micros(identity(&child).started);
        assert_eq!(
            still_the_process(child.id(), started + Duration::from_secs(1)),
            Some(identity(&child)),
            "connected while it ran"
        );
        assert_eq!(
            still_the_process(child.id(), started - Duration::from_secs(1)),
            None,
            "started after the connection: its pid was reused"
        );
        assert_eq!(
            caller_process(&Peer::default()),
            None,
            "no token, no process"
        );
        child.kill().unwrap();
        child.wait().unwrap();
    }
}
