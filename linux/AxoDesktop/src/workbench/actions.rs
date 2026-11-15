//! Explicit creation intent, separate from the read-only catalog and viewport owners.
use super::*;
use crate::task::MainThreadTask;
use axo_protocol::rpc::{self, CreateSession};
use std::io;

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Ready,
    Pending,
    Unconfirmed,
}
enum Failure {
    NotSent(String),
    Unconfirmed(String),
}

pub(super) struct Creation {
    phase: Cell<Phase>,
    task: RefCell<Option<MainThreadTask>>,
    folder: RefCell<Option<(gtk4::FileDialog, gtk4::gio::Cancellable)>>,
    selection: Cell<Option<(SessionId, u64)>>,
    banner: gtk4::Box,
    message: gtk4::Label,
    acknowledge: gtk4::Button,
    commands: Vec<gtk4::gio::SimpleAction>,
}
impl Creation {
    pub(super) fn new() -> Self {
        let banner = gtk4::Box::new(gtk4::Orientation::Vertical, 6);
        crate::style::inset(&banner, 8, 12);
        let message = gtk4::Label::new(None);
        message.set_xalign(0.0);
        message.set_wrap(true);
        message.set_selectable(true);
        let acknowledge = gtk4::Button::with_label("Dismiss");
        acknowledge.set_halign(gtk4::Align::End);
        banner.append(&message);
        banner.append(&acknowledge);
        banner.set_visible(false);
        Self {
            phase: Cell::new(Phase::Ready),
            task: RefCell::new(None),
            folder: RefCell::new(None),
            selection: Cell::new(None),
            banner,
            message,
            acknowledge,
            commands: ["new-session", "new-home-session", "new-folder-session"]
                .into_iter()
                .map(|name| gtk4::gio::SimpleAction::new(name, None))
                .collect(),
        }
    }
    pub(super) fn widget(&self) -> &gtk4::Box {
        &self.banner
    }
    pub(super) fn update_controls(&self, enabled: bool) {
        for command in &self.commands {
            command.set_enabled(
                enabled && self.phase.get() == Phase::Ready && self.folder.borrow().is_none(),
            );
        }
    }
    pub(super) fn preferred_selection(
        &self,
        catalog: &LocalCatalog,
        revision: u64,
    ) -> Option<SessionId> {
        let (id, original) = self.selection.get()?;
        if revision != original {
            self.selection.set(None);
            return None;
        }
        if catalog.session(id).is_none() {
            return None;
        }
        self.selection.set(None);
        Some(id)
    }
    pub(super) fn shutdown(&self) {
        let dialog = self.folder.borrow_mut().take();
        if let Some((_, cancellable)) = dialog {
            cancellable.cancel();
        }
        // Cancels delivery, not an already admitted creation. The worker has its own deadline.
        self.task.borrow_mut().take();
        self.update_controls(false);
    }
    fn show(&self, message: &str, unconfirmed: bool) {
        self.message.set_text(message);
        self.acknowledge.set_label(if unconfirmed {
            "I've reviewed Sessions"
        } else {
            "Dismiss"
        });
        self.acknowledge
            .set_visible(self.phase.get() != Phase::Pending);
        self.banner.set_visible(true);
    }
}
impl Workbench {
    pub(super) fn bind_creation(self: &Rc<Self>, button: &gtk4::MenuButton) {
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let popover = gtk4::Popover::new();
        let menu = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
        for (label, action) in [
            ("New Session", "win.new-session"),
            ("New Session at Home", "win.new-home-session"),
            ("New Session in Folder…", "win.new-folder-session"),
        ] {
            let item = gtk4::Button::with_label(label);
            item.add_css_class("flat");
            item.update_property(&[gtk4::accessible::Property::Label(label)]);
            item.set_action_name(Some(action));
            item.connect_clicked({
                let popover = popover.downgrade();
                move |_| {
                    if let Some(popover) = popover.upgrade() {
                        popover.popdown();
                    }
                }
            });
            menu.append(&item);
        }
        popover.set_child(Some(&menu));
        button.set_popover(Some(&popover));
        for command in &self.creation.commands {
            let name = command.name();
            command.connect_activate({
                let weak = Rc::downgrade(self);
                move |_, _| {
                    let Some(model) = weak.upgrade() else { return };
                    match name.as_str() {
                        "new-folder-session" => model.choose_creation_folder(),
                        "new-home-session" => model.create_session(CreateSession::AtHome),
                        _ => {
                            let request = model
                                .selected
                                .get()
                                .filter(|id| {
                                    model
                                        .catalog
                                        .borrow()
                                        .as_ref()
                                        .is_some_and(|catalog| catalog.session(*id).is_some())
                                })
                                .map(CreateSession::Like)
                                .unwrap_or_default();
                            model.create_session(request);
                        }
                    }
                }
            });
            window.add_action(command);
        }
        if let Some(app) = window.application() {
            app.set_accels_for_action("win.new-session", &["<Primary>n"]);
            app.set_accels_for_action("win.new-folder-session", &["<Primary><Shift>n"]);
        }
        self.creation.acknowledge.connect_clicked({
            let weak = Rc::downgrade(self);
            move |_| {
                if let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) {
                    if model.creation.phase.get() == Phase::Pending {
                        return;
                    }
                    // Explicit acknowledgement permits a NEW intent. It never resends the old one.
                    model.creation.phase.set(Phase::Ready);
                    model.creation.banner.set_visible(false);
                    model.creation.update_controls(model.online.get());
                }
            }
        });
        self.creation.update_controls(false);
    }
    fn choose_creation_folder(self: &Rc<Self>) {
        if !self.can_create() {
            return;
        }
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let dialog = gtk4::FileDialog::builder()
            .title("New Session in Folder")
            .modal(true)
            .accept_label("Create Session")
            .build();
        let initial = self.catalog.borrow().as_ref().and_then(|catalog| {
            self.selected
                .get()
                .and_then(|id| catalog.session(id))
                .map(|session| session.folder.clone())
        });
        if let Some(folder) = initial {
            dialog.set_initial_folder(Some(&gtk4::gio::File::for_path(folder)));
        }
        let cancellable = gtk4::gio::Cancellable::new();
        *self.creation.folder.borrow_mut() = Some((dialog.clone(), cancellable.clone()));
        self.creation.update_controls(self.online.get());
        dialog.select_folder(Some(&window), Some(&cancellable), {
            let weak = Rc::downgrade(self);
            move |result| {
                let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                    return;
                };
                model.creation.folder.borrow_mut().take();
                model.creation.update_controls(model.online.get());
                match result {
                    Ok(file) => {
                        if let Some(folder) = file.path() {
                            model.create_session(CreateSession::InFolder(folder));
                        } else {
                            model
                                .creation
                                .show("Choose a local folder for this Session.", false);
                        }
                    }
                    Err(error)
                        if error.matches(gtk4::DialogError::Dismissed)
                            || error.matches(gtk4::DialogError::Cancelled)
                            || error.matches(gtk4::gio::IOErrorEnum::Cancelled) => {}
                    Err(error) => model
                        .creation
                        .show(&format!("Cannot choose folder: {error}"), false),
                }
            }
        });
    }
    fn can_create(&self) -> bool {
        !self.closing.get()
            && self.online.get()
            && self.creation.phase.get() == Phase::Ready
            && self.creation.folder.borrow().is_none()
    }
    fn create_session(self: &Rc<Self>, request: CreateSession) {
        if !self.can_create() {
            if !self.closing.get()
                && !self.online.get()
                && self.creation.phase.get() == Phase::Ready
            {
                self.creation
                    .show("Daemon unavailable; Session creation was not sent.", false);
            }
            return;
        }
        self.creation.phase.set(Phase::Pending);
        self.creation.selection.set(None);
        self.creation.update_controls(false);
        self.creation.show("Creating Session…", false);
        let revision = self.selection_revision.get();
        let previous = self.catalog.borrow().clone();
        let socket = self.socket.clone();
        let weak = Rc::downgrade(self);
        let task = MainThreadTask::start(
            "axo-session-create",
            move || execute_creation(&socket, request),
            move |result| {
                let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                    return;
                };
                model.creation.task.borrow_mut().take();
                let result = resolve_worker(result);
                let result = result.and_then(|record| {
                    if previous
                        .as_ref()
                        .is_some_and(|catalog| catalog.session(record.id).is_some())
                    {
                        Err(Failure::Unconfirmed(
                            "daemon returned an existing Session".into(),
                        ))
                    } else {
                        Ok(record)
                    }
                });
                match result {
                    Ok(record) => {
                        model.creation.phase.set(Phase::Ready);
                        model.creation.banner.set_visible(false);
                        if model.selection_revision.get() == revision {
                            model.creation.selection.set(Some((record.id, revision)));
                        }
                    }
                    Err(Failure::NotSent(reason)) => {
                        model.creation.phase.set(Phase::Ready);
                        model
                            .creation
                            .show(&format!("Session creation was not sent: {reason}"), false);
                    }
                    Err(Failure::Unconfirmed(reason)) => {
                        model.creation.phase.set(Phase::Unconfirmed);
                        model.creation.show(&format!("Creation was not confirmed: {reason}. It may have succeeded. Review Sessions before creating another; nothing will be retried automatically."), true);
                    }
                }
                model.creation.update_controls(model.online.get());
                model.reload(); // Authoritative reconciliation only; never replay the action.
            },
        );
        match task {
            Ok(task) => *self.creation.task.borrow_mut() = Some(task),
            Err(error) => {
                self.creation.phase.set(Phase::Ready);
                self.creation
                    .show(&format!("Cannot start Session creation: {error}"), false);
                self.creation.update_controls(self.online.get());
            }
        }
    }
}

// A worker/channel failure is not proof that creation was never admitted. Only
// failures explicitly classified before dispatch may enable another intent directly.
fn resolve_worker(
    result: io::Result<Result<SessionRecord, Failure>>,
) -> Result<SessionRecord, Failure> {
    result.unwrap_or_else(|error| Err(Failure::Unconfirmed(error.to_string())))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lost_worker_is_uncertain_but_explicit_preflight_failure_remains_not_sent() {
        assert!(matches!(
            resolve_worker(Err(io::Error::other("worker stopped"))),
            Err(Failure::Unconfirmed(_))
        ));
        assert!(matches!(
            resolve_worker(Ok(Err(Failure::NotSent("unsupported".into())))),
            Err(Failure::NotSent(_))
        ));
    }
}

fn execute_creation(
    socket: &std::path::Path,
    request: CreateSession,
) -> io::Result<Result<SessionRecord, Failure>> {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return Ok(Err(Failure::NotSent(error.to_string()))),
    };
    let mut dispatched = false;
    let result = runtime.block_on(async {
        tokio::time::timeout(Duration::from_secs(40), async {
            let mut client = axo_client::Client::connect(socket)
                .await
                .map_err(|error| Failure::NotSent(error.to_string()))?;
            client
                .negotiate()
                .await
                .map_err(|error| Failure::NotSent(error.to_string()))?;
            if !client.supports(rpc::method::SESSION_CREATE) {
                return Err(Failure::NotSent(
                    "the running daemon does not support Session creation".into(),
                ));
            }
            dispatched = true;
            client
                .create_session(request)
                .await
                .map_err(|error| match error {
                    axo_client::Error::Input(message) => Failure::NotSent(message),
                    // Even an RPC rejection may follow partial multi-step creation.
                    error => Failure::Unconfirmed(error.to_string()),
                })
        })
        .await
    });
    Ok(result.unwrap_or_else(|_| {
        Err(if dispatched {
            Failure::Unconfirmed("request timed out".into())
        } else {
            Failure::NotSent("connection timed out".into())
        })
    }))
}
