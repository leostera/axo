//! Stable pane containers for same-layout catalog updates. Never reparent a healthy
//! realized Ghostty widget; each replacement invalidates its own async callbacks first.
use super::*;
use axo_protocol::ShellRecord;

pub(super) struct PaneSlot {
    id: ShellId,
    root: gtk4::Box,
    generation: Cell<u64>,
    failed: Cell<bool>,
    surface: RefCell<Option<Rc<crate::ghostty::Surface>>>,
    focus_on_activate: Cell<bool>,
    task: RefCell<Option<AttachmentTask>>,
}
impl PaneSlot {
    pub(super) fn generation(&self) -> u64 {
        self.generation.get()
    }
    fn update(self: &Rc<Self>, view: &Rc<SessionView>, shell: &ShellRecord) {
        let generation = self
            .generation
            .get()
            .checked_add(1)
            .expect("pane generation exhausted");
        self.generation.set(generation); // Invalidate EOF/frame/focus/late attach before teardown.
        self.failed.set(false);
        self.focus_on_activate.set(false);
        self.task.borrow_mut().take();
        self.surface.borrow_mut().take();
        view.grids.borrow_mut().remove(&self.id);
        while let Some(child) = self.root.first_child() {
            self.root.remove(&child);
        }
        self.root
            .update_property(&[gtk4::accessible::Property::Label(match shell.role {
                PaneRole::Pi => "Pi pane",
                PaneRole::Terminal => "Terminal pane",
            })]);
        match &shell.availability {
            Availability::Unavailable { reason } => {
                self.root.append(&notice(reason));
                return;
            }
            Availability::Dormant => {
                if let Some(owner) = view.owner.upgrade() {
                    owner.dormant_pi(view.record().id, self.id, &self.root);
                }
                return;
            }
            Availability::Available => {}
        }
        let message = gtk4::Label::new(Some("Connecting…"));
        self.root.append(&message);
        let weak_view = Rc::downgrade(view);
        let weak_slot = Rc::downgrade(self);
        let weak_message = message.downgrade();
        let id = self.id;
        let task =
            AttachmentTask::start(shell.attach_socket_path.clone(), id.get(), move |result| {
                let (Some(view), Some(slot)) = (weak_view.upgrade(), weak_slot.upgrade()) else {
                    return;
                };
                if slot.generation.get() != generation {
                    return;
                }
                slot.task.borrow_mut().take();
                if let Some(message) = weak_message.upgrade() {
                    slot.root.remove(&message);
                }
                let retry = result.as_ref().err().is_some_and(|error| {
                    matches!(
                        error.kind(),
                        std::io::ErrorKind::NotFound
                            | std::io::ErrorKind::ConnectionRefused
                            | std::io::ErrorKind::ConnectionReset
                            | std::io::ErrorKind::UnexpectedEof
                            | std::io::ErrorKind::TimedOut
                            | std::io::ErrorKind::BrokenPipe
                    )
                });
                let result = result
                    .map_err(|error| error.to_string())
                    .and_then(|prepared| view.engine.attached_surface(prepared));
                match result {
                    Ok(surface) => {
                        let surface = Rc::new(surface);
                        *slot.surface.borrow_mut() = Some(surface.clone());
                        slot.install(&view, &surface, generation);
                    }
                    Err(error) => {
                        slot.root
                            .append(&notice(&format!("Cannot attach: {error}")));
                        slot.failed.set(true);
                        view.needs_retry.set(true);
                        if retry {
                            view.retry();
                        }
                    }
                }
            });
        match task {
            Ok(task) => *self.task.borrow_mut() = Some(task),
            Err(error) => {
                self.failed.set(true);
                view.needs_retry.set(true);
                self.root.remove(&message);
                self.root.append(&notice(&error.to_string()));
            }
        }
    }
    fn install(
        self: &Rc<Self>,
        view: &Rc<SessionView>,
        surface: &crate::ghostty::Surface,
        generation: u64,
    ) {
        let weak_view = Rc::downgrade(view);
        let weak_slot = Rc::downgrade(self);
        surface.on_output_ended(move || {
            let weak_view = weak_view.clone();
            let weak_slot = weak_slot.clone();
            // Native dispatch must return before any widget replacement.
            glib::idle_add_local_once(move || {
                if let (Some(view), Some(slot)) = (weak_view.upgrade(), weak_slot.upgrade()) {
                    if slot.generation.get() == generation {
                        slot.failed.set(true);
                        view.retry();
                    }
                }
            });
        });
        let id = self.id;
        let focus = gtk4::EventControllerFocus::new();
        focus.connect_enter({
            let view = Rc::downgrade(view);
            let slot = Rc::downgrade(self);
            move |_| {
                if let (Some(view), Some(slot)) = (view.upgrade(), slot.upgrade()) {
                    if slot.generation.get() == generation {
                        view.focused.set(Some(id));
                    }
                }
            }
        });
        surface.widget().add_controller(focus);
        surface.widget().set_hexpand(true);
        surface.widget().set_vexpand(true);
        self.root.append(surface.widget());
        let weak_view = Rc::downgrade(view);
        let weak_slot = Rc::downgrade(self);
        let previous = Cell::new(crate::ghostty::SurfaceStats::default());
        surface.on_frame(move |stats, _| {
            let (Some(view), Some(slot)) = (weak_view.upgrade(), weak_slot.upgrade()) else {
                return;
            };
            if slot.generation.get() != generation {
                return;
            }
            let changed = stats != previous.replace(stats);
            let geometry = crate::ghostty::widget_geometry(view.root.upcast_ref());
            let moved = view.geometry.replace(Some(geometry)) != Some(geometry);
            if changed || moved {
                view.record_grid(id, stats);
            }
        });
        if view.options.snapshot.is_some() && !view.snapshot_observed.replace(true) {
            if let Some(window) = view.window.upgrade() {
                crate::observe_window(&window, surface, view.options.snapshot.clone(), None);
            }
        }
        if view.focused.get() == Some(id) {
            if view
                .window
                .upgrade()
                .is_some_and(|window| window.is_active())
            {
                surface.focus();
            } else {
                // Do not steal Settings focus; fulfill this initial pane focus only when
                // the actual main window becomes active, without recreating the widget.
                self.focus_on_activate.set(true);
            }
        }
    }
}
impl SessionView {
    pub(super) fn record(&self) -> Rc<SessionRecord> {
        self.session.borrow().clone()
    }
    pub(super) fn focus_deferred(&self) {
        if !self
            .window
            .upgrade()
            .is_some_and(|window| window.is_visible() && window.is_active())
        {
            return;
        }
        let slot = self
            .focused
            .get()
            .and_then(|id| self.slots.borrow().get(&id).cloned());
        if let Some(slot) = slot {
            if slot.focus_on_activate.replace(false) {
                let surface = slot.surface.borrow().clone();
                if let Some(surface) = surface {
                    surface.focus();
                }
            }
        }
    }

    /// This bounded slice reconciles membership/availability only with the exact same
    /// layout. Topology/ratio changes still take the explicit fresh-v3 Scene path.
    pub(super) fn reconcile(self: &Rc<Self>, next: &SessionRecord) -> bool {
        let previous = self.record();
        if previous.id != next.id
            || previous.layout != next.layout
            || !previous
                .shells
                .iter()
                .map(|shell| shell.id)
                .eq(next.shells.iter().map(|shell| shell.id))
        {
            return false;
        }
        *self.session.borrow_mut() = Rc::new(next.clone());
        for (old, shell) in previous.shells.iter().zip(&next.shells) {
            if old != shell {
                let slot = self.slots.borrow().get(&shell.id).cloned();
                if let Some(slot) = slot {
                    slot.update(self, shell);
                }
            }
        }
        let failed = self.slots.borrow().values().any(|slot| slot.failed.get());
        self.needs_retry.set(failed);
        if !failed {
            if let Some(owner) = self.owner.upgrade() {
                if owner
                    .view
                    .borrow()
                    .as_ref()
                    .is_some_and(|current| Rc::ptr_eq(current, self))
                {
                    owner.cancel_retry();
                    owner.update_viewport_status();
                }
            }
        }
        // A disappearance must be visible even if every retained native surface is idle.
        self.publish_metrics();
        true
    }
    pub(super) fn pane(self: &Rc<Self>, id: ShellId) -> gtk4::Box {
        let pane = gtk4::Box::builder()
            .orientation(gtk4::Orientation::Vertical)
            .accessible_role(gtk4::AccessibleRole::Group)
            .build();
        pane.set_hexpand(true);
        pane.set_vexpand(true);
        pane.add_css_class("axo-pane");
        let record = self.record();
        let Some(shell) = record.shells.iter().find(|shell| shell.id == id) else {
            pane.append(&notice("Pane does not belong to this Session"));
            return pane;
        };
        let slot = Rc::new(PaneSlot {
            id,
            root: pane.clone(),
            generation: Cell::new(0),
            failed: Cell::new(false),
            surface: RefCell::new(None),
            focus_on_activate: Cell::new(false),
            task: RefCell::new(None),
        });
        self.slots.borrow_mut().insert(id, slot.clone());
        slot.update(self, shell);
        pane
    }
}
