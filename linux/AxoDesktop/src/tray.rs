//! StatusNotifierItem + DBusMenu on the user's session bus. No GNOME extension,
//! XEmbed/GTK3 shim, daemon ownership, or privileged approval path.
use glib::variant::ToVariant;
use gtk4::{gio, glib};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
    time::Duration,
};

const WATCHER: &str = "org.kde.StatusNotifierWatcher";
const WATCHER_PATH: &str = "/StatusNotifierWatcher";
const ITEM: &str = "org.kde.StatusNotifierItem";
const MENU: &str = "com.canonical.dbusmenu";
const ITEM_PATH: &str = "/StatusNotifierItem";
const MENU_PATH: &str = "/MenuBar";

#[derive(Clone, Copy)]
pub enum Action {
    Show,
    Hide,
    Settings,
    Quit,
}
impl Action {
    fn from_id(id: i32) -> Option<Self> {
        match id {
            1 => Some(Self::Show),
            2 => Some(Self::Hide),
            3 => Some(Self::Settings),
            4 => Some(Self::Quit),
            _ => None,
        }
    }
}

pub struct Tray {
    state: Rc<State>,
    objects: Vec<gio::RegistrationId>,
    unwatch: Option<Box<dyn FnOnce()>>,
    poll: Option<glib::SourceId>,
}
struct State {
    connection: gio::DBusConnection,
    owner: RefCell<Option<String>>,
    registered: Cell<bool>,
    checking: Cell<bool>,
    available: Cell<bool>,
    daemon: RefCell<String>,
    revision: Cell<u32>,
    action: Box<dyn Fn(Action)>,
    availability: Box<dyn Fn(bool)>,
}

impl Tray {
    pub fn new(
        connection: gio::DBusConnection,
        action: impl Fn(Action) + 'static,
        availability: impl Fn(bool) + 'static,
    ) -> Result<Self, glib::Error> {
        let state = Rc::new(State {
            connection,
            owner: RefCell::new(None),
            registered: Cell::new(false),
            checking: Cell::new(false),
            available: Cell::new(false),
            daemon: RefCell::new("Checking daemon…".into()),
            revision: Cell::new(1),
            action: Box::new(action),
            availability: Box::new(availability),
        });
        let mut tray = Self {
            state: state.clone(),
            objects: Vec::new(),
            unwatch: None,
            poll: None,
        };
        let info = gio::DBusNodeInfo::for_xml(ITEM_XML)?
            .lookup_interface(ITEM)
            .expect("static item XML");
        tray.objects.push(
            state
                .connection
                .register_object(ITEM_PATH, &info)
                .method_call({
                    let state = state.clone();
                    move |_, _, _, _, method, _, call| {
                        match method {
                            "Activate" | "SecondaryActivate" => (state.action)(Action::Show),
                            "ContextMenu" | "Scroll" => {}
                            _ => {
                                call.return_dbus_error(
                                    "org.freedesktop.DBus.Error.UnknownMethod",
                                    "Unknown item method",
                                );
                                return;
                            }
                        }
                        call.return_value(Some(&().to_variant()));
                    }
                })
                .property({
                    let state = state.clone();
                    move |_, _, _, _, name| state.item_property(name)
                })
                .build()?,
        );
        let info = gio::DBusNodeInfo::for_xml(MENU_XML)?
            .lookup_interface(MENU)
            .expect("static menu XML");
        tray.objects.push(
            state
                .connection
                .register_object(MENU_PATH, &info)
                .method_call({
                    let state = state.clone();
                    move |_, _, _, _, method, parameters, call| match state
                        .menu_call(method, parameters)
                    {
                        Some(value) => call.return_value(Some(&value)),
                        None => call.return_dbus_error(
                            "org.freedesktop.DBus.Error.InvalidArgs",
                            "Unknown menu item or invalid arguments",
                        ),
                    }
                })
                .property(|_, _, _, _, name| match name {
                    "Version" => 3_u32.to_variant(),
                    "TextDirection" => "ltr".to_variant(),
                    "Status" => "normal".to_variant(),
                    "IconThemePath" => Vec::<String>::new().to_variant(),
                    _ => unreachable!("introspected menu property"),
                })
                .build()?,
        );
        let watcher = gio::bus_watch_name_on_connection(
            &state.connection,
            WATCHER,
            gio::BusNameWatcherFlags::NONE,
            {
                let weak = Rc::downgrade(&state);
                move |_, _, owner| {
                    if let Some(state) = weak.upgrade() {
                        state.register(owner);
                    }
                }
            },
            {
                let weak = Rc::downgrade(&state);
                move |_, _| {
                    if let Some(state) = weak.upgrade() {
                        state.owner.borrow_mut().take();
                        state.registered.set(false);
                        state.set_available(false);
                    }
                }
            },
        );
        // gio 0.21's root WatcherId shadows the name-watch return type. Keep its
        // inferred typed cleanup rather than casting an opaque registration ID.
        tray.unwatch = Some(Box::new(move || gio::bus_unwatch_name(watcher)));
        // The standard has no required host-unregistered signal. Recheck host
        // presence even when the watcher process stays alive, never just its name.
        tray.poll = Some(glib::timeout_add_local(Duration::from_secs(2), {
            let weak = Rc::downgrade(&state);
            move || {
                let Some(state) = weak.upgrade() else {
                    return glib::ControlFlow::Break;
                };
                state.check_host();
                glib::ControlFlow::Continue
            }
        }));
        Ok(tray)
    }
    pub fn daemon_status(&self, value: &str) {
        if *self.state.daemon.borrow() == value {
            return;
        }
        *self.state.daemon.borrow_mut() = value.into();
        self.state
            .revision
            .set(self.state.revision.get().wrapping_add(1));
        let connection = &self.state.connection;
        let _ = connection.emit_signal(None, ITEM_PATH, ITEM, "NewToolTip", Some(&().to_variant()));
        let _ = connection.emit_signal(
            None,
            MENU_PATH,
            MENU,
            "LayoutUpdated",
            Some(&(self.state.revision.get(), 0_i32).to_variant()),
        );
    }
}
impl Drop for Tray {
    fn drop(&mut self) {
        if let Some(poll) = self.poll.take() {
            poll.remove();
        }
        if let Some(unwatch) = self.unwatch.take() {
            unwatch();
        }
        for object in self.objects.drain(..) {
            let _ = self.state.connection.unregister_object(object);
        }
    }
}
impl State {
    fn set_available(&self, available: bool) {
        if self.available.replace(available) != available {
            (self.availability)(available);
        }
    }
    fn register(self: &Rc<Self>, owner: &str) {
        *self.owner.borrow_mut() = Some(owner.into());
        self.registered.set(false);
        self.set_available(false);
        let Some(name) = self.connection.unique_name() else {
            return;
        };
        let owner = owner.to_owned();
        let weak = Rc::downgrade(self);
        self.connection.call(
            Some(&owner),
            WATCHER_PATH,
            WATCHER,
            "RegisterStatusNotifierItem",
            Some(&(name.as_str(),).to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            5000,
            gio::Cancellable::NONE,
            {
                let owner = owner.clone();
                move |result| {
                    let Some(state) = weak.upgrade() else { return };
                    if state.owner.borrow().as_deref() != Some(owner.as_str()) {
                        return;
                    }
                    state.registered.set(result.is_ok());
                    state.check_host();
                }
            },
        );
    }
    fn check_host(self: &Rc<Self>) {
        if !self.registered.get() || self.checking.replace(true) {
            return;
        }
        let Some(owner) = self.owner.borrow().clone() else {
            self.checking.set(false);
            return;
        };
        let weak = Rc::downgrade(self);
        self.connection.call(
            Some(&owner),
            WATCHER_PATH,
            "org.freedesktop.DBus.Properties",
            "Get",
            Some(&(WATCHER, "IsStatusNotifierHostRegistered").to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            1500,
            gio::Cancellable::NONE,
            {
                let owner = owner.clone();
                move |result| {
                    let Some(state) = weak.upgrade() else { return };
                    state.checking.set(false);
                    if state.owner.borrow().as_deref() != Some(owner.as_str()) {
                        return;
                    }
                    let available = result
                        .ok()
                        .and_then(|value| value.get::<(glib::Variant,)>())
                        .and_then(|(value,)| value.get::<bool>())
                        .unwrap_or(false);
                    state.set_available(available);
                }
            },
        );
    }
    fn item_property(&self, name: &str) -> glib::Variant {
        let pixmaps: Vec<(i32, i32, Vec<u8>)> = Vec::new();
        match name {
            "Category" => "ApplicationStatus".to_variant(),
            "Id" => "axo".to_variant(),
            "Title" => "Axo".to_variant(),
            "Status" => "Active".to_variant(),
            "WindowId" => 0_u32.to_variant(),
            "IconName" => "utilities-terminal".to_variant(),
            "AttentionIconName" => "dialog-warning".to_variant(),
            "OverlayIconName" | "AttentionMovieName" | "IconThemePath" => "".to_variant(),
            "IconPixmap" | "OverlayIconPixmap" | "AttentionIconPixmap" => pixmaps.to_variant(),
            "ToolTip" => (
                "utilities-terminal",
                pixmaps,
                "Axo",
                self.daemon.borrow().as_str(),
            )
                .to_variant(),
            "ItemIsMenu" => false.to_variant(),
            "Menu" => glib::variant::ObjectPath::try_from(MENU_PATH)
                .expect("static menu path")
                .to_variant(),
            _ => unreachable!("introspected item property"),
        }
    }
    fn properties(&self, id: i32, names: &[String]) -> Option<HashMap<String, glib::Variant>> {
        let mut properties = HashMap::new();
        if id == 0 {
            properties.insert("children-display".into(), "submenu".to_variant());
        } else {
            let label = if id == 5 {
                self.daemon.borrow().clone()
            } else {
                match id {
                    1 => "Show Axo",
                    2 => "Hide Axo",
                    3 => "Settings…",
                    4 => "Quit Axo",
                    _ => return None,
                }
                .to_owned()
            };
            properties.insert("label".into(), label.to_variant());
            properties.insert("enabled".into(), (id != 5).to_variant());
            properties.insert("visible".into(), true.to_variant());
        }
        if !names.is_empty() {
            properties.retain(|name, _| names.contains(name));
        }
        Some(properties)
    }
    fn event(&self, id: i32, event: &str) -> bool {
        let Some(action) = Action::from_id(id) else {
            return false;
        };
        if event == "clicked" {
            (self.action)(action);
        }
        true
    }
    fn menu_call(&self, method: &str, parameters: glib::Variant) -> Option<glib::Variant> {
        Some(match method {
            "GetLayout" => {
                let (id, depth, names) = parameters.get::<(i32, i32, Vec<String>)>()?;
                if depth < -1 {
                    return None;
                }
                let properties = self.properties(id, &names)?;
                let children: Vec<glib::Variant> = if id == 0 && depth != 0 {
                    (1..=5)
                        .map(|id| {
                            (
                                id,
                                self.properties(id, &names).expect("static item"),
                                Vec::<glib::Variant>::new(),
                            )
                                .to_variant()
                        })
                        .collect()
                } else {
                    Vec::new()
                };
                (self.revision.get(), (id, properties, children)).to_variant()
            }
            "GetGroupProperties" => {
                let (ids, names) = parameters.get::<(Vec<i32>, Vec<String>)>()?;
                let ids = if ids.is_empty() {
                    (0..=5).collect()
                } else {
                    ids
                };
                let result: Vec<_> = ids
                    .into_iter()
                    .filter_map(|id| {
                        self.properties(id, &names)
                            .map(|properties| (id, properties))
                    })
                    .collect();
                (result,).to_variant()
            }
            "GetProperty" => {
                let (id, name) = parameters.get::<(i32, String)>()?;
                (self.properties(id, &[])?.remove(&name)?,).to_variant()
            }
            "Event" => {
                let (id, event, _, _) = parameters.get::<(i32, String, glib::Variant, u32)>()?;
                if !self.event(id, &event) {
                    return None;
                }
                ().to_variant()
            }
            "EventGroup" => {
                let (events,) = parameters.get::<(Vec<(i32, String, glib::Variant, u32)>,)>()?;
                let failed: Vec<_> = events
                    .into_iter()
                    .filter_map(|(id, event, _, _)| (!self.event(id, &event)).then_some(id))
                    .collect();
                (failed,).to_variant()
            }
            "AboutToShow" => {
                let (id,) = parameters.get::<(i32,)>()?;
                self.properties(id, &[])?;
                (false,).to_variant()
            }
            "AboutToShowGroup" => {
                let (ids,) = parameters.get::<(Vec<i32>,)>()?;
                let errors: Vec<_> = ids
                    .into_iter()
                    .filter(|id| self.properties(*id, &[]).is_none())
                    .collect();
                (Vec::<i32>::new(), errors).to_variant()
            }
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_explicit_menu_ids_are_actions() {
        assert!(matches!(Action::from_id(4), Some(Action::Quit)));
        for id in [-1, 0, 5, 999] {
            assert!(Action::from_id(id).is_none());
        }
    }
    #[test]
    fn native_bus_interfaces_are_valid_introspection_xml() {
        assert!(
            gio::DBusNodeInfo::for_xml(ITEM_XML)
                .unwrap()
                .lookup_interface(ITEM)
                .is_some()
        );
        assert!(
            gio::DBusNodeInfo::for_xml(MENU_XML)
                .unwrap()
                .lookup_interface(MENU)
                .is_some()
        );
    }
}

const ITEM_XML: &str = r#"<node><interface name="org.kde.StatusNotifierItem">
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="WindowId" type="u" access="read"/><property name="IconName" type="s" access="read"/>
<property name="IconPixmap" type="a(iiay)" access="read"/><property name="OverlayIconName" type="s" access="read"/>
<property name="OverlayIconPixmap" type="a(iiay)" access="read"/><property name="AttentionIconName" type="s" access="read"/>
<property name="AttentionIconPixmap" type="a(iiay)" access="read"/><property name="AttentionMovieName" type="s" access="read"/>
<property name="IconThemePath" type="s" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
<signal name="NewToolTip"/></interface></node>"#;
const MENU_XML: &str = r#"<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>"#;
