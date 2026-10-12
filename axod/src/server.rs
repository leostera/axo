//! One runtime owner with local authenticated JSON-RPC and optional outbound cloud RPC.
use crate::{journal::Journal, local::LocalServer, profiles::Profiles, relay, runtime::Manager};
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
pub fn serve_with_pi(
    root: &Path,
    relay: Option<relay::Config>,
    profiles: Option<Profiles>,
    pi: Option<crate::PiPolicy>,
) -> io::Result<()> {
    serve_with_shell(
        root,
        relay,
        profiles,
        pi,
        crate::user_shell::CapturedUserShell::capture(),
        false,
    )
}
pub(crate) fn serve_for_user(
    root: &Path,
    relay: Option<relay::Config>,
    profiles: Option<Profiles>,
    pi: crate::PiPolicy,
) -> io::Result<()> {
    serve_with_shell(
        root,
        relay,
        profiles,
        Some(pi),
        crate::user_shell::CapturedUserShell::capture_account(),
        true,
    )
}
fn serve_with_shell(
    root: &Path,
    mut relay: Option<relay::Config>,
    profiles: Option<Profiles>,
    pi: Option<crate::PiPolicy>,
    user_shell: Option<crate::user_shell::CapturedUserShell>,
    session_keep_alive: bool,
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
    if !journal.managed.lock().unwrap().belongs_to(machine) {
        return Err(io::Error::other("Managed state belongs to another machine"));
    }
    if !journal.panes.lock().unwrap().belongs_to(machine) {
        return Err(io::Error::other("Pane state belongs to another machine"));
    }
    let mut manager = Manager::new(journal);
    manager.user_shell = user_shell;
    manager.session_keep_alive = session_keep_alive;
    manager.normal_path = pi.as_ref().and_then(|policy| policy.normal_path.clone());
    *manager.managed_policy.lock().unwrap() = pi;
    let manager = Arc::new(manager);
    let stopping = Arc::new(AtomicBool::new(false));
    let term = signal_hook::flag::register(libc::SIGTERM, stopping.clone())?;
    let interrupt = match signal_hook::flag::register(libc::SIGINT, stopping.clone()) {
        Ok(id) => id,
        Err(error) => {
            signal_hook::low_level::unregister(term);
            return Err(error);
        }
    };
    let result = run(
        root,
        relay,
        profiles,
        machine,
        manager.clone(),
        stopping.clone(),
    );
    stopping.store(true, Ordering::SeqCst);
    manager.shutdown();
    signal_hook::low_level::unregister(term);
    signal_hook::low_level::unregister(interrupt);
    result
}
fn run(
    root: &Path,
    relay: Option<relay::Config>,
    profiles: Profiles,
    machine: crate::model::MachineId,
    manager: Arc<Manager>,
    stopping: Arc<AtomicBool>,
) -> io::Result<()> {
    let lifecycle_profiles = profiles.0.clone();
    let local = LocalServer::start(root, machine, manager.clone(), profiles, stopping.clone())?;
    let lifecycle = if manager.session_keep_alive {
        Some(crate::session_lifecycle::spawn(
            manager.clone(),
            machine,
            lifecycle_profiles,
            stopping.clone(),
        )?)
    } else {
        None
    };
    if let Some(config) = relay {
        let manager = manager.clone();
        let stopping = stopping.clone();
        thread::Builder::new()
            .name("axod-cloud-rpc".into())
            .spawn(move || relay::run(config, machine, manager, stopping))?;
    }
    while !stopping.load(Ordering::SeqCst) {
        if lifecycle
            .as_ref()
            .is_some_and(|worker| worker.is_finished())
        {
            stopping.store(true, Ordering::SeqCst);
            return Err(io::Error::other(
                "Session lifecycle worker stopped unexpectedly",
            ));
        }
        thread::sleep(Duration::from_millis(10));
    }
    manager.stop_admitting();
    if let Some(worker) = lifecycle {
        worker
            .join()
            .map_err(|_| io::Error::other("Session lifecycle worker failed"))?;
    }
    drop(local);
    Ok(())
}
