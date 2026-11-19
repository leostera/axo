//! Live local catalog workbench. Daemon owns sessions/layout/processes; this view
//! owns selection and cancellable, detach-only Ghostty widgets. No CLI subprocess.
use crate::{
    Options, attachment::AttachmentTask, catalog_task::CatalogTask, ghostty::Engine,
    viewport_task::ViewportTask,
};
use axo_client::{CatalogState, LocalCatalog, ViewportPhase};
use axo_protocol::{
    Availability, LayoutDirection, LayoutNode, PaneRole, SessionId, SessionRecord, SessionStatus,
    ShellId,
};
use gtk4::{glib, prelude::*};
mod actions;
mod panes;
mod wake;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};

pub fn create_window(
    app: &gtk4::Application,
    engine: &Rc<Engine>,
    options: &Options,
    socket: &PathBuf,
) -> Result<(), String> {
    let window = gtk4::ApplicationWindow::builder()
        .application(app)
        .title("Axo")
        .default_width(1200)
        .default_height(760)
        .build();
    window.add_css_class("axo-window");
    window.set_size_request(760, 480);
    let root = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    let sidebar = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    sidebar.add_css_class("axo-sidebar");
    sidebar.append(&crate::style::sidebar_titlebar(&window, None));
    sidebar.set_width_request(220);
    sidebar.set_hexpand(false);
    let host = gtk4::Label::new(Some("This Computer"));
    host.set_xalign(0.0);
    host.add_css_class("axo-host-caption");
    crate::style::inset(&host, 5, 8);
    let host_row = gtk4::Box::new(gtk4::Orientation::Horizontal, 4);
    host_row.set_margin_start(8);
    host_row.append(&crate::style::brand_icon(include_bytes!(
        "../../../assets/brands/BrandLogos.xcassets/host-linux.imageset/host-linux.svg"
    )));
    host_row.append(&host);
    sidebar.append(&host_row);
    let heading = gtk4::Label::new(Some("Sessions"));
    heading.set_xalign(0.0);
    heading.add_css_class("axo-section-caption");
    heading.set_margin_start(8);
    heading.set_margin_end(8);
    heading.set_margin_top(8);
    heading.set_margin_bottom(2);
    let session_heading = gtk4::Box::new(gtk4::Orientation::Horizontal, 4);
    heading.set_hexpand(true);
    session_heading.append(&heading);
    let new_session = gtk4::MenuButton::builder()
        .icon_name("list-add-symbolic")
        .tooltip_text("New Session")
        .build();
    new_session.update_property(&[gtk4::accessible::Property::Label("New Session")]);
    new_session.set_margin_end(4);
    session_heading.append(&new_session);
    sidebar.append(&session_heading);
    let list = gtk4::ListBox::new();
    list.set_selection_mode(gtk4::SelectionMode::Single);
    list.add_css_class("axo-session-list");
    list.set_margin_start(2);
    list.set_margin_end(2);
    let scroll = gtk4::ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .hscrollbar_policy(gtk4::PolicyType::Never)
        .build();
    sidebar.append(&scroll);
    let status = gtk4::Label::new(Some("Connecting…"));
    status.set_wrap(true);
    status.set_max_width_chars(18);
    status.set_xalign(0.0);
    status.add_css_class("axo-status");
    let footer = gtk4::Box::new(gtk4::Orientation::Horizontal, 4);
    footer.add_css_class("axo-sidebar-footer");
    crate::style::inset(&footer, 4, 4);
    status.set_hexpand(true);
    footer.append(&status);
    let refresh = crate::style::icon_button("view-refresh-symbolic", "Refresh Sessions");
    footer.append(&refresh);
    let settings = crate::style::icon_button("emblem-system-symbolic", "Settings…");
    settings.set_action_name(Some("win.settings"));
    footer.append(&settings);
    sidebar.append(&footer);
    root.append(&sidebar);
    root.append(&gtk4::Separator::new(gtk4::Orientation::Vertical));
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content.set_hexpand(true);
    content.set_vexpand(true);
    let creation = actions::Creation::new();
    let detail = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    detail.set_hexpand(true);
    detail.set_vexpand(true);
    detail.append(creation.widget());
    detail.append(&content);
    root.append(&detail);
    window.set_child(Some(&root));
    let model = Rc::new(Workbench {
        window: window.downgrade(),
        engine: engine.clone(),
        options: options.clone(),
        socket: socket.clone(),
        list,
        status,
        refresh,
        content,
        catalog: RefCell::new(None),
        task: RefCell::new(None),
        epoch: Cell::new(None),
        viewport_epoch: Cell::new(0),
        viewport_task: RefCell::new(None),
        viewport_warning: RefCell::new(None),
        latest_viewport: Cell::new(None),
        last_divider: Cell::new(None),
        view_generation: Cell::new(0),
        online: Cell::new(false),
        retry_timer: RefCell::new(None),
        retry_delay: Cell::new(Duration::from_millis(500)),
        selected: Cell::new(None),
        selection_revision: Cell::new(0),
        creation,
        wake: wake::Wake::default(),
        view: RefCell::new(None),
        updating: Cell::new(false),
        closing: Cell::new(false),
        settings_window: glib::WeakRef::new(),
        tray: RefCell::new(None),
        tray_available: Cell::new(false),
        daemon_status: RefCell::new("Daemon connecting…".into()),
    });
    model.bind_creation(&new_session);
    let settings_action = gtk4::gio::SimpleAction::new("settings", None);
    settings_action.connect_activate({
        let model = Rc::downgrade(&model);
        move |_, _| {
            if let Some(model) = model.upgrade() {
                model.open_settings();
            }
        }
    });
    window.add_action(&settings_action);
    app.set_accels_for_action("win.settings", &["<Primary>comma"]);
    model.refresh.connect_clicked({
        let model = Rc::downgrade(&model);
        move |_| {
            if let Some(model) = model.upgrade() {
                model.refresh_selected();
            }
        }
    });
    model.list.connect_row_selected({
        let model = Rc::downgrade(&model);
        move |_, row| {
            let Some(model) = model.upgrade() else { return };
            if model.updating.get() {
                return;
            }
            let id = row.and_then(|row| {
                model
                    .catalog
                    .borrow()
                    .as_ref()
                    .and_then(|catalog| catalog.sessions().get(row.index() as usize))
                    .map(|session| session.id)
            });
            if let Some(id) = id {
                model.select(id);
            }
        }
    });
    window.connect_is_active_notify({
        let model = Rc::downgrade(&model);
        move |window| {
            if window.is_active() {
                if let Some(model) = model.upgrade() {
                    let view = model.view.borrow().clone();
                    if let Some(view) = view {
                        view.focus_deferred();
                        model.publish_viewport(&view);
                    }
                    model.wake_selected_pi();
                }
            }
        }
    });
    // The window owns the model; model only has a weak window. Widget callbacks
    // use Weak<Model/View>, avoiding GTK signal -> model -> widget reference cycles.
    window.connect_close_request({
        let model = model.clone();
        move |_| {
            if model.tray_available.get() {
                if let Some(window) = model.window.upgrade() {
                    window.set_visible(false);
                }
            } else {
                model.shutdown();
                model.engine.request_quit();
            }
            glib::Propagation::Stop
        }
    });
    // App-level quit/SIGTERM can bypass close-request. Drop owned views even then.
    window.connect_unrealize({
        let model = model.clone();
        move |_| model.shutdown()
    });
    window.present();
    model.start_viewport();
    model.reload();
    model.start_tray();
    Ok(())
}

struct Workbench {
    window: glib::WeakRef<gtk4::ApplicationWindow>,
    engine: Rc<Engine>,
    options: Options,
    socket: PathBuf,
    list: gtk4::ListBox,
    status: gtk4::Label,
    refresh: gtk4::Button,
    content: gtk4::Box,
    catalog: RefCell<Option<Arc<LocalCatalog>>>,
    task: RefCell<Option<CatalogTask>>,
    epoch: Cell<Option<u64>>,
    viewport_epoch: Cell<u64>,
    viewport_task: RefCell<Option<ViewportTask>>,
    viewport_warning: RefCell<Option<String>>,
    latest_viewport: Cell<Option<axo_protocol::Viewport>>,
    last_divider: Cell<Option<f64>>,
    view_generation: Cell<u64>,
    online: Cell<bool>,
    retry_timer: RefCell<Option<glib::SourceId>>,
    retry_delay: Cell<Duration>,
    selected: Cell<Option<SessionId>>,
    selection_revision: Cell<u64>,
    creation: actions::Creation,
    wake: wake::Wake,
    view: RefCell<Option<Rc<SessionView>>>,
    updating: Cell<bool>,
    closing: Cell<bool>,
    settings_window: glib::WeakRef<gtk4::Window>,
    tray: RefCell<Option<crate::tray::Tray>>,
    tray_available: Cell<bool>,
    daemon_status: RefCell<String>,
}
impl Workbench {
    fn start_tray(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        gtk4::gio::bus_get(
            gtk4::gio::BusType::Session,
            gtk4::gio::Cancellable::NONE,
            move |result| {
                let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                    return;
                };
                let Ok(connection) = result else { return }; // Workbench never depends on a tray.
                let action_model = Rc::downgrade(&model);
                let availability_model = Rc::downgrade(&model);
                let tray = crate::tray::Tray::new(
                    connection,
                    move |action| {
                        if let Some(model) = action_model.upgrade() {
                            model.tray_action(action);
                        }
                    },
                    move |available| {
                        if let Some(model) = availability_model
                            .upgrade()
                            .filter(|model| !model.closing.get())
                        {
                            model.tray_available.set(available);
                            if available {
                                model.publish_daemon_status();
                            } else if let Some(window) =
                                model.window.upgrade().filter(|window| !window.is_visible())
                            {
                                window.present();
                            }
                        }
                    },
                );
                match tray {
                    Ok(tray) => {
                        *model.tray.borrow_mut() = Some(tray);
                        model.publish_daemon_status();
                    }
                    Err(error) => eprintln!("AxoDesktop: tray unavailable: {error}"),
                }
            },
        );
    }
    fn tray_action(self: &Rc<Self>, action: crate::tray::Action) {
        if self.closing.get() {
            return;
        }
        match action {
            crate::tray::Action::Show => {
                if let Some(window) = self.window.upgrade() {
                    window.present();
                }
            }
            crate::tray::Action::Hide => {
                if self.tray_available.get() {
                    if let Some(window) = self.window.upgrade() {
                        window.set_visible(false);
                    }
                }
            }
            crate::tray::Action::Settings => {
                if let Some(window) = self.window.upgrade() {
                    window.present();
                }
                self.open_settings();
            }
            crate::tray::Action::Quit => {
                self.shutdown();
                self.engine.request_quit();
            }
        }
    }
    fn publish_daemon_status(&self) {
        if let Some(tray) = self.tray.borrow().as_ref() {
            tray.daemon_status(&self.daemon_status.borrow());
        }
    }
    fn observe_catalog(self: &Rc<Self>, state: Arc<CatalogState>) {
        if self.closing.get() {
            return;
        }
        match state.as_ref() {
            CatalogState::Connecting => {
                self.epoch.set(None);
                self.suspend_viewport();
                self.online.set(false);
                self.list.set_sensitive(false);
                self.detach_view("Connecting to daemon…");
                self.status.set_text("Connecting…");
                *self.daemon_status.borrow_mut() = "Daemon connecting…".into();
            }
            CatalogState::Reconnecting { reason } => {
                self.suspend_viewport();
                self.online.set(false);
                self.list.set_sensitive(false);
                self.detach_view("Daemon disconnected. Reconnecting…");
                self.status.set_text(&format!("Reconnecting: {reason}"));
                *self.daemon_status.borrow_mut() = "Daemon unavailable · reconnecting".into();
            }
            CatalogState::Live(snapshot) => {
                // Latest-state delivery may coalesce an entire outage. Epoch changes still
                // force fresh attachments even when IDs, PIDs and advertised paths match.
                let changed = self.epoch.replace(Some(snapshot.epoch)) != Some(snapshot.epoch);
                if changed {
                    self.viewport_epoch.set(
                        self.viewport_epoch
                            .get()
                            .checked_add(1)
                            .expect("viewport epoch exhausted"),
                    );
                    self.viewport_warning.borrow_mut().take();
                }
                if changed || !snapshot.health.ready {
                    self.suspend_viewport();
                    self.detach_view("Waiting for daemon readiness…");
                }
                self.online.set(snapshot.health.ready);
                self.list.set_sensitive(snapshot.health.ready);
                self.install_catalog(snapshot.catalog.clone());
                self.status.set_text(if !snapshot.health.ready {
                    "Daemon starting…"
                } else if self.retry_timer.borrow().is_some() {
                    "Reconnecting terminal…"
                } else {
                    ""
                });
                self.update_viewport_status();
                *self.daemon_status.borrow_mut() = format!(
                    "Daemon {} · Axo {}",
                    if snapshot.health.ready {
                        "running"
                    } else {
                        "starting"
                    },
                    snapshot.health.version
                );
            }
        }
        self.creation
            .update_controls(self.online.get() && !self.closing.get());
        self.publish_daemon_status();
    }
    fn start_viewport(self: &Rc<Self>) {
        self.viewport_task.borrow_mut().take();
        let weak = Rc::downgrade(self);
        match ViewportTask::start(self.socket.clone(), move |result| {
            let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                return;
            };
            match result {
                Ok(status) if status.epoch == model.viewport_epoch.get() => match status.phase {
                    ViewportPhase::Published | ViewportPhase::Idle => {
                        model.viewport_warning.borrow_mut().take();
                    }
                    ViewportPhase::Unsupported => {
                        *model.viewport_warning.borrow_mut() =
                            Some("Viewport pre-sizing unavailable".into())
                    }
                    ViewportPhase::Uncertain { .. } => {
                        *model.viewport_warning.borrow_mut() =
                            Some("Viewport unconfirmed; Refresh to retry".into())
                    }
                    ViewportPhase::Sending => {}
                },
                Ok(_) => return,
                Err(_) => {
                    *model.viewport_warning.borrow_mut() =
                        Some("Viewport reporter stopped; Refresh to retry".into())
                }
            }
            model.update_viewport_status();
        }) {
            Ok(task) => {
                if let Some(viewport) = self.latest_viewport.get().filter(|_| self.online.get()) {
                    task.report(self.viewport_epoch.get(), viewport);
                }
                *self.viewport_task.borrow_mut() = Some(task);
            }
            Err(_) => {
                *self.viewport_warning.borrow_mut() =
                    Some("Viewport unavailable; Refresh to retry".into());
                self.update_viewport_status();
            }
        }
    }
    fn update_viewport_status(&self) {
        if !self.online.get() || self.retry_timer.borrow().is_some() {
            return;
        }
        self.status
            .set_text(self.viewport_warning.borrow().as_deref().unwrap_or(""));
    }
    fn suspend_viewport(&self) {
        self.latest_viewport.set(None);
        if let Some(task) = self.viewport_task.borrow().as_ref() {
            task.suspend();
        }
    }
    fn publish_viewport(&self, view: &SessionView) {
        if !self.online.get()
            || self.closing.get()
            || view.needs_retry.get()
            || !self
                .window
                .upgrade()
                .is_some_and(|window| window.is_active() && window.is_visible())
            || !self
                .view
                .borrow()
                .as_ref()
                .is_some_and(|current| current.generation == view.generation)
        {
            return;
        }
        if let Some((viewport, divider)) = view.native_viewport(self.last_divider.get()) {
            self.last_divider.set(Some(divider));
            self.latest_viewport.set(Some(viewport));
            if let Some(task) = self.viewport_task.borrow().as_ref() {
                task.report(self.viewport_epoch.get(), viewport);
            }
        }
    }
    fn cancel_retry(&self) {
        if let Some(timer) = self.retry_timer.borrow_mut().take() {
            timer.remove();
        }
    }
    fn detach_view(&self, message: &str) {
        self.cancel_retry();
        self.view.borrow_mut().take();
        while let Some(child) = self.content.first_child() {
            self.content.remove(&child);
        }
        self.content.append(&notice(message));
    }
    fn refresh_selected(self: &Rc<Self>) {
        if self.closing.get() {
            return;
        }
        if self.online.get() && self.viewport_warning.borrow().is_some() {
            let retry = self
                .viewport_task
                .borrow()
                .as_ref()
                .is_some_and(ViewportTask::retry);
            if !retry {
                self.start_viewport();
            }
        }
        let retry = self
            .view
            .borrow()
            .as_ref()
            .is_some_and(|view| view.needs_retry.get());
        if retry {
            self.detach_view("Reconnecting Session…");
        }
        self.reload();
    }
    fn schedule_retry(self: &Rc<Self>, view: &Rc<SessionView>) {
        if self.closing.get()
            || !self.online.get()
            || self.retry_timer.borrow().is_some()
            || !self
                .view
                .borrow()
                .as_ref()
                .is_some_and(|current| Rc::ptr_eq(current, view))
        {
            return;
        }
        if view.began.elapsed() >= Duration::from_secs(10) {
            self.retry_delay.set(Duration::from_millis(500));
        }
        let delay = self.retry_delay.get();
        self.retry_delay
            .set((delay * 2).min(Duration::from_secs(5)));
        self.status.set_text("Reconnecting terminal…");
        let weak = Rc::downgrade(self);
        let view = Rc::downgrade(view);
        *self.retry_timer.borrow_mut() = Some(glib::timeout_add_local_once(delay, move || {
            let Some(model) = weak.upgrade() else { return };
            model.retry_timer.borrow_mut().take();
            if let Some(view) = view.upgrade() {
                if model
                    .view
                    .borrow()
                    .as_ref()
                    .is_some_and(|current| Rc::ptr_eq(current, &view))
                {
                    model.refresh_selected();
                }
            }
        }));
    }
    fn open_settings(&self) {
        if self.closing.get() {
            return;
        }
        if let Some(window) = self.settings_window.upgrade() {
            window.present();
            return;
        }
        if let Some(parent) = self.window.upgrade() {
            let window = crate::settings::show(&parent, self.socket.clone());
            self.settings_window.set(Some(&window));
        }
    }
    fn shutdown(&self) {
        if self.closing.replace(true) {
            return;
        }
        if let Some(window) = self.settings_window.upgrade() {
            window.destroy();
        }
        self.cancel_retry();
        self.creation.shutdown();
        self.wake.shutdown();
        self.viewport_task.borrow_mut().take();
        self.tray.borrow_mut().take();
        self.tray_available.set(false);
        self.task.borrow_mut().take();
        self.view.borrow_mut().take();
        while let Some(child) = self.content.first_child() {
            self.content.remove(&child);
        }
    }
    fn observer_stopped(&self, reason: &str) {
        if self.closing.get() {
            return;
        }
        self.online.set(false);
        self.creation.update_controls(false);
        self.list.set_sensitive(false);
        self.epoch.set(None);
        self.suspend_viewport();
        self.detach_view("Catalog observer stopped. Refresh Sessions to retry.");
        self.status.set_text(&format!("Observer stopped: {reason}"));
        *self.daemon_status.borrow_mut() = "Daemon status unavailable".into();
        self.publish_daemon_status();
    }
    fn reload(self: &Rc<Self>) {
        if self.closing.get() {
            return;
        }
        if self
            .task
            .borrow()
            .as_ref()
            .is_some_and(CatalogTask::refresh)
        {
            return;
        }
        self.task.borrow_mut().take();
        self.observe_catalog(Arc::new(CatalogState::Connecting));
        let weak = Rc::downgrade(self);
        match CatalogTask::start(self.socket.clone(), move |result| {
            if let Some(model) = weak.upgrade() {
                match result {
                    Ok(state) => model.observe_catalog(state),
                    Err(reason) => model.observer_stopped(&reason),
                }
            }
        }) {
            Ok(task) => *self.task.borrow_mut() = Some(task),
            Err(error) => self.observer_stopped(&error.to_string()),
        }
    }
    fn install_catalog(self: &Rc<Self>, catalog: Arc<LocalCatalog>) {
        self.wake.reconcile(&catalog);
        let selected = self
            .creation
            .preferred_selection(&catalog, self.selection_revision.get())
            .or_else(|| {
                self.selected
                    .get()
                    .filter(|id| catalog.session(*id).is_some())
            })
            .or_else(|| catalog.sessions().first().map(|session| session.id));
        self.updating.set(true);
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        for session in catalog.sessions() {
            self.list.append(&session_row(session));
        }
        let index = selected.and_then(|id| {
            catalog
                .sessions()
                .iter()
                .position(|session| session.id == id)
        });
        *self.catalog.borrow_mut() = Some(catalog);
        self.updating.set(false);
        if !self.online.get() {
            return;
        }
        if let Some(index) = index {
            self.list
                .select_row(self.list.row_at_index(index as i32).as_ref());
            // Selecting the same row may not emit the GTK signal.
            self.select(selected.expect("index came from selected identity"));
        } else {
            self.selected.set(None);
            self.view.borrow_mut().take();
            while let Some(child) = self.content.first_child() {
                self.content.remove(&child);
            }
            self.content
                .append(&gtk4::Label::new(Some("No open Sessions")));
        }
    }
    fn select(self: &Rc<Self>, id: SessionId) {
        if self.closing.get() || !self.online.get() {
            return;
        }
        let catalog = self.catalog.borrow().clone();
        let Some(catalog) = catalog else { return };
        let Some(session) = catalog.session(id) else {
            return;
        };
        if self.selected.replace(Some(id)) != Some(id) {
            self.selection_revision.set(
                self.selection_revision
                    .get()
                    .checked_add(1)
                    .expect("selection revision exhausted"),
            );
            self.retry_delay.set(Duration::from_millis(500));
        }
        if let Some(window) = self.window.upgrade() {
            window.set_title(Some(&format!(
                "Axo · {}",
                session.manual_name.as_ref().unwrap_or(&session.name)
            )));
        }
        let current = self.view.borrow().clone();
        if current.as_ref().is_some_and(|view| view.reconcile(session)) {
            self.wake_selected_pi();
            return;
        }
        let previous_focus = self
            .view
            .borrow()
            .as_ref()
            .filter(|view| view.record().id == id)
            .and_then(|view| view.focused.get());
        self.cancel_retry();
        self.view.borrow_mut().take(); // Cancels pending attachments before replacing widgets.
        while let Some(child) = self.content.first_child() {
            self.content.remove(&child);
        }
        let generation = self
            .view_generation
            .get()
            .checked_add(1)
            .expect("view generation exhausted");
        self.view_generation.set(generation);
        let view = Rc::new(SessionView {
            epoch: self.epoch.get().expect("a live catalog has an epoch"),
            generation,
            needs_retry: Cell::new(false),
            owner: Rc::downgrade(self),
            began: Instant::now(),
            session: RefCell::new(Rc::new(session.clone())),
            root: gtk4::Box::new(gtk4::Orientation::Vertical, 0),
            engine: self.engine.clone(),
            window: self.window.clone(),
            options: self.options.clone(),
            slots: RefCell::new(std::collections::BTreeMap::new()),
            focused: Cell::new(None),
            grids: RefCell::new(std::collections::BTreeMap::new()),
            splits: RefCell::new(Vec::new()),
            geometry: Cell::new(None),
            snapshot_observed: Cell::new(false),
        });
        self.content.append(&view.root);
        *self.view.borrow_mut() = Some(view.clone());
        if let Some(layout) = &session.layout {
            view.focused.set(
                previous_focus
                    .filter(|id| {
                        session.shells.iter().any(|shell| {
                            shell.id == *id
                                && shell.availability == Availability::Available
                                && layout.shell_ids().contains(id)
                        })
                    })
                    .or_else(|| {
                        session
                            .shells
                            .iter()
                            .filter(|shell| {
                                shell.availability == Availability::Available
                                    && layout.shell_ids().contains(&shell.id)
                            })
                            .min_by_key(|shell| if shell.role == PaneRole::Pi { 0 } else { 1 })
                            .map(|shell| shell.id)
                            .or_else(|| Some(first_pane(layout.root())))
                    }),
            );
            view.root.append(&view.node(layout.root()));
        } else {
            view.root
                .append(&gtk4::Label::new(Some("Session layout is not ready")));
        }
        self.wake_selected_pi();
    }
}

fn session_row(session: &SessionRecord) -> gtk4::Box {
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 4);
    crate::style::inset(&row, 0, 4);
    let sleeping = session
        .shells
        .iter()
        .any(|shell| shell.role == PaneRole::Pi && shell.availability == Availability::Dormant);
    let (class, status) = session_status_style(session.status, sleeping);
    let indicator = gtk4::Label::new(Some("●"));
    indicator.add_css_class("axo-session-status");
    indicator.add_css_class(class);
    indicator.update_property(&[gtk4::accessible::Property::Label(status)]);
    row.append(&indicator);
    if let Some(emoji) = &session.emoji {
        let glyph = gtk4::Label::new(Some(emoji));
        glyph.set_width_request(14);
        row.append(&glyph);
    } else {
        let glyph = gtk4::Image::from_icon_name(if session.has_agent() {
            "starred-symbolic"
        } else {
            "utilities-terminal-symbolic"
        });
        glyph.set_pixel_size(12);
        glyph.set_width_request(14);
        glyph.add_css_class("dim-label");
        row.append(&glyph);
    }
    let title = session.manual_name.as_ref().unwrap_or(&session.name);
    let label = gtk4::Label::new(Some(title));
    label.set_xalign(0.0);
    label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    label.set_max_width_chars(24);
    label.set_hexpand(true);
    row.append(&label);
    row.set_tooltip_text(Some(&format!(
        "{title} · {status}\n{}",
        session.folder.display()
    )));
    row
}

fn session_status_style(status: SessionStatus, sleeping: bool) -> (&'static str, &'static str) {
    match status {
        SessionStatus::NeedsAttention => ("axo-attention", "Needs attention"),
        SessionStatus::Unavailable => ("axo-unavailable", "Unavailable"),
        _ if sleeping => ("axo-unavailable", "Pi asleep"),
        SessionStatus::Ready => ("axo-ready", "Ready"),
        SessionStatus::Working => ("axo-working", "Working"),
        SessionStatus::Starting => ("axo-unavailable", "Starting"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleeping_pi_is_not_presented_as_ready_or_working() {
        for status in [
            SessionStatus::Starting,
            SessionStatus::Ready,
            SessionStatus::Working,
        ] {
            assert_eq!(
                session_status_style(status, true),
                ("axo-unavailable", "Pi asleep")
            );
        }
    }

    #[test]
    fn attention_and_failure_take_precedence_over_sleep() {
        for sleeping in [false, true] {
            assert_eq!(
                session_status_style(SessionStatus::NeedsAttention, sleeping),
                ("axo-attention", "Needs attention")
            );
            assert_eq!(
                session_status_style(SessionStatus::Unavailable, sleeping),
                ("axo-unavailable", "Unavailable")
            );
        }
    }

    #[test]
    fn live_statuses_follow_the_catalog() {
        assert_eq!(
            session_status_style(SessionStatus::Ready, false),
            ("axo-ready", "Ready")
        );
        assert_eq!(
            session_status_style(SessionStatus::Working, false),
            ("axo-working", "Working")
        );
        assert_eq!(
            session_status_style(SessionStatus::Starting, false),
            ("axo-unavailable", "Starting")
        );
    }
}

struct SessionView {
    epoch: u64,
    generation: u64,
    needs_retry: Cell<bool>,
    owner: std::rc::Weak<Workbench>,
    began: Instant,
    session: RefCell<Rc<SessionRecord>>,
    root: gtk4::Box,
    engine: Rc<Engine>,
    window: glib::WeakRef<gtk4::ApplicationWindow>,
    options: Options,
    slots: RefCell<std::collections::BTreeMap<ShellId, Rc<panes::PaneSlot>>>,
    focused: Cell<Option<ShellId>>,
    grids: RefCell<std::collections::BTreeMap<ShellId, crate::ghostty::SurfaceStats>>,
    snapshot_observed: Cell<bool>,
    splits: RefCell<Vec<gtk4::Paned>>,
    geometry: Cell<Option<crate::ghostty::WidgetGeometry>>,
}
impl SessionView {
    fn retry(self: &Rc<Self>) {
        self.needs_retry.set(true);
        if let Some(owner) = self.owner.upgrade() {
            owner.schedule_retry(self);
        }
    }
    fn node(self: &Rc<Self>, node: &LayoutNode) -> gtk4::Widget {
        match node {
            LayoutNode::Pane { shell_id } => self.pane(*shell_id).upcast(),
            LayoutNode::Split {
                direction,
                ratio,
                first,
                second,
                ..
            } => {
                let horizontal = *direction == LayoutDirection::Right;
                let split = gtk4::Paned::new(if horizontal {
                    gtk4::Orientation::Horizontal
                } else {
                    gtk4::Orientation::Vertical
                });
                split.set_hexpand(true);
                split.set_vexpand(true);
                split.set_start_child(Some(&self.node(first)));
                split.set_end_child(Some(&self.node(second)));
                split.set_resize_start_child(true);
                split.set_resize_end_child(true);
                split.set_shrink_start_child(true);
                split.set_shrink_end_child(true);
                self.splits.borrow_mut().push(split.clone());
                let ratio = *ratio;
                split.add_tick_callback(move |split, _| {
                    let size = if horizontal {
                        split.width()
                    } else {
                        split.height()
                    };
                    if size <= 0 {
                        return glib::ControlFlow::Continue;
                    }
                    let (Some(start), Some(end)) = (split.start_child(), split.end_child()) else {
                        return glib::ControlFlow::Continue;
                    };
                    let available = if horizontal {
                        start.width() + end.width()
                    } else {
                        start.height() + end.height()
                    };
                    if available <= 0 {
                        return glib::ControlFlow::Continue;
                    }
                    split.set_position((available as f64 * ratio.clamp(0.01, 0.99)).floor() as i32);
                    glib::ControlFlow::Break
                });
                split.upcast()
            }
        }
    }
    fn native_viewport(&self, last_divider: Option<f64>) -> Option<(axo_protocol::Viewport, f64)> {
        let grids = self.grids.borrow();
        let session = self.record();
        let layout = session.layout.as_ref()?;
        let expected = session
            .shells
            .iter()
            .filter(|shell| {
                shell.availability == Availability::Available
                    && layout.shell_ids().contains(&shell.id)
            })
            .count();
        if expected == 0 || grids.len() != expected {
            return None;
        }
        let first = grids.values().next()?;
        let signature = |stats: &crate::ghostty::SurfaceStats| {
            (
                stats.cell_width,
                stats.cell_height,
                stats.padding_top,
                stats.padding_bottom,
                stats.padding_left,
                stats.padding_right,
                stats.scale_x,
                stats.scale_y,
            )
        };
        if grids
            .values()
            .any(|stats| stats.ready != 1 || signature(stats) != signature(first))
            || first.scale_x != first.scale_y
        {
            return None;
        }
        let splits = self.splits.borrow();
        let mut divider = None;
        for split in splits.iter() {
            let (start, end) = (split.start_child()?, split.end_child()?);
            let gap = if split.orientation() == gtk4::Orientation::Horizontal {
                split.width() - start.width() - end.width()
            } else {
                split.height() - start.height() - end.height()
            };
            if !(0..=100).contains(&gap) || divider.is_some_and(|previous| previous != gap as f64) {
                return None;
            }
            divider = Some(gap as f64);
        }
        // A single pane cannot measure a nonexistent handle. Reuse only an actually observed
        // divider from this same workbench/style, never a guessed theme size.
        let divider = divider.or(last_divider)?;
        let geometry = crate::ghostty::widget_geometry(self.root.upcast_ref());
        if geometry.scale != first.scale_x {
            return None;
        }
        let viewport = axo_protocol::Viewport::from_native_metrics(
            axo_protocol::Size {
                width: geometry.width,
                height: geometry.height,
            },
            geometry.scale,
            axo_protocol::PixelSize {
                width: first.cell_width,
                height: first.cell_height,
            },
            axo_protocol::Padding {
                top: first.padding_top,
                bottom: first.padding_bottom,
                left: first.padding_left,
                right: first.padding_right,
            },
            divider,
            axo_protocol::ViewportOrigin {
                x: geometry.origin_x,
                y: geometry.origin_y,
            },
        )
        .ok()?;
        Some((viewport, divider))
    }

    fn record_grid(&self, id: ShellId, stats: crate::ghostty::SurfaceStats) {
        self.grids.borrow_mut().insert(id, stats);
        self.publish_metrics();
    }
    fn publish_metrics(&self) {
        if let Some(owner) = self.owner.upgrade() {
            owner.publish_viewport(self);
        }
        if let Some(path) = &self.options.diagnostics {
            let grids = self.grids.borrow();
            let panes: Vec<_> = grids.iter().map(|(id, stats)| serde_json::json!({
                "shellId":id, "ready":stats.ready == 1, "columns":stats.columns, "rows":stats.rows,
                "paneGeneration":self.slots.borrow().get(id).map(|slot|slot.generation()),
                "cell":{"width":stats.cell_width,"height":stats.cell_height},
                "scale":stats.scale_x
            })).collect();
            let viewport = self
                .owner
                .upgrade()
                .and_then(|owner| self.native_viewport(owner.last_divider.get()).map(|v| v.0));
            let data = serde_json::json!({"sessionId":self.record().id,"panes":panes,
                "catalogEpoch":self.epoch,"viewGeneration":self.generation,"viewport":viewport});
            if let Err(error) = std::fs::write(path, data.to_string()) {
                eprintln!("diagnostics: {error}");
            }
        }
    }
}
fn notice(text: &str) -> gtk4::Label {
    gtk4::Label::builder()
        .label(text)
        .wrap(true)
        .wrap_mode(gtk4::pango::WrapMode::WordChar)
        .max_width_chars(48)
        .hexpand(true)
        .vexpand(true)
        .selectable(true)
        .build()
}

fn first_pane(node: &LayoutNode) -> ShellId {
    match node {
        LayoutNode::Pane { shell_id } => *shell_id,
        LayoutNode::Split { first, .. } => first_pane(first),
    }
}
