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
        .default_width(820)
        .default_height(510)
        .build();
    window.add_css_class("axo-window");
    window.add_css_class("axo-settings");
    window.set_size_request(720, 480);
    window.set_application(parent.application().as_ref());
    let header = gtk4::HeaderBar::new();
    header.set_title_widget(Some(&gtk4::Label::new(Some("Settings"))));
    window.set_titlebar(Some(&header));
    let root = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content.add_css_class("axo-settings-body");
    content.set_hexpand(true);
    let tabs = gtk4::Stack::new();
    tabs.set_vexpand(true);
    let general = page("Shell", "Choose how new terminal processes start.");
    let sessions = page(
        "Idle sessions",
        "Keep memory available without losing your conversations.",
    );
    let agent = page(
        "Default agent",
        "Configure the command used for new Agent processes.",
    );
    let fields = vec![
        field(
            &general,
            ConfigKey::ShellCommand,
            "Shell command",
            "Full command line for new or restarted shells. Arguments support quoting; commands run on the daemon's PATH.",
        ),
        field(
            &sessions,
            ConfigKey::IdleMinutes,
            "Idle timeout (minutes)",
            "0 means never. Working Pis are never stopped. Idle changes apply without restarting the daemon.",
        ),
        field(
            &sessions,
            ConfigKey::IdleLimit,
            "Maximum idle Pis awake",
            "0 means none. Sleeping preserves the Session; other clients can wake its Pi.",
        ),
        field(
            &agent,
            ConfigKey::AgentCommand,
            "Agent command",
            "Full command for new Agent processes. Axo appends its managed session and extension arguments. Existing processes are not restarted.",
        ),
    ];
    for (name, page) in [
        ("General", general),
        ("Sessions", sessions),
        ("Agent", agent),
    ] {
        tabs.add_titled(&page, Some(name), name);
    }
    let navigation = gtk4::StackSidebar::builder()
        .stack(&tabs)
        .width_request(160)
        .build();
    navigation.set_vexpand(true);
    let navigation_background = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    navigation_background.add_css_class("axo-settings-nav");
    crate::style::inset(&navigation, 12, 8);
    navigation_background.append(&navigation);
    root.append(&navigation_background);
    root.append(&gtk4::Separator::new(gtk4::Orientation::Vertical));
    content.append(&tabs);
    let footer = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
    let footer_background = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    footer_background.add_css_class("axo-settings-footer");
    crate::style::inset(&footer, 12, 22);
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
fn page(title: &str, description: &str) -> gtk4::Box {
    let page = gtk4::Box::new(gtk4::Orientation::Vertical, 12);
    page.add_css_class("axo-settings-page");
    crate::style::inset(&page, 22, 22);
    let heading = text(title);
    heading.add_css_class("axo-page-title");
    page.append(&heading);
    let description = text(description);
    description.add_css_class("axo-page-description");
    description.set_margin_bottom(12);
    page.append(&description);
    page
}
fn text(value: &str) -> gtk4::Label {
    let label = gtk4::Label::new(Some(value));
    label.set_wrap(true);
    label.set_max_width_chars(72);
    label.set_xalign(0.0);
    label
}
fn field(page: &gtk4::Box, key: ConfigKey, title: &str, help: &str) -> Field {
    let group = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
    crate::style::inset(&group, 14, 14);
    let card = gtk4::Frame::new(None);
    card.add_css_class("axo-setting-card");
    card.set_child(Some(&group));
    let entry = gtk4::Entry::new();
    entry.set_hexpand(true);
    entry.update_property(&[gtk4::accessible::Property::Label(title)]);
    if matches!(key, ConfigKey::IdleMinutes | ConfigKey::IdleLimit) {
        entry.set_input_purpose(gtk4::InputPurpose::Digits);
    }
    if matches!(key, ConfigKey::ShellCommand | ConfigKey::AgentCommand) {
        entry.add_css_class("axo-command");
    }
    let caption = text(title);
    caption.add_css_class("axo-field-title");
    group.append(&caption);
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
    let save = gtk4::Button::with_label("Save");
    save.update_property(&[gtk4::accessible::Property::Description(&format!(
        "Save {title}"
    ))]);
    row.append(&entry);
    row.append(&save);
    group.append(&row);
    let help = text(help);
    help.add_css_class("axo-field-help");
    group.append(&help);
    page.append(&card);
    Field {
        key,
        entry,
        save,
        saved: RefCell::new(None),
    }
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
                        model.status.set_text(&format!(
                            "{}{}",
                            loaded.daemon,
                            if loaded.writable { "" } else { " · Read only" }
                        ));
                    }
                    Err(error) => {
                        model.phase.set(Phase::Unavailable);
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
