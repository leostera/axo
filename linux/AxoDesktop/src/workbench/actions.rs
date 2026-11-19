//! Explicit creation intent, separate from the read-only catalog and viewport owners.
use super::*;
use crate::task::MainThreadTask;
use axo_protocol::rpc::{self, SessionLocation};
use std::io;

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Ready,
    Pending,
    Unconfirmed,
}
pub(super) enum Failure {
    NotSent(String),
    Unconfirmed(String),
}

pub(super) struct Creation {
    phase: Cell<Phase>,
    task: RefCell<Option<MainThreadTask>>,
    agents_task: RefCell<Option<MainThreadTask>>,
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
            agents_task: RefCell::new(None),
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
        self.agents_task.borrow_mut().take();
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
        let agents_box = gtk4::Box::new(gtk4::Orientation::Vertical, 2);
        menu.append(&agents_box);
        popover.connect_show({
            let weak = Rc::downgrade(self);
            let agents_box = agents_box.downgrade();
            move |popover| {
                let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                    return;
                };
                let Some(agents_box) = agents_box.upgrade() else {
                    return;
                };
                while let Some(child) = agents_box.first_child() {
                    agents_box.remove(&child);
                }
                agents_box.append(&gtk4::Label::new(Some("Checking agents…")));
                let socket = model.socket.clone();
                let weak = weak.clone();
                let popover = popover.downgrade();
                let task = MainThreadTask::start(
                    "axo-agent-discovery",
                    move || {
                        crate::task::daemon_request(&socket, |mut client| async move {
                            client
                                .call_typed::<rpc::AgentsList>(
                                    rpc::method::AGENTS_LIST,
                                    serde_json::json!({}),
                                )
                                .await
                        })
                    },
                    move |result| {
                        let Some(model) = weak.upgrade().filter(|model| !model.closing.get())
                        else {
                            return;
                        };
                        while let Some(child) = agents_box.first_child() {
                            agents_box.remove(&child);
                        }
                        let Ok(catalog) = result else {
                            agents_box.append(&gtk4::Label::new(Some(
                                "Could not check agents. Reopen to retry.",
                            )));
                            return;
                        };
                        let available = catalog
                            .agents
                            .into_iter()
                            .filter(|entry| entry.installed)
                            .collect::<Vec<_>>();
                        if available.is_empty() {
                            agents_box
                                .append(&gtk4::Label::new(Some("No coding agents available")));
                        }
                        for entry in available {
                            let agent = entry.agent;
                            let item = gtk4::Button::new();
                            item.add_css_class("flat");
                            let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
                            row.append(&agent_icon(agent));
                            row.append(&gtk4::Label::new(Some(&format!(
                                "New Session with {agent}"
                            ))));
                            item.set_child(Some(&row));
                            item.set_sensitive(model.can_create());
                            item.connect_clicked({
                                let weak = Rc::downgrade(&model);
                                let popover = popover.clone();
                                move |_| {
                                    if let Some(model) = weak.upgrade() {
                                        model.create_session_with_agent(
                                            SessionLocation::AtHome,
                                            agent,
                                        );
                                    }
                                    if let Some(popover) = popover.upgrade() {
                                        popover.popdown();
                                    }
                                }
                            });
                            agents_box.append(&item);
                        }
                    },
                );
                if let Ok(task) = task {
                    *model.creation.agents_task.borrow_mut() = Some(task);
                }
            }
        });
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
                        "new-home-session" => model.create_session(SessionLocation::AtHome),
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
                                .map(SessionLocation::Like)
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
                            model.create_session(SessionLocation::InFolder(folder));
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
    fn create_session(self: &Rc<Self>, request: SessionLocation) {
        self.create_session_with_agent(request, axo_protocol::agent::AgentKind::Pi)
    }

    fn create_session_with_agent(
        self: &Rc<Self>,
        request: SessionLocation,
        agent: axo_protocol::agent::AgentKind,
    ) {
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
            move || execute_creation(&socket, request, agent),
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
pub(super) fn resolve_worker(
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

fn agent_icon(agent: axo_protocol::agent::AgentKind) -> gtk4::Image {
    use axo_protocol::agent::AgentKind;
    let bytes: &'static [u8] = match agent {
        AgentKind::Pi => include_bytes!(
            "../../../../assets/brands/BrandLogos.xcassets/agent-pi.imageset/agent-pi.svg"
        ),
        AgentKind::Codex => include_bytes!(
            "../../../../assets/brands/BrandLogos.xcassets/agent-codex.imageset/agent-codex.svg"
        ),
        AgentKind::OpenCode => include_bytes!(
            "../../../../assets/brands/BrandLogos.xcassets/agent-opencode.imageset/agent-opencode.svg"
        ),
        AgentKind::ClaudeCode => include_bytes!(
            "../../../../assets/brands/BrandLogos.xcassets/agent-claude-code.imageset/agent-claude-code.svg"
        ),
    };
    crate::style::brand_icon(bytes)
}

fn execute_creation(
    socket: &std::path::Path,
    request: SessionLocation,
    agent: axo_protocol::agent::AgentKind,
) -> io::Result<Result<SessionRecord, Failure>> {
    execute_action(
        socket,
        rpc::method::SESSION_CREATE,
        |mut client| async move {
            let mut params: rpc::CreateSession = request.into();
            params.agent = agent;
            client.create_session(params).await
        },
    )
}

pub(super) fn execute_action<F, Fut>(
    socket: &std::path::Path,
    method: &'static str,
    operation: F,
) -> io::Result<Result<SessionRecord, Failure>>
where
    F: FnOnce(axo_client::Client) -> Fut,
    Fut: std::future::Future<Output = Result<SessionRecord, axo_client::Error>>,
{
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
            if !client.supports(method) {
                return Err(Failure::NotSent(format!(
                    "the running daemon does not support {method}"
                )));
            }
            dispatched = true;
            operation(client).await.map_err(|error| match error {
                axo_client::Error::Input(message) => Failure::NotSent(message),
                // Even an RPC rejection may follow a partial multi-step action.
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
