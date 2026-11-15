//! Foreground-selected dormant Pi intent. The catalog remains a read-only owner.
use super::actions::{Failure, execute_action, resolve_worker};
use super::*;
use crate::task::MainThreadTask;
use std::collections::BTreeMap;

type Target = (SessionId, ShellId);
#[derive(Clone, Copy, PartialEq)]
enum Intent {
    Automatic,
    Explicit,
}
enum Attempt {
    Pending,
    Reconciling,
    Failed(String),
}

#[derive(Default)]
pub(super) struct Wake {
    task: RefCell<Option<MainThreadTask>>,
    pending: Cell<Option<Target>>,
    attempts: RefCell<BTreeMap<Target, Attempt>>,
    rows: RefCell<BTreeMap<Target, (glib::WeakRef<gtk4::Label>, glib::WeakRef<gtk4::Button>)>>,
}
impl Wake {
    // Context eligibility is checked against the actual foreground window and current catalog
    // before reservation. An uncertain attempt survives selection changes and read reconnect.
    fn reserve(&self, target: Target, intent: Intent) -> bool {
        if self.pending.get().is_some()
            || (intent == Intent::Automatic && self.attempts.borrow().contains_key(&target))
        {
            return false;
        }
        self.pending.set(Some(target));
        self.attempts.borrow_mut().insert(target, Attempt::Pending);
        true
    }
    pub(super) fn reconcile(&self, catalog: &LocalCatalog) {
        self.attempts
            .borrow_mut()
            .retain(|(session_id, shell_id), attempt| {
                let shell = catalog
                    .session(*session_id)
                    .and_then(|session| session.shells.iter().find(|shell| shell.id == *shell_id));
                match shell {
                    Some(shell)
                        if shell.role == PaneRole::Pi
                            && shell.availability != Availability::Available =>
                    {
                        if matches!(attempt, Attempt::Reconciling) {
                            *attempt = Attempt::Failed(
                                "Pi is still asleep; Wake Pi makes a new unavailable-only request."
                                    .into(),
                            );
                        }
                        true
                    }
                    _ => false, // Authoritative available/gone state reconciles the attempt, never a retry.
                }
            });
        self.rows
            .borrow_mut()
            .retain(|_, (label, button)| label.upgrade().is_some() && button.upgrade().is_some());
        self.render();
    }
    fn render(&self) {
        for (target, (label, button)) in self.rows.borrow().iter() {
            let (Some(label), Some(button)) = (label.upgrade(), button.upgrade()) else {
                continue;
            };
            let attempts = self.attempts.borrow();
            let text = match attempts.get(target) {
                None => "Pi is asleep. It starts when this Session is shown.",
                Some(Attempt::Pending) => "Starting Pi…",
                Some(Attempt::Reconciling) => "Checking Pi state…",
                Some(Attempt::Failed(reason)) => reason,
            };
            label.set_text(text);
            button.set_sensitive(
                self.pending.get().is_none()
                    && !matches!(attempts.get(target), Some(Attempt::Reconciling)),
            );
        }
    }
    pub(super) fn shutdown(&self) {
        self.task.borrow_mut().take(); // Delivery only; admitted work may complete.
        self.rows.borrow_mut().clear();
    }
}
impl Workbench {
    fn looking_at_selection(&self) -> bool {
        !self.closing.get()
            && self.online.get()
            && self
                .window
                .upgrade()
                .is_some_and(|window| window.is_visible() && window.is_active())
    }
    pub(super) fn wake_selected_pi(self: &Rc<Self>) {
        if !self.looking_at_selection() {
            return;
        }
        let catalog = self.catalog.borrow().clone();
        let target = catalog
            .as_ref()
            .and_then(|catalog| self.selected.get().and_then(|id| catalog.session(id)))
            .and_then(|session| {
                session
                    .shells
                    .iter()
                    .find(|shell| {
                        shell.role == PaneRole::Pi && shell.availability == Availability::Dormant
                    })
                    .map(|shell| (session.id, shell.id))
            });
        if let Some(target) = target {
            self.wake_dormant(target, Intent::Automatic);
        }
    }
    fn wake_dormant(self: &Rc<Self>, target: Target, intent: Intent) {
        if !self.looking_at_selection() || self.selected.get() != Some(target.0) {
            return;
        }
        let eligible = self
            .catalog
            .borrow()
            .as_ref()
            .and_then(|catalog| catalog.session(target.0))
            .is_some_and(|session| {
                session.shells.iter().any(|shell| {
                    shell.id == target.1
                        && shell.role == PaneRole::Pi
                        && shell.availability == Availability::Dormant
                })
            });
        if !eligible || !self.wake.reserve(target, intent) {
            return;
        }
        self.wake.render();
        let socket = self.socket.clone();
        let weak = Rc::downgrade(self);
        let task = MainThreadTask::start(
            "axo-pi-wake",
            move || {
                execute_action(
                    &socket,
                    axo_protocol::rpc::method::SESSION_PI_RESTART_AUTO,
                    |mut client| async move { client.wake_pi(target.0, target.1).await },
                )
            },
            move |result| {
                let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                    return;
                };
                model.wake.task.borrow_mut().take();
                model.wake.pending.set(None);
                let attempt = match resolve_worker(result) {
                    Ok(_) => Attempt::Reconciling,
                    Err(Failure::NotSent(reason)) => {
                        Attempt::Failed(format!("Pi wake was not sent: {reason}"))
                    }
                    Err(Failure::Unconfirmed(reason)) => Attempt::Failed(format!(
                        "Pi wake was not confirmed: {reason}. Refresh to inspect; Wake Pi makes a new unavailable-only request."
                    )),
                };
                model.wake.attempts.borrow_mut().insert(target, attempt);
                model.wake.render();
                model.reload(); // Only authoritative reads reconcile; no replay or stale selection.
                model.wake_selected_pi(); // A newer selected target may have waited for this worker.
            },
        );
        match task {
            Ok(task) => *self.wake.task.borrow_mut() = Some(task),
            Err(error) => {
                self.wake.pending.set(None);
                self.wake.attempts.borrow_mut().insert(
                    target,
                    Attempt::Failed(format!("Cannot start Pi wake: {error}")),
                );
                self.wake.render();
            }
        }
    }
    pub(super) fn dormant_pi(
        self: &Rc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
        pane: &gtk4::Box,
    ) {
        let label = notice("Pi is asleep");
        let button = gtk4::Button::with_label("Wake Pi");
        button.set_halign(gtk4::Align::Center);
        button.set_margin_bottom(12);
        let target = (session_id, shell_id);
        button.connect_clicked({
            let weak = Rc::downgrade(self);
            move |_| {
                if let Some(model) = weak.upgrade() {
                    model.wake_dormant(target, Intent::Explicit);
                }
            }
        });
        pane.append(&label);
        pane.append(&button);
        self.wake
            .rows
            .borrow_mut()
            .insert(target, (label.downgrade(), button.downgrade()));
        self.wake.render();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn target(n: i64) -> Target {
        (SessionId::from_u128(n as u128), ShellId::new(n).unwrap())
    }
    #[test]
    fn pending_is_serial_and_uncertain_attempt_is_not_automatically_replayed() {
        let wake = Wake::default();
        let a = target(1);
        let b = target(2);
        assert!(wake.reserve(a, Intent::Automatic));
        assert!(!wake.reserve(a, Intent::Explicit));
        assert!(!wake.reserve(b, Intent::Automatic));
        wake.pending.set(None);
        wake.attempts
            .borrow_mut()
            .insert(a, Attempt::Failed("lost reply".into()));
        for _ in 0..10 {
            assert!(!wake.reserve(a, Intent::Automatic));
        }
        assert!(wake.reserve(b, Intent::Automatic));
        wake.pending.set(None);
        assert!(wake.reserve(a, Intent::Explicit));
    }
}
