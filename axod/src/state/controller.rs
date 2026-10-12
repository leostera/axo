//! Desired-state materializer over the existing native runtime owner. Its
//! auxiliary runtime journal is completion evidence, never a second catalog.
#[cfg(test)]
mod interactive_tests;
#[cfg(test)]
mod model_fixture;
#[cfg(test)]
mod tests;
use super::{
    Accepted, ApprovedDirectory, ApprovedHome, Attempt, AttemptPhase, Database, DesiredLifecycle,
    Error, LifecycleTarget, PaneRole, SessionGraph, WorkspaceGraph,
    execution::{Reservation, Specification},
};
use crate::{
    journal::Journal,
    model::*,
    pi_control::Control,
    pi_session::{
        Binding, Running,
        persistence::{WriterLease, validate_resume},
        session_directory,
    },
    runtime::Manager,
};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Availability {
    Live,
    Materializing,
    Restarting,
    Stopping,
    Stopped,
    Blocked,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    pub pane_id: PaneId,
    pub availability: Availability,
    pub runtime: Option<RuntimeRef>,
}

pub struct Controller {
    pub(super) database: Mutex<Database>,
    service_root: Option<super::image::Root>,
    pub(super) native: Arc<Manager>,
    policy: Option<crate::PiPolicy>,
    shells: Mutex<()>,
    pi: Mutex<()>,
    supervising: AtomicBool,
    stopped: AtomicBool,
    admitting: AtomicBool,
    pub(super) admission: Mutex<()>,
    failures: Mutex<BTreeMap<PaneId, Error>>,
}
impl Controller {
    pub fn open(
        root: &Path,
        machine: MachineId,
        policy: Option<crate::PiPolicy>,
    ) -> Result<Self, Error> {
        let database = Database::open(root, machine)?;
        let journal =
            Journal::open(&database.root.runtime_directory()?).map_err(|_| Error::UnsafeStorage)?;
        // The native journal holds only execution/completion evidence.
        let mut native = Manager::new(journal);
        native.user_shell = crate::user_shell::CapturedUserShell::capture_account();
        native.normal_path = policy
            .as_ref()
            .and_then(|policy| policy.normal_path.clone());
        Ok(Self {
            database: Mutex::new(database),
            service_root: None,
            native: Arc::new(native),
            policy,
            shells: Mutex::new(()),
            pi: Mutex::new(()),
            supervising: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            admitting: AtomicBool::new(true),
            admission: Mutex::new(()),
            failures: Mutex::new(BTreeMap::new()),
        })
    }
    pub(crate) fn for_service(
        root: &Path,
        policy: Option<crate::PiPolicy>,
    ) -> Result<(MachineId, Self), Error> {
        // Claim the same top-level lease as an old helper, without opening any
        // legacy catalog. Never interpret old session data as fresh authority.
        let lease = super::image::Root::acquire(root)?;
        let machine = crate::relay::machine_id(root).map_err(|_| Error::UnsafeStorage)?;
        let mut controller = Self::open(&lease.central_directory()?, machine, policy)?;
        controller.service_root = Some(lease);
        Ok((machine, controller))
    }
    pub(super) fn ensure_owner(&self) -> Result<(), Error> {
        if let Some(root) = &self.service_root {
            root.check_directory()?;
        }
        if !self.admitting.load(Ordering::SeqCst) || self.stopped.load(Ordering::SeqCst) {
            return Err(Error::Stopping);
        }
        Ok(())
    }
    pub(crate) fn runtime_owner(&self) -> Arc<Manager> {
        self.native.clone()
    }
    pub(crate) fn freeze_admission(&self) {
        let _gate = self.admission.lock().unwrap();
        self.admitting.store(false, Ordering::SeqCst);
        self.native.stop_admitting();
    }
    pub fn generation(&self) -> Result<StoreGeneration, Error> {
        self.ensure_owner()?;
        self.database.lock().unwrap().generation()
    }
    pub fn create_workspace(
        &self,
        command: CommandId,
        expected: u64,
        name: &str,
        directory: &ApprovedDirectory,
    ) -> Result<Accepted<WorkspaceGraph>, Error> {
        self.database
            .lock()
            .unwrap()
            .create_workspace(command, expected, name, directory)
    }
    pub fn create_session(
        &self,
        command: CommandId,
        expected: u64,
        workspace: WorkspaceId,
        name: &str,
    ) -> Result<Accepted<SessionGraph>, Error> {
        self.database
            .lock()
            .unwrap()
            .create_session(command, expected, workspace, name)
    }
    pub fn create_standalone(
        &self,
        command: CommandId,
        expected: u64,
        name: &str,
        home: &ApprovedHome,
    ) -> Result<Accepted<SessionGraph>, Error> {
        self.database
            .lock()
            .unwrap()
            .create_standalone(command, expected, name, home)
    }
    pub fn revision(&self) -> Result<u64, Error> {
        self.database.lock().unwrap().revision()
    }
    pub fn set_lifecycle(
        &self,
        command: CommandId,
        expected: u64,
        target: LifecycleTarget,
        lifecycle: DesiredLifecycle,
    ) -> Result<Accepted<LifecycleTarget>, Error> {
        self.database
            .lock()
            .unwrap()
            .set_lifecycle(command, expected, target, lifecycle)
    }
    pub fn add_shell(
        &self,
        command: CommandId,
        expected: u64,
        session: SessionId,
    ) -> Result<Accepted<super::DesiredPane>, Error> {
        self.database
            .lock()
            .unwrap()
            .add_shell(command, expected, session)
    }
    pub fn remove_shell(
        &self,
        command: CommandId,
        expected: u64,
        session: SessionId,
        pane: PaneId,
    ) -> Result<Accepted<PaneId>, Error> {
        self.database
            .lock()
            .unwrap()
            .remove_shell(command, expected, session, pane)
    }
    pub fn observations(&self) -> Result<Vec<Observation>, Error> {
        let database = self.database.lock().unwrap();
        let mut observations = Vec::new();
        for session in database.sessions()? {
            for pane in database.panes(session.session_id)? {
                let attempt = database.attempt(pane.pane_id)?;
                let specification = match database.specification(pane.pane_id) {
                    Ok(specification) => Some(specification),
                    Err(Error::NotFound) => None,
                    Err(error) => return Err(error),
                };
                let desired = specification.is_some();
                let owned_live = attempt
                    .as_ref()
                    .is_some_and(|attempt| self.live(attempt, &pane.role));
                let live = owned_live
                    && attempt.as_ref().is_some_and(|attempt| {
                        specification.as_ref().is_some_and(|spec| {
                            attempt.configuration.as_ref() == Some(&spec.configuration)
                        })
                    });
                let withdrawing = !desired
                    && attempt
                        .as_ref()
                        .is_some_and(|attempt| attempt.phase != AttemptPhase::CompletionProven);
                let outdated_live = owned_live && desired && !live;
                let availability = if live {
                    Availability::Live
                } else if outdated_live || withdrawing {
                    Availability::Stopping
                } else if !desired {
                    Availability::Stopped
                } else if self.failures.lock().unwrap().contains_key(&pane.pane_id) {
                    Availability::Blocked
                } else if attempt
                    .as_ref()
                    .is_some_and(|attempt| attempt.phase == AttemptPhase::CompletionProven)
                {
                    Availability::Restarting
                } else if attempt.is_some() {
                    Availability::Blocked
                } else {
                    Availability::Materializing
                };
                observations.push(Observation {
                    pane_id: pane.pane_id,
                    availability,
                    runtime: attempt.map(|attempt| attempt.runtime),
                });
            }
        }
        Ok(observations)
    }
    fn live(&self, attempt: &Attempt, role: &PaneRole) -> bool {
        if !self.native.owns_running_runtime(attempt.runtime) {
            return false;
        }
        if *role != PaneRole::Pi {
            return attempt.phase == AttemptPhase::Launched;
        }
        attempt.phase == AttemptPhase::Admitted
            && self
                .native
                .managed_live
                .lock()
                .unwrap()
                .get(&attempt.runtime.target.session_id)
                .is_some_and(|running| {
                    running.binding.runtime == attempt.runtime && running.control.current().is_ok()
                })
    }
    fn current(&self, spec: &Specification) -> bool {
        if self.ensure_owner().is_err() {
            return false;
        }
        self.database
            .lock()
            .unwrap()
            .specification(spec.pane.pane_id)
            .is_ok_and(|current| current.configuration == spec.configuration)
    }
    pub(super) fn reconcile_pane(&self, pane: PaneId) -> Result<Availability, Error> {
        self.ensure_owner()?;
        let (spec, previous) = {
            let database = self.database.lock().unwrap();
            (database.specification(pane)?, database.attempt(pane)?)
        };
        if let Some(previous) = previous {
            if previous.configuration.is_none() {
                return Ok(Availability::Blocked);
            }
            if spec.pane.role == PaneRole::Pi
                && self
                    .database
                    .lock()
                    .unwrap()
                    .binding(spec.pane.session_id)?
                    .is_none()
            {
                return Ok(Availability::Blocked);
            }
            if previous.phase != AttemptPhase::CompletionProven {
                if let Some(proof) = self.native.completion_evidence(previous.runtime) {
                    self.database
                        .lock()
                        .unwrap()
                        .complete_attempt(&previous, proof)?;
                    if spec.pane.role == PaneRole::Pi {
                        self.native
                            .managed_live
                            .lock()
                            .unwrap()
                            .remove(&spec.pane.session_id);
                    }
                } else if self.live(&previous, &spec.pane.role) {
                    return Ok(Availability::Live);
                } else {
                    return Ok(Availability::Blocked);
                }
            }
        }
        // Dependency probing happens before reservation, so unavailable policy
        // can retry without manufacturing an uncertain spawn attempt.
        let (launch, persistence) = self.launch(&spec)?;
        if !self.current(&spec) {
            return Err(Error::Conflict);
        }
        let reservation = self.database.lock().unwrap().reserve_attempt(
            pane,
            self.native.generation,
            spec.configuration.clone(),
        )?;
        let attempt = match reservation {
            Reservation::New(attempt) => attempt,
            Reservation::Existing(original) => {
                debug_assert_eq!(original.runtime.target.pane_id, pane);
                return Ok(Availability::Blocked);
            }
        };
        if !self.current(&spec) {
            return Ok(Availability::Blocked);
        }
        if persistence
            .as_ref()
            .is_some_and(|persistence| persistence.prepare_workspace)
        {
            session_directory::prepare(&spec.directory, spec.pane.session_id, true)
                .map_err(|_| Error::UnsafeStorage)?;
            if !self.current(&spec) {
                return Ok(Availability::Blocked);
            }
        }
        let controlled = spec.pane.role == PaneRole::Pi;
        let (terminal, socket) = self
            .native
            .start_materialized(attempt.command_id, attempt.runtime, &launch, controlled)
            .map_err(|_| Error::Storage)?;
        // Keep native ownership even if this commit fails; next observation may
        // reconcile it, but never allocates another attempt for the same pane.
        self.database
            .lock()
            .unwrap()
            .mark_launched(&attempt, terminal.runtime)?;
        if !self.current(&spec) {
            let _ = self.native.stop(terminal.runtime);
            return Ok(Availability::Stopped);
        }
        if let Some(persistence) = persistence {
            let ProcessState::Running { pid } = terminal.process else {
                return Ok(Availability::Blocked);
            };
            let control = Control::admit(
                terminal.runtime,
                pid,
                &spec.directory,
                &persistence.sessions,
                socket.ok_or(Error::Conflict)?,
            )
            .map_err(|_| Error::Conflict)?;
            let state = control.current().map_err(|_| Error::Conflict)?;
            let file = state.file.ok_or(Error::Conflict)?;
            if let Some(previous) = &persistence.previous
                && (previous.file != file || previous.chat_id != state.chat_id)
            {
                return Err(Error::Conflict);
            }
            let lease = match persistence.lease {
                Some(lease) => lease,
                None => WriterLease::acquire(&file).map_err(|_| Error::Conflict)?,
            };
            let binding = Binding {
                workspace_id: spec.workspace_id,
                session_id: spec.pane.session_id,
                pane_id: pane,
                chat_id: state.chat_id,
                runtime: terminal.runtime,
                file,
                directory: spec.directory.clone(),
                start_command_id: attempt.command_id,
            };
            let running = Arc::new(Running {
                binding: binding.clone(),
                control,
                _lease: lease,
            });
            self.native
                .managed_live
                .lock()
                .unwrap()
                .insert(binding.session_id, running);
            if !self.current(&spec) {
                let _ = self.native.stop(terminal.runtime);
                return Ok(Availability::Stopped);
            }
            self.database
                .lock()
                .unwrap()
                .admit_binding(&attempt, &binding)?;
        }
        Ok(Availability::Materializing)
    }
    fn launch(&self, spec: &Specification) -> Result<(TerminalLaunch, Option<Persistence>), Error> {
        match &spec.pane.role {
            PaneRole::AccountShell => Ok((
                self.native
                    .user_shell
                    .as_ref()
                    .and_then(|shell| shell.launch(&spec.directory))
                    .ok_or(Error::Invalid)?,
                None,
            )),
            PaneRole::ProfileShell { .. } => Err(Error::Invalid),
            PaneRole::Pi => {
                let policy = self.policy.as_ref().ok_or(Error::Invalid)?;
                let mut profile = policy
                    .profile(&spec.approval, &spec.directory)
                    .map_err(|_| Error::Invalid)?;
                let previous = self
                    .database
                    .lock()
                    .unwrap()
                    .binding(spec.pane.session_id)?;
                let mut lease = None;
                if let Some(binding) = &previous {
                    if !self.native.runtime_completed(binding.runtime) {
                        return Err(Error::Conflict);
                    }
                    if binding.file.parent()
                        == Some(
                            session_directory::path(&spec.directory, spec.pane.session_id)
                                .as_path(),
                        )
                    {
                        profile.session_directory = session_directory::prepare(
                            &spec.directory,
                            spec.pane.session_id,
                            false,
                        )
                        .map_err(|_| Error::UnsafeStorage)?;
                    }
                    validate_resume(binding, &spec.directory, &profile.session_directory)
                        .map_err(|_| Error::Conflict)?;
                    lease = Some(WriterLease::acquire(&binding.file).map_err(|_| Error::Conflict)?);
                } else if spec.workspace_id.is_some() {
                    profile.session_directory =
                        session_directory::path(&spec.directory, spec.pane.session_id);
                }
                let approved = policy
                    .launch(
                        &profile,
                        &spec.directory,
                        previous.as_ref().map(|binding| binding.file.as_path()),
                    )
                    .map_err(|_| Error::Invalid)?;
                Ok((
                    approved.terminal,
                    Some(Persistence {
                        sessions: approved.sessions,
                        prepare_workspace: spec.workspace_id.is_some() && previous.is_none(),
                        previous,
                        lease,
                    }),
                ))
            }
        }
    }
    fn reconcile_withdrawn(&self) -> Result<(), Error> {
        let mut database = self.database.lock().unwrap();
        let desired = database.desired_panes()?;
        for snapshot in self.native.list() {
            if desired
                .iter()
                .any(|pane| pane.pane_id == snapshot.runtime.target.pane_id)
            {
                continue;
            }
            if let Some(attempt) = database.attempt(snapshot.runtime.target.pane_id)?
                && attempt.runtime == snapshot.runtime
                && attempt.phase != AttemptPhase::CompletionProven
                && let Some(proof) = self.native.completion_evidence(snapshot.runtime)
            {
                database.complete_attempt(&attempt, proof)?;
                let mut running = self.native.managed_live.lock().unwrap();
                if running
                    .get(&snapshot.runtime.target.session_id)
                    .is_some_and(|running| running.binding.runtime == snapshot.runtime)
                {
                    running.remove(&snapshot.runtime.target.session_id);
                }
            } else if self.native.owns_running_runtime(snapshot.runtime) {
                let _ = self.native.stop(snapshot.runtime);
            }
        }
        Ok(())
    }
    pub fn supervise(self: &Arc<Self>) -> Result<Supervision, Error> {
        self.ensure_owner()?;
        if self.supervising.swap(true, Ordering::SeqCst) {
            return Err(Error::Conflict);
        }
        let stopping = Arc::new(AtomicBool::new(false));
        let shell = self.spawn_role(false, stopping.clone()).map_err(|_| {
            self.supervising.store(false, Ordering::SeqCst);
            Error::Storage
        })?;
        let pi = match self.spawn_role(true, stopping.clone()) {
            Ok(pi) => pi,
            Err(_) => {
                stopping.store(true, Ordering::SeqCst);
                let _ = shell.join();
                self.supervising.store(false, Ordering::SeqCst);
                return Err(Error::Storage);
            }
        };
        Ok(Supervision {
            controller: self.clone(),
            stopping,
            shell: Some(shell),
            pi: Some(pi),
        })
    }
    fn spawn_role(
        self: &Arc<Self>,
        pi: bool,
        stopping: Arc<AtomicBool>,
    ) -> std::io::Result<thread::JoinHandle<()>> {
        let controller = self.clone();
        thread::Builder::new()
            .name(
                if pi {
                    "axod-central-pi"
                } else {
                    "axod-central-shells"
                }
                .into(),
            )
            .spawn(move || {
                let _role = if pi {
                    controller.pi.lock().unwrap()
                } else {
                    controller.shells.lock().unwrap()
                };
                let mut retries = BTreeMap::<PaneId, (Instant, u32)>::new();
                while !stopping.load(Ordering::SeqCst) && !controller.stopped.load(Ordering::SeqCst)
                {
                    let panes = match controller.database.lock().unwrap().desired_panes() {
                        Ok(panes) => panes,
                        Err(_) => return, // Never turn a fenced catalog into empty intent.
                    };
                    retries.retain(|id, _| panes.iter().any(|pane| pane.pane_id == *id));
                    controller
                        .failures
                        .lock()
                        .unwrap()
                        .retain(|id, _| panes.iter().any(|pane| pane.pane_id == *id));
                    if controller.reconcile_withdrawn().is_err() {
                        return;
                    }
                    for pane in panes
                        .into_iter()
                        .filter(|pane| (pane.role == PaneRole::Pi) == pi)
                    {
                        if stopping.load(Ordering::SeqCst) {
                            break;
                        }
                        let retry = retries.entry(pane.pane_id).or_insert((Instant::now(), 0));
                        if Instant::now() < retry.0 {
                            continue;
                        }
                        let result = controller.reconcile_pane(pane.pane_id);
                        let mut failures = controller.failures.lock().unwrap();
                        if let Err(error) = result {
                            failures.insert(pane.pane_id, error);
                        } else {
                            failures.remove(&pane.pane_id);
                        }
                        drop(failures);
                        if result == Ok(Availability::Live) {
                            retry.1 = 0;
                            retry.0 = Instant::now() + Duration::from_secs(1);
                        } else {
                            retry.1 = (retry.1 + 1).min(6);
                            retry.0 = Instant::now() + Duration::from_secs(1 << retry.1);
                        }
                    }
                    thread::sleep(Duration::from_millis(100));
                }
            })
    }
    pub fn shutdown(&self) {
        if self.stopped.swap(true, Ordering::SeqCst) {
            return;
        }
        self.freeze_admission();
        self.native.shutdown();
        let Ok(mut database) = self.database.lock() else {
            return;
        };
        let Ok(sessions) = database.sessions() else {
            return;
        };
        for session in sessions {
            let Ok(panes) = database.panes(session.session_id) else {
                continue;
            };
            for pane in panes {
                if let Ok(Some(attempt)) = database.attempt(pane.pane_id)
                    && attempt.phase != AttemptPhase::CompletionProven
                    && let Some(proof) = self.native.completion_evidence(attempt.runtime)
                {
                    let _ = database.complete_attempt(&attempt, proof);
                }
            }
        }
    }
}
struct Persistence {
    sessions: std::path::PathBuf,
    prepare_workspace: bool,
    previous: Option<Binding>,
    lease: Option<WriterLease>,
}
pub struct Supervision {
    controller: Arc<Controller>,
    stopping: Arc<AtomicBool>,
    shell: Option<thread::JoinHandle<()>>,
    pi: Option<thread::JoinHandle<()>>,
}
impl Supervision {
    pub(crate) fn is_finished(&self) -> bool {
        self.shell
            .as_ref()
            .is_some_and(|worker| worker.is_finished())
            || self.pi.as_ref().is_some_and(|worker| worker.is_finished())
    }
    pub fn shutdown(mut self) -> Result<(), Error> {
        self.finish()
    }
    fn finish(&mut self) -> Result<(), Error> {
        if self.shell.is_none() && self.pi.is_none() {
            return Ok(());
        }
        self.stopping.store(true, Ordering::SeqCst);
        self.controller.freeze_admission();
        let shell = self.shell.take().map(|worker| worker.join());
        let pi = self.pi.take().map(|worker| worker.join());
        self.controller.shutdown();
        if shell.is_some_and(|result| result.is_err()) || pi.is_some_and(|result| result.is_err()) {
            return Err(Error::Storage);
        }
        Ok(())
    }
}
impl Drop for Supervision {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}
impl Drop for Controller {
    fn drop(&mut self) {
        self.shutdown();
    }
}
