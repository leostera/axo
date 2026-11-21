//! Native settings presentation; validation and durable values stay in axod.
use crate::task::{MainThreadTask, daemon_request};
use axo_client::Error;
use axo_protocol::{ConfigKey, rpc};
use gtk4::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
};

#[derive(Clone, Copy)]
enum Phase {
    Unavailable,
    Loading,
    Ready { writable: bool },
    Saving,
    NeedsReload,
    Closed,
}

struct Field {
    key: ConfigKey,
    entry: gtk4::Entry,
    save: gtk4::Button,
    saved: RefCell<Option<String>>,
}
struct Settings {
    socket: PathBuf,
    fields: Vec<Field>,
    status: gtk4::Label,
    daemon: gtk4::Label,
    reload: gtk4::Button,
    phase: Cell<Phase>,
    task: RefCell<Option<MainThreadTask>>,
}
struct Loaded {
    values: Vec<rpc::ConfigValue>,
    writable: bool,
    daemon: String,
}
enum SaveResult {
    Saved(rpc::ConfigValue),
    Invalid(String),
}

pub fn show(parent: &gtk4::ApplicationWindow, socket: PathBuf) -> gtk4::Window {
    let window = gtk4::Window::builder()
        .title("Axo Settings")
        .transient_for(parent)
        .destroy_with_parent(true)
        .default_width(860)
        .default_height(580)
        .build();
    window.add_css_class("axo-window");
    window.add_css_class("axo-settings");
    window.set_size_request(720, 480);
    window.set_application(parent.application().as_ref());
    let root = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content.add_css_class("axo-settings-body");
    content.set_hexpand(true);
    let tabs = gtk4::Stack::new();
    tabs.set_vexpand(true);
    let general = page();
    let sessions = page();
    let agent = page();
    let shell = command_field(
        &general,
        ConfigKey::ShellCommand,
        "Shell",
        "Shell command",
        "Axod runs this command in its own terminal session. Use an absolute executable path or a command on axod's PATH; arguments support shell-style quoting. Changes apply to new or restarted shell processes.",
    );
    let daemon_group = section(&general, "axod");
    let daemon = text("Connecting…");
    daemon.set_xalign(1.0);
    daemon.set_hexpand(true);
    daemon.update_property(&[gtk4::accessible::Property::Label("Daemon status")]);
    daemon_group.append(&value_row("Daemon status", &daemon));
    let limits = section(&sessions, "Limits");
    let minutes = count_field(
        &limits,
        ConfigKey::IdleMinutes,
        "Put idle Pis to sleep after",
        "Idle timeout (minutes)",
        "min",
    );
    limits.append(&gtk4::Separator::new(gtk4::Orientation::Horizontal));
    let count = count_field(
        &limits,
        ConfigKey::IdleLimit,
        "Keep idle Pis awake, at most",
        "Maximum idle Pis awake",
        "Pis",
    );
    let help = text(
        "A Pi that isn't working or asking you anything is idle. Axod stops idle Pis to save memory; the Session stays where it is. Working Pis are never stopped. Use 0 minutes for never, or 0 Pis to keep none awake. Other clients can wake a sleeping Pi.",
    );
    help.add_css_class("axo-field-help");
    crate::style::inset(&help, 10, 10);
    sessions.append(&help);
    let agent_command = command_field(
        &agent,
        ConfigKey::AgentCommand,
        "Default Agent",
        "Agent command",
        "Enter the full command line. Use an absolute executable path or a command on axod's PATH. Arguments support shell-style quoting; Axod launches it directly without a shell and appends its managed Pi session and extension arguments. Changes apply to new Agent processes.",
    );
    let fields = vec![shell, minutes, count, agent_command];
    for (name, page) in [
        ("General", general),
        ("Sessions", sessions),
        ("Agent", agent),
    ] {
        let scroll = gtk4::ScrolledWindow::builder()
            .child(&page)
            .hscrollbar_policy(gtk4::PolicyType::Never)
            .build();
        tabs.add_titled(&scroll, Some(name), name);
    }
    let navigation_background = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    navigation_background.add_css_class("axo-settings-nav");
    navigation_background.set_width_request(180);
    navigation_background.set_hexpand(false);
    navigation_background.append(&crate::style::sidebar_titlebar(
        &window,
        Some("Axo Settings"),
    ));
    navigation_background.append(&navigation(&tabs));
    root.append(&navigation_background);
    root.append(&gtk4::Separator::new(gtk4::Orientation::Vertical));
    content.append(&tabs);
    let footer = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
    let footer_background = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    footer_background.add_css_class("axo-settings-footer");
    crate::style::inset(&footer, 8, 36);
    let status = text("Loading daemon settings…");
    status.add_css_class("axo-feedback");
    status.set_hexpand(true);
    status.set_height_request(38);
    status.set_lines(3);
    status.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    status.set_selectable(true);
    footer.append(&status);
    let reload = gtk4::Button::with_label("Reload values");
    reload.set_tooltip_text(Some(
        "Discard unsaved edits and read settings from the daemon",
    ));
    reload.set_halign(gtk4::Align::End);
    reload.set_valign(gtk4::Align::Center);
    footer.append(&reload);
    footer_background.append(&footer);
    content.append(&footer_background);
    root.append(&content);
    window.set_child(Some(&root));
    let model = Rc::new(Settings {
        socket,
        fields,
        status,
        daemon,
        reload,
        phase: Cell::new(Phase::Unavailable),
        task: RefCell::new(None),
    });
    for field in &model.fields {
        field.entry.connect_changed({
            let model = Rc::downgrade(&model);
            move |_| {
                if let Some(model) = model.upgrade() {
                    model.controls();
                }
            }
        });
        field.save.connect_clicked({
            let model = Rc::downgrade(&model);
            let key = field.key;
            move |_| {
                if let Some(model) = model.upgrade() {
                    model.save(key);
                }
            }
        });
        field.entry.connect_activate({
            let model = Rc::downgrade(&model);
            let key = field.key;
            move |_| {
                if let Some(model) = model.upgrade() {
                    model.save(key);
                }
            }
        });
    }
    model.reload.connect_clicked({
        let model = Rc::downgrade(&model);
        move |_| {
            if let Some(model) = model.upgrade() {
                model.load();
            }
        }
    });
    window.connect_close_request({
        let model = model.clone();
        move |_| {
            model.close();
            glib::Propagation::Proceed
        }
    });
    window.connect_unrealize({
        let model = model.clone();
        move |_| model.close()
    });
    window.present();
    model.load();
    window
}
fn navigation(tabs: &gtk4::Stack) -> gtk4::ListBox {
    let navigation = gtk4::ListBox::new();
    navigation.set_vexpand(true);
    navigation.set_selection_mode(gtk4::SelectionMode::Single);
    crate::style::inset(&navigation, 8, 8);
    for (name, icon) in [
        ("General", "emblem-system-symbolic"),
        ("Sessions", "view-dual-symbolic"),
        ("Agent", "utilities-terminal-symbolic"),
    ] {
        let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 10);
        crate::style::inset(&row, 4, 10);
        let image = gtk4::Image::from_icon_name(icon);
        image.set_pixel_size(16);
        row.append(&image);
        row.append(&gtk4::Label::new(Some(name)));
        navigation.append(&row);
    }
    navigation.connect_row_selected({
        let tabs = tabs.downgrade();
        move |_, row| {
            let (Some(tabs), Some(row)) = (tabs.upgrade(), row) else {
                return;
            };
            if let Some(name) = ["General", "Sessions", "Agent"].get(row.index() as usize) {
                tabs.set_visible_child_name(name);
            }
        }
    });
    navigation.select_row(navigation.row_at_index(0).as_ref());
    navigation
}
fn page() -> gtk4::Box {
    let page = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    page.add_css_class("axo-settings-page");
    crate::style::inset(&page, 20, 36);
    page.set_margin_top(68);
    page
}
fn section(page: &gtk4::Box, title: &str) -> gtk4::Box {
    let heading = text(title);
    heading.add_css_class("axo-section-title");
    heading.set_margin_start(10);
    heading.set_margin_bottom(10);
    if page.first_child().is_some() {
        heading.set_margin_top(28);
    }
    page.append(&heading);
    let card = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    card.add_css_class("axo-setting-card");
    page.append(&card);
    card
}
fn value_row(caption: &str, value: &impl IsA<gtk4::Widget>) -> gtk4::Box {
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
    crate::style::inset(&row, 3, 10);
    row.set_height_request(30);
    let caption = text(caption);
    caption.set_wrap(false);
    row.append(&caption);
    row.append(value);
    row
}
fn text(value: &str) -> gtk4::Label {
    let label = gtk4::Label::new(Some(value));
    label.set_wrap(true);
    label.set_max_width_chars(72);
    label.set_xalign(0.0);
    label
}
fn field(key: ConfigKey, title: &str) -> Field {
    let entry = gtk4::Entry::new();
    entry.set_hexpand(true);
    gtk4::prelude::EntryExt::set_alignment(&entry, 1.0);
    entry.set_width_chars(8);
    entry.update_property(&[gtk4::accessible::Property::Label(title)]);
    let save = gtk4::Button::with_label("Save");
    save.update_property(&[gtk4::accessible::Property::Description(&format!(
        "Save {title}"
    ))]);
    Field {
        key,
        entry,
        save,
        saved: RefCell::new(None),
    }
}
fn command_field(
    page: &gtk4::Box,
    key: ConfigKey,
    section_title: &str,
    title: &str,
    help: &str,
) -> Field {
    let field = field(key, title);
    let card = section(page, section_title);
    card.append(&value_row("Command", &field.entry));
    card.append(&gtk4::Separator::new(gtk4::Orientation::Horizontal));
    let help = text(help);
    help.add_css_class("axo-field-help");
    crate::style::inset(&help, 10, 10);
    card.append(&help);
    card.append(&gtk4::Separator::new(gtk4::Orientation::Horizontal));
    let actions = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    actions.set_halign(gtk4::Align::End);
    crate::style::inset(&actions, 8, 10);
    actions.append(&field.save);
    card.append(&actions);
    field
}
fn count_field(card: &gtk4::Box, key: ConfigKey, caption: &str, title: &str, unit: &str) -> Field {
    let field = field(key, title);
    field.entry.set_input_purpose(gtk4::InputPurpose::Digits);
    field.entry.set_hexpand(false);
    field.entry.set_width_chars(4);
    field.entry.set_max_width_chars(6);
    let controls = gtk4::Box::new(gtk4::Orientation::Horizontal, 6);
    controls.set_hexpand(true);
    controls.set_halign(gtk4::Align::End);
    controls.append(&field.entry);
    controls.append(&text(unit));
    controls.append(&field.save);
    card.append(&value_row(caption, &controls));
    field
}
impl Settings {
    fn close(&self) {
        self.phase.set(Phase::Closed);
        self.task.borrow_mut().take();
    }
    fn controls(&self) {
        let editable = matches!(self.phase.get(), Phase::Ready { writable: true });
        for field in &self.fields {
            field.entry.set_sensitive(editable);
            field.save.set_sensitive(
                editable
                    && field
                        .saved
                        .borrow()
                        .as_deref()
                        .is_some_and(|saved| saved != field.entry.text().as_str()),
            );
        }
        self.reload.set_sensitive(!matches!(
            self.phase.get(),
            Phase::Loading | Phase::Saving | Phase::Closed
        ));
    }
    fn load(self: &Rc<Self>) {
        if self.task.borrow().is_some() || matches!(self.phase.get(), Phase::Closed) {
            return;
        }
        self.phase.set(Phase::Loading);
        self.status.set_text("Loading daemon settings…");
        self.controls();
        let keys: Vec<_> = self.fields.iter().map(|field| field.key).collect();
        let socket = self.socket.clone();
        let weak = Rc::downgrade(self);
        let task = MainThreadTask::start(
            "axo-settings-read",
            move || {
                daemon_request(&socket, |mut client| async move {
                    let health: rpc::DaemonHealth = client
                        .call_typed(rpc::method::DAEMON_HEALTH, serde_json::json!({}))
                        .await?;
                    let mut values = Vec::new();
                    for key in keys {
                        values.push(client.config_value(key).await?);
                    }
                    Ok(Loaded {
                        values,
                        writable: client.supports(rpc::method::CONFIG_SET),
                        daemon: format!(
                            "{} · Axo {}",
                            if health.ready { "Running" } else { "Starting" },
                            health.version
                        ),
                    })
                })
            },
            move |result| {
                let Some(model) = weak.upgrade() else { return };
                model.task.borrow_mut().take();
                match result {
                    Ok(loaded) => {
                        for value in loaded.values {
                            if let Some(field) =
                                model.fields.iter().find(|field| field.key == value.key)
                            {
                                field.entry.set_text(&value.value);
                                *field.saved.borrow_mut() = Some(value.value);
                            }
                        }
                        model.phase.set(Phase::Ready {
                            writable: loaded.writable,
                        });
                        model.daemon.set_text(&loaded.daemon);
                        model
                            .status
                            .set_text(if loaded.writable { "" } else { "Read only" });
                    }
                    Err(error) => {
                        model.phase.set(Phase::Unavailable);
                        model.daemon.set_text("Unavailable");
                        model.status.set_text(&format!(
                            "Cannot load settings: {error}. Check the daemon, then reload."
                        ));
                    }
                }
                model.controls();
            },
        );
        self.keep_task(task);
    }
    fn save(self: &Rc<Self>, key: ConfigKey) {
        if !matches!(self.phase.get(), Phase::Ready { writable: true }) {
            return;
        }
        let Some(field) = self.fields.iter().find(|field| field.key == key) else {
            return;
        };
        if !field.save.is_sensitive() {
            return;
        }
        let value = field.entry.text().to_string();
        let socket = self.socket.clone();
        let weak = Rc::downgrade(self);
        self.phase.set(Phase::Saving);
        self.status.set_text("Saving…");
        self.controls();
        let task = MainThreadTask::start(
            "axo-settings-write",
            move || {
                daemon_request(&socket, |mut client| async move {
                    match client.set_config_value(key, &value).await {
                        Ok(value) => Ok(SaveResult::Saved(value)),
                        Err(Error::Rejected {
                            code: -32602,
                            message,
                            ..
                        })
                        | Err(Error::Input(message)) => Ok(SaveResult::Invalid(message)),
                        Err(error) => Err(error),
                    }
                })
            },
            move |result| {
                let Some(model) = weak.upgrade() else { return };
                model.task.borrow_mut().take();
                match result {
                    Ok(SaveResult::Saved(value)) => {
                        if let Some(field) =
                            model.fields.iter().find(|field| field.key == value.key)
                        {
                            field.entry.set_text(&value.value);
                            *field.saved.borrow_mut() = Some(value.value);
                        }
                        model.phase.set(Phase::Ready { writable: true });
                        model.status.set_text("Saved");
                    }
                    Ok(SaveResult::Invalid(error)) => {
                        model.phase.set(Phase::Ready { writable: true });
                        model.status.set_text(&format!("Not saved: {error}"));
                    }
                    Err(error) => {
                        model.phase.set(Phase::NeedsReload);
                        model.status.set_text(&format!("Save could not be confirmed: {error}. Reload values before trying again."));
                    }
                }
                model.controls();
            },
        );
        self.keep_task(task);
    }
    fn keep_task(&self, task: std::io::Result<MainThreadTask>) {
        match task {
            Ok(task) => *self.task.borrow_mut() = Some(task),
            Err(error) => {
                self.phase.set(Phase::Unavailable);
                self.status
                    .set_text(&format!("Could not start settings request: {error}"));
                self.controls();
            }
        }
    }
}
