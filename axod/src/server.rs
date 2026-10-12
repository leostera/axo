//! launchd's serve-user owns a fresh central session store. The explicit
//! configured native harness is separate, never a production fallback.
use crate::{
    journal::Journal, local::LocalServer, profiles::Profiles, relay, runtime::Manager,
    state::controller::Controller,
};
use std::{
    io,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

pub fn serve(root: &Path) -> io::Result<()> {
    serve_with_relay(root, None)
}
pub fn serve_with_relay(root: &Path, relay: Option<relay::Config>) -> io::Result<()> {
    serve_configured(root, relay, None)
}
pub fn serve_configured(
    root: &Path,
    relay: Option<relay::Config>,
    profiles: Option<Profiles>,
) -> io::Result<()> {
    serve_with_pi(root, relay, profiles, None)
}
/// Explicit operator/owned-fixture harness for existing native public-API tests.
/// It does not run any session keep-alive policy and serve-user never calls it.
pub fn serve_with_pi(
    root: &Path,
    mut relay: Option<relay::Config>,
    profiles: Option<Profiles>,
    pi: Option<crate::PiPolicy>,
) -> io::Result<()> {
    let profiles = profiles.unwrap_or_else(|| {
        relay
            .as_ref()
            .map_or_else(Profiles::default, relay::Config::profiles)
    });
    if let Some(config) = relay.as_mut() {
        config.use_profiles(&profiles)?;
    }
    let journal = Journal::open(root)?;
    let machine = relay::machine_id(root)?;
    if !journal.managed.lock().unwrap().belongs_to(machine)
        || !journal.panes.lock().unwrap().belongs_to(machine)
    {
        return Err(io::Error::other(
            "Native harness belongs to another machine",
        ));
    }
    let mut manager = Manager::new(journal);
    manager.normal_path = pi.as_ref().and_then(|policy| policy.normal_path.clone());
    *manager.managed_policy.lock().unwrap() = pi;
    let manager = Arc::new(manager);
    let stopping = Arc::new(AtomicBool::new(false));
    let _signals = Signals::register(stopping.clone())?;
    let result = run_native(
        root,
        relay,
        profiles,
        machine,
        manager.clone(),
        stopping.clone(),
    );
    stopping.store(true, Ordering::SeqCst);
    manager.shutdown();
    result
}
pub(crate) fn serve_for_user(
    root: &Path,
    mut relay: Option<relay::Config>,
    profiles: Option<Profiles>,
    pi: crate::PiPolicy,
) -> io::Result<()> {
    if let Some(config) = relay.as_mut()
        && let Some(profiles) = profiles.as_ref()
    {
        config.use_profiles(profiles)?;
    }
    serve_central(root, relay, Some(pi))
}
/// The same authority used by launchd, exposed for disposable process fixtures.
/// Opening this root never starts, repairs or replaces an installed service.
pub fn serve_central(
    root: &Path,
    relay: Option<relay::Config>,
    pi: Option<crate::PiPolicy>,
) -> io::Result<()> {
    let (machine, controller) = Controller::for_service(root, pi).map_err(storage_error)?;
    let controller = Arc::new(controller);
    let stopping = Arc::new(AtomicBool::new(false));
    let _signals = Signals::register(stopping.clone())?;
    let result = run_central(root, relay, machine, controller.clone(), stopping.clone());
    stopping.store(true, Ordering::SeqCst);
    controller.shutdown();
    result
}
fn storage_error(error: crate::state::Error) -> io::Error {
    match error {
        crate::state::Error::OwnerConflict => io::Error::new(
            io::ErrorKind::WouldBlock,
            "Another helper owns the service root",
        ),
        _ => io::Error::other("Central session storage unavailable"),
    }
}
struct Signals {
    term: signal_hook::SigId,
    interrupt: signal_hook::SigId,
}
impl Signals {
    fn register(stopping: Arc<AtomicBool>) -> io::Result<Self> {
        let term = signal_hook::flag::register(libc::SIGTERM, stopping.clone())?;
        let interrupt = match signal_hook::flag::register(libc::SIGINT, stopping) {
            Ok(id) => id,
            Err(error) => {
                signal_hook::low_level::unregister(term);
                return Err(error);
            }
        };
        Ok(Self { term, interrupt })
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        signal_hook::low_level::unregister(self.term);
        signal_hook::low_level::unregister(self.interrupt);
    }
}
fn run_central(
    root: &Path,
    relay: Option<relay::Config>,
    machine: crate::model::MachineId,
    controller: Arc<Controller>,
    stopping: Arc<AtomicBool>,
) -> io::Result<()> {
    let supervision = controller.supervise().map_err(storage_error)?;
    let local = LocalServer::start_central(root, machine, controller.clone(), stopping.clone())?;
    let cloud = if let Some(config) = relay {
        let owner = controller.clone();
        let stop = stopping.clone();
        Some(
            thread::Builder::new()
                .name("axod-central-cloud".into())
                .spawn(move || relay::run_central(config, machine, owner, stop))?,
        )
    } else {
        None
    };
    let mut result = Ok(());
    while !stopping.load(Ordering::SeqCst) {
        if supervision.is_finished() || cloud.as_ref().is_some_and(|worker| worker.is_finished()) {
            stopping.store(true, Ordering::SeqCst);
            result = Err(io::Error::other(
                "Central service worker stopped unexpectedly",
            ));
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    // Stop public admission before joining the policy owner. Views/relay cannot
    // prolong service ownership or accidentally spawn during shutdown.
    controller.freeze_admission();
    drop(local);
    if let Some(worker) = cloud
        && worker.join().is_err()
    {
        result = Err(io::Error::other("Central relay worker failed"));
    }
    if supervision.shutdown().is_err() {
        result = Err(io::Error::other("Central materializer shutdown failed"));
    }
    result
}
fn run_native(
    root: &Path,
    relay: Option<relay::Config>,
    profiles: Profiles,
    machine: crate::model::MachineId,
    manager: Arc<Manager>,
    stopping: Arc<AtomicBool>,
) -> io::Result<()> {
    let local = LocalServer::start(root, machine, manager.clone(), profiles, stopping.clone())?;
    let cloud = if let Some(config) = relay {
        let owner = manager.clone();
        let stop = stopping.clone();
        Some(
            thread::Builder::new()
                .name("axod-native-cloud".into())
                .spawn(move || relay::run(config, machine, owner, stop))?,
        )
    } else {
        None
    };
    while !stopping.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(10));
    }
    manager.stop_admitting();
    drop(local);
    if let Some(worker) = cloud {
        let _ = worker.join();
    }
    Ok(())
}
