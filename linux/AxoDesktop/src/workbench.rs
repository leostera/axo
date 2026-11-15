//! First local catalog workbench. Daemon owns sessions/layout/processes; this view
//! owns selection and cancellable, detach-only Ghostty widgets. No CLI subprocess.
use crate::{Options, attachment::AttachmentTask, ghostty::Engine, task::MainThreadTask};
use axo_client::{Client, LocalCatalog};
use axo_protocol::{
    Availability, LayoutDirection, LayoutNode, PaneRole, SessionId, SessionRecord, ShellId,
};
use gtk4::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    io,
    path::PathBuf,
    rc::Rc,
    time::Duration,
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
    let header = gtk4::HeaderBar::new();
    header.set_title_widget(Some(&gtk4::Label::new(Some("Axo · local Sessions"))));
    window.set_titlebar(Some(&header));
    let root = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    let sidebar = gtk4::Box::new(gtk4::Orientation::Vertical, 6);
    sidebar.add_css_class("sidebar");
    sidebar.set_width_request(220);
    let heading = gtk4::Label::new(Some("Sessions"));
    heading.set_xalign(0.0);
    heading.set_margin_start(12);
    heading.set_margin_top(8);
    sidebar.append(&heading);
    let list = gtk4::ListBox::new();
    list.set_selection_mode(gtk4::SelectionMode::Single);
    list.add_css_class("navigation-sidebar");
    let scroll = gtk4::ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .hscrollbar_policy(gtk4::PolicyType::Never)
        .build();
    sidebar.append(&scroll);
    let status = gtk4::Label::new(Some("Connecting…"));
    status.set_wrap(true);
    status.set_max_width_chars(26);
    status.set_margin_start(8);
    status.set_margin_end(8);
    sidebar.append(&status);
    let refresh = gtk4::Button::with_label("Refresh Sessions");
    refresh.add_css_class("flat");
    sidebar.append(&refresh);
    root.append(&sidebar);
    root.append(&gtk4::Separator::new(gtk4::Orientation::Vertical));
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content.set_hexpand(true);
    content.set_vexpand(true);
    root.append(&content);
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
        selected: Cell::new(None),
        view: RefCell::new(None),
        updating: Cell::new(false),
        closing: Cell::new(false),
    });
    model.refresh.connect_clicked({
        let model = Rc::downgrade(&model);
        move |_| {
            if let Some(model) = model.upgrade() {
                model.reload();
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
    // The window owns the model; model only has a weak window. Widget callbacks
    // use Weak<Model/View>, avoiding GTK signal -> model -> widget reference cycles.
    window.connect_close_request({
        let model = model.clone();
        move |_| {
            model.shutdown();
            model.engine.request_quit();
            glib::Propagation::Stop
        }
    });
    // App-level quit/SIGTERM can bypass close-request. Drop owned views even then.
    window.connect_unrealize({
        let model = model.clone();
        move |_| model.shutdown()
    });
    window.present();
    model.reload();
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
    catalog: RefCell<Option<Rc<LocalCatalog>>>,
    task: RefCell<Option<MainThreadTask>>,
    selected: Cell<Option<SessionId>>,
    view: RefCell<Option<Rc<SessionView>>>,
    updating: Cell<bool>,
    closing: Cell<bool>,
}
impl Workbench {
    fn shutdown(&self) {
        if self.closing.replace(true) {
            return;
        }
        self.task.borrow_mut().take();
        self.view.borrow_mut().take();
        while let Some(child) = self.content.first_child() {
            self.content.remove(&child);
        }
    }
    fn reload(self: &Rc<Self>) {
        if self.closing.get() || self.task.borrow().is_some() {
            return;
        }
        self.status.set_text("Refreshing…");
        self.refresh.set_sensitive(false);
        let socket = self.socket.clone();
        let weak = Rc::downgrade(self);
        let task = MainThreadTask::start(
            "axo-catalog",
            move || load_catalog(socket),
            move |result| {
                let Some(model) = weak.upgrade().filter(|model| !model.closing.get()) else {
                    return;
                };
                model.task.borrow_mut().take();
                model.refresh.set_sensitive(true);
                match result {
                    Ok(catalog) => model.install_catalog(catalog),
                    Err(error) => model
                        .status
                        .set_text(&format!("Cannot load Sessions: {error}")),
                }
            },
        );
        match task {
            Ok(task) => *self.task.borrow_mut() = Some(task),
            Err(error) => {
                self.status.set_text(&error.to_string());
                self.refresh.set_sensitive(true);
            }
        }
    }
    fn install_catalog(self: &Rc<Self>, catalog: LocalCatalog) {
        let selected = self
            .selected
            .get()
            .filter(|id| catalog.session(*id).is_some())
            .or_else(|| catalog.sessions().first().map(|session| session.id));
        self.updating.set(true);
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        for session in catalog.sessions() {
            let title = session.manual_name.as_ref().unwrap_or(&session.name);
            let text = format!("{} {}", session.emoji.as_deref().unwrap_or("◦"), title);
            let label = gtk4::Label::new(Some(&text));
            label.set_xalign(0.0);
            label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
            label.set_max_width_chars(24);
            label.set_margin_top(5);
            label.set_margin_bottom(5);
            label.set_margin_start(6);
            label.set_margin_end(6);
            label.set_tooltip_text(Some(&session.folder.to_string_lossy()));
            self.list.append(&label);
        }
        self.status.set_text(&format!(
            "{} open · {} archived",
            catalog.sessions().len(),
            catalog.archived().len()
        ));
        let index = selected.and_then(|id| {
            catalog
                .sessions()
                .iter()
                .position(|session| session.id == id)
        });
        *self.catalog.borrow_mut() = Some(Rc::new(catalog));
        self.updating.set(false);
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
        let catalog = self.catalog.borrow().clone();
        let Some(catalog) = catalog else { return };
        let Some(session) = catalog.session(id) else {
            return;
        };
        self.selected.set(Some(id));
        if let Some(window) = self.window.upgrade() {
            window.set_title(Some(&format!(
                "Axo · {}",
                session.manual_name.as_ref().unwrap_or(&session.name)
            )));
        }
        if self.view.borrow().as_ref().is_some_and(|view| {
            view.session.id == id
                && view.session.shells == session.shells
                && view.session.layout == session.layout
        }) {
            return;
        }
        self.view.borrow_mut().take(); // Cancels pending attachments before replacing widgets.
        while let Some(child) = self.content.first_child() {
            self.content.remove(&child);
        }
        let view = Rc::new(SessionView {
            session: session.clone(),
            root: gtk4::Box::new(gtk4::Orientation::Vertical, 0),
            engine: self.engine.clone(),
            window: self.window.clone(),
            options: self.options.clone(),
            pending: RefCell::new(Vec::new()),
            focused: Cell::new(None),
            grids: RefCell::new(std::collections::BTreeMap::new()),
            snapshot_observed: Cell::new(false),
        });
        self.content.append(&view.root);
        *self.view.borrow_mut() = Some(view.clone());
        if let Some(layout) = &view.session.layout {
            view.focused.set(
                view.session
                    .shells
                    .iter()
                    .filter(|shell| {
                        shell.availability == Availability::Available
                            && layout.shell_ids().contains(&shell.id)
                    })
                    .min_by_key(|shell| if shell.role == PaneRole::Pi { 0 } else { 1 })
                    .map(|shell| shell.id)
                    .or_else(|| Some(first_pane(layout.root()))),
            );
            view.root.append(&view.node(layout.root()));
        } else {
            view.root
                .append(&gtk4::Label::new(Some("Session layout is not ready")));
        }
    }
}

fn load_catalog(socket: PathBuf) -> io::Result<LocalCatalog> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(async {
            tokio::time::timeout(Duration::from_secs(5), async {
                let mut client = Client::connect(&socket).await?;
                client.negotiate().await?;
                LocalCatalog::load(&mut client).await
            })
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "catalog request timed out"))?
            .map_err(io::Error::other)
        })
}

struct SessionView {
    session: SessionRecord,
    root: gtk4::Box,
    engine: Rc<Engine>,
    window: glib::WeakRef<gtk4::ApplicationWindow>,
    options: Options,
    pending: RefCell<Vec<AttachmentTask>>,
    focused: Cell<Option<ShellId>>,
    grids: RefCell<std::collections::BTreeMap<ShellId, crate::ghostty::SurfaceStats>>,
    snapshot_observed: Cell<bool>,
}
impl SessionView {
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
                    split.set_position((size as f64 * ratio).round() as i32);
                    glib::ControlFlow::Break
                });
                split.upcast()
            }
        }
    }
    fn pane(self: &Rc<Self>, id: ShellId) -> gtk4::Box {
        let pane = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        pane.set_hexpand(true);
        pane.set_vexpand(true);
        let Some(shell) = self.session.shells.iter().find(|shell| shell.id == id) else {
            pane.append(&gtk4::Label::new(Some(
                "Pane does not belong to this Session",
            )));
            return pane;
        };
        let heading = gtk4::Label::new(Some(match shell.role {
            PaneRole::Pi => "Pi",
            PaneRole::Terminal => "Terminal",
        }));
        heading.set_xalign(0.0);
        heading.set_margin_start(8);
        heading.add_css_class("dim-label");
        pane.append(&heading);
        match &shell.availability {
            Availability::Unavailable { reason } => {
                pane.append(&notice(reason));
                return pane;
            }
            Availability::Dormant => {
                pane.append(&notice(
                    "Pi is asleep; automatic wake is not implemented yet",
                ));
                return pane;
            }
            Availability::Available => {}
        }
        let message = gtk4::Label::new(Some("Connecting…"));
        pane.append(&message);
        let weak_view = Rc::downgrade(self);
        let weak_pane = pane.downgrade();
        let weak_message = message.downgrade();
        let task =
            AttachmentTask::start(shell.attach_socket_path.clone(), id.get(), move |result| {
                let (Some(view), Some(pane)) = (weak_view.upgrade(), weak_pane.upgrade()) else {
                    return;
                };
                if let Some(message) = weak_message.upgrade() {
                    pane.remove(&message);
                }
                let result = result
                    .map_err(|error| error.to_string())
                    .and_then(|prepared| view.engine.attached_surface(prepared));
                match result {
                    Ok(surface) => view.install_surface(id, &pane, &surface),
                    Err(error) => {
                        pane.append(&notice(&format!("Cannot attach: {error}")));
                    }
                }
            });
        match task {
            Ok(task) => self.pending.borrow_mut().push(task),
            Err(error) => {
                pane.remove(&message);
                pane.append(&notice(&error.to_string()));
            }
        }
        pane
    }

    fn install_surface(
        self: &Rc<Self>,
        id: ShellId,
        pane: &gtk4::Box,
        surface: &crate::ghostty::Surface,
    ) {
        let focus = gtk4::EventControllerFocus::new();
        focus.connect_enter({
            let view = Rc::downgrade(self);
            move |_| {
                if let Some(view) = view.upgrade() {
                    view.focused.set(Some(id));
                }
            }
        });
        surface.widget().add_controller(focus);
        surface.widget().set_hexpand(true);
        surface.widget().set_vexpand(true);
        pane.append(surface.widget());
        self.observe_surface(id, surface);
        if self.focused.get() == Some(id) {
            surface.focus();
        }
    }

    fn observe_surface(self: &Rc<Self>, id: ShellId, surface: &crate::ghostty::Surface) {
        if self.options.diagnostics.is_some() {
            let weak = Rc::downgrade(self);
            let previous = Cell::new(crate::ghostty::SurfaceStats::default());
            surface.on_frame(move |stats, _| {
                if stats == previous.replace(stats) {
                    return;
                }
                if let Some(view) = weak.upgrade() {
                    view.record_grid(id, stats);
                }
            });
        }
        // Readback follows the first installed surface, not focus timing. A slow
        // Pi attachment or a user clicking another pane must not suppress it.
        if self.options.snapshot.is_some() && !self.snapshot_observed.replace(true) {
            if let Some(window) = self.window.upgrade() {
                crate::observe_window(&window, surface, self.options.snapshot.clone(), None);
            }
        }
    }

    fn record_grid(&self, id: ShellId, stats: crate::ghostty::SurfaceStats) {
        let mut grids = self.grids.borrow_mut();
        grids.insert(id, stats);
        let panes: Vec<_> = grids.iter().map(|(id, stats)| serde_json::json!({
            "shellId":id, "ready":stats.ready == 1, "columns":stats.columns, "rows":stats.rows
        })).collect();
        let data = serde_json::json!({"sessionId":self.session.id,"panes":panes});
        if let Some(path) = &self.options.diagnostics {
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
