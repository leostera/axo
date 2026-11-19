//! Metadata-only AT-SPI form binding. No foreground typing, clipboard or existing-value reads.
use super::{FieldReading, FormError, fail};
use futures_util::StreamExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};
use zbus::{Connection, Proxy, proxy::CacheProperties, zvariant::OwnedObjectPath};

type Address = (String, OwnedObjectPath);
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const DEADLINE: Duration = Duration::from_secs(10);
const REFUSED: &str =
    "The GUI target could not be verified; no foreground or clipboard fallback is permitted.";

#[derive(Clone, Debug, Eq, PartialEq)]
struct Element {
    bus: String,
    path: OwnedObjectPath,
    role: u32,
    label: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
struct Document {
    element: Element,
    url: String,
}

pub struct Form {
    pub pid: i32,
    pub window_id: u64,
    pub app: String,
    pub window_title: String,
    pub origin: Option<String>,
    pub fields: Vec<FieldReading>,
    pub buttons: Vec<String>,
    connection: Connection,
    process: String,
    frame: Address,
    documents: Vec<Document>,
    field_elements: Vec<Element>,
    button_elements: Vec<Element>,
    guard: fn() -> bool,
    changes: Changes,
    protected: HashSet<String>,
}

struct Changes {
    stream: tokio::sync::Mutex<Option<zbus::MessageStream>>,
    dirty: AtomicBool,
}
impl Changes {
    async fn watch(connection: &Connection, sender: &str) -> Result<Self, FormError> {
        let rule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender(sender)
            .map_err(fixed)?
            .interface("org.a11y.atspi.Event.Object")
            .map_err(fixed)?
            .member("ChildrenChanged")
            .map_err(fixed)?
            .build();
        let stream = zbus::MessageStream::for_match_rule(rule, connection, Some(64))
            .await
            .map_err(fixed)?;
        let registry = Proxy::new(
            connection,
            "org.a11y.atspi.Registry",
            "/org/a11y/atspi/registry",
            "org.a11y.atspi.Registry",
        )
        .await
        .map_err(fixed)?;
        let _: () = registry
            .call("RegisterEvent", &("object:children-changed",))
            .await
            .map_err(fixed)?;
        Ok(Self {
            stream: tokio::sync::Mutex::new(Some(stream)),
            dirty: AtomicBool::new(false),
        })
    }
    async fn changed(&self, protected: &HashSet<String>) -> bool {
        if self.dirty.load(Ordering::Acquire) {
            return true;
        }
        let mut stream = self.stream.lock().await;
        let Some(stream) = stream.as_mut() else {
            return true;
        };
        for _ in 0..64 {
            match tokio::time::timeout(Duration::from_millis(2), stream.next()).await {
                Err(_) => return false,
                Ok(Some(Ok(message)))
                    if message
                        .header()
                        .path()
                        .is_some_and(|path| !protected.contains(path.as_str())) =>
                {
                    continue;
                }
                _ => {
                    self.dirty.store(true, Ordering::Release);
                    return true;
                }
            }
        }
        self.dirty.store(true, Ordering::Release);
        true
    }
}

impl Drop for Changes {
    fn drop(&mut self) {
        let stream = self.stream.get_mut().take();
        // zbus removes its match through an executor task on drop. Form handles also
        // retire on blocking workers, so enter the owner runtime before retiring it.
        if tokio::runtime::Handle::try_current().is_ok() {
            drop(stream);
        } else {
            crate::native::block_on(async move {
                drop(stream);
            });
        }
    }
}

fn fixed(_: impl std::fmt::Display) -> FormError {
    FormError(REFUSED.into())
}
async fn proxy<'a>(
    connection: &'a Connection,
    address: &'a Address,
    interface: &'a str,
) -> Result<Proxy<'a>, FormError> {
    zbus::proxy::Builder::new(connection)
        .destination(address.0.as_str())
        .map_err(fixed)?
        .path(address.1.as_str())
        .map_err(fixed)?
        .interface(interface)
        .map_err(fixed)?
        .cache_properties(CacheProperties::No)
        .build()
        .await
        .map_err(fixed)
}
async fn accessible<'a>(
    connection: &'a Connection,
    address: &'a Address,
) -> Result<Proxy<'a>, FormError> {
    // Disable GetAll caching: some Qt bridges mishandle that method. Never cache changing form metadata.
    zbus::proxy::Builder::new(connection)
        .destination(address.0.as_str())
        .map_err(fixed)?
        .path(address.1.as_str())
        .map_err(fixed)?
        .interface(ACCESSIBLE)
        .map_err(fixed)?
        .cache_properties(CacheProperties::No)
        .build()
        .await
        .map_err(fixed)
}
fn identity(pid: i32) -> Result<String, FormError> {
    if pid <= 0 {
        return fail(REFUSED);
    }
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).map_err(fixed)?;
    stat.rsplit_once(')')
        .and_then(|(_, tail)| tail.split_whitespace().nth(19))
        .map(str::to_owned)
        .ok_or_else(|| fixed("no process identity"))
}
fn bounded<T>(
    work: impl std::future::Future<Output = Result<T, FormError>>,
) -> Result<T, FormError> {
    crate::native::block_on(async { tokio::time::timeout(DEADLINE, work).await.map_err(fixed)? })
}
async fn connection() -> Result<Connection, FormError> {
    let session = Connection::session().await.map_err(fixed)?;
    let bus = Proxy::new(&session, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus")
        .await
        .map_err(fixed)?;
    let address: String = bus.call("GetAddress", &()).await.map_err(fixed)?;
    zbus::connection::Builder::address(address.as_str())
        .map_err(fixed)?
        .build()
        .await
        .map_err(fixed)
}
async fn owner(connection: &Connection, name: &str) -> Result<String, FormError> {
    let bus = Proxy::new(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .await
    .map_err(fixed)?;
    bus.call("GetNameOwner", &(name,)).await.map_err(fixed)
}
async fn process_id(connection: &Connection, name: &str) -> Result<u32, FormError> {
    let bus = Proxy::new(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .await
    .map_err(fixed)?;
    bus.call("GetConnectionUnixProcessID", &(name,))
        .await
        .map_err(fixed)
}
async fn children(connection: &Connection, address: &Address) -> Result<Vec<Address>, FormError> {
    accessible(connection, address)
        .await?
        .call("GetChildren", &())
        .await
        .map_err(fixed)
}
async fn element(
    connection: &Connection,
    address: &Address,
) -> Result<(Element, Vec<String>, Vec<u32>), FormError> {
    let accessible = accessible(connection, address).await?;
    // Numeric roles are the protocol contract. GTK 4 can call PasswordText (40)
    // "text box" through GetRoleName, so names/labels cannot attest secure fields.
    let role: u32 = accessible.call("GetRole", &()).await.map_err(fixed)?;
    let name: String = accessible.get_property("Name").await.map_err(fixed)?;
    let interfaces: Vec<String> = accessible.call("GetInterfaces", &()).await.map_err(fixed)?;
    let state: Vec<u32> = accessible.call("GetState", &()).await.map_err(fixed)?;
    let label = if name.trim().is_empty() {
        let attrs: HashMap<String, String> =
            accessible.call("GetAttributes", &()).await.map_err(fixed)?;
        attrs
            .get("placeholder-text")
            .or_else(|| attrs.get("placeholder"))
            .cloned()
            .unwrap_or_default()
    } else {
        name
    };
    Ok((
        Element {
            bus: address.0.clone(),
            path: address.1.clone(),
            role,
            label,
        },
        interfaces,
        state,
    ))
}
fn state_has(state: &[u32], bit: usize) -> bool {
    state
        .get(bit / 32)
        .is_some_and(|word| word & (1 << (bit % 32)) != 0)
}
fn usable(state: &[u32]) -> bool {
    // AT-SPI State ordinals: Defunct=6, Sensitive=24, Showing=25. GTK omits Enabled
    // for editable controls; Sensitive attests interaction, not keyboard focus.
    !state_has(state, 6) && state_has(state, 24) && state_has(state, 25)
}
async fn application(connection: &Connection, pid: i32) -> Result<Address, FormError> {
    let registry: Address = (
        "org.a11y.atspi.Registry".into(),
        OwnedObjectPath::try_from("/org/a11y/atspi/accessible/root").map_err(fixed)?,
    );
    let mut matches = Vec::new();
    for (name, path) in children(connection, &registry).await? {
        let bus = owner(connection, &name).await?;
        if process_id(connection, &bus).await? == pid as u32 {
            matches.push((bus, path));
        }
    }
    if matches.len() != 1 {
        return fail(REFUSED);
    }
    Ok(matches.remove(0))
}

#[derive(serde::Serialize)]
pub struct InputWindow {
    pid: i32,
    window_id: u64,
    app: String,
    window_title: String,
}

/// Discover the accessibility handles that secure form reads actually accept.
/// Compositor window IDs and editable field values never enter this inventory.
pub fn input_windows(pid: i32) -> Result<Vec<InputWindow>, FormError> {
    input_windows_with_guard(pid, crate::screen_locked)
}

fn input_windows_with_guard(pid: i32, guard: fn() -> bool) -> Result<Vec<InputWindow>, FormError> {
    if guard() {
        return fail(crate::LOCKED);
    }
    let process = identity(pid)?;
    let windows = bounded(async {
        let connection = connection().await?;
        let application = application(&connection, pid).await?;
        let frames = children(&connection, &application).await?;
        if frames.len() > 64 {
            return fail("This application has too many input windows to inspect at once.");
        }
        let executable = std::fs::read_link(format!("/proc/{pid}/exe")).map_err(fixed)?;
        let mut windows = Vec::new();
        for (ordinal, mut address) in frames.into_iter().enumerate() {
            address.0 = owner(&connection, &address.0).await?;
            if address.0 != application.0 {
                return fail(REFUSED);
            }
            let accessible = accessible(&connection, &address).await?;
            let role: u32 = accessible.call("GetRole", &()).await.map_err(fixed)?;
            if !matches!(role, 2 | 16 | 23 | 69) {
                continue;
            }
            let window_title: String = accessible.get_property("Name").await.map_err(fixed)?;
            windows.push(InputWindow {
                pid,
                window_id: ((pid as u64) << 16) | ordinal as u64,
                app: executable.to_string_lossy().into_owned(),
                window_title,
            });
        }
        Ok(windows)
    })?;
    if guard() {
        return fail(crate::LOCKED);
    }
    if identity(pid)? != process {
        return fail(REFUSED);
    }
    Ok(windows)
}

async fn read(
    connection: Connection,
    pid: i32,
    window_id: u64,
    guard: fn() -> bool,
) -> Result<Form, FormError> {
    let process = identity(pid)?;
    // AT-SPI handles are (kernel PID << 16) | top-level ordinal. Never cast them to u32.
    if window_id >> 16 != pid as u64 {
        return fail(
            "Use the AT-SPI window handle for this process; compositor window IDs are not secure form targets.",
        );
    }
    let ordinal = (window_id & 0xffff) as usize;
    let application = application(&connection, pid).await?;
    let frames = children(&connection, &application).await?;
    let mut frame = frames
        .get(ordinal)
        .cloned()
        .ok_or_else(|| fixed("missing window"))?;
    frame.0 = owner(&connection, &frame.0).await?;
    if frame.0 != application.0 {
        return fail(REFUSED);
    }
    let changes = Changes::watch(&connection, &frame.0).await?;
    let (frame_meta, _, _) = element(&connection, &frame).await?;
    if !matches!(frame_meta.role, 2 | 16 | 23 | 69) {
        return fail(REFUSED);
    }
    let mut stack = vec![(frame.clone(), 0usize, false)];
    let mut seen = HashSet::new();
    let mut page_paths = HashSet::new();
    let mut native_fields = Vec::new();
    let mut page_fields = Vec::new();
    let mut native_buttons = Vec::new();
    let mut page_buttons = Vec::new();
    let mut documents: Vec<Document> = Vec::new();
    while let Some((mut address, depth, in_page)) = stack.pop() {
        if depth > 80 || seen.len() >= 6000 {
            return fail("The accessibility form is incomplete; nothing will be filled.");
        }
        address.0 = owner(&connection, &address.0).await?;
        if address.0 != frame.0 {
            return fail("Cross-process accessibility forms are not yet supported securely.");
        }
        if !seen.insert(address.clone()) {
            return fail(REFUSED);
        }
        let (node, interfaces, state) = element(&connection, &address).await?;
        let is_document = interfaces.iter().any(|i| i == "org.a11y.atspi.Document");
        if matches!(node.role, 82 | 95) && !is_document {
            return fail("The browser document interface could not be verified.");
        }
        let mut in_page = in_page;
        if is_document {
            let document = proxy(&connection, &address, "org.a11y.atspi.Document").await?;
            let url: String = document
                .call("GetAttributeValue", &("DocURL",))
                .await
                .map_err(fixed)?;
            let parsed = url::Url::parse(&url).map_err(fixed)?;
            if matches!(parsed.scheme(), "https" | "http") && parsed.host_str().is_some() {
                in_page = true;
                if documents
                    .iter()
                    .any(|doc| super::origin_of(&doc.url) != super::origin_of(&url))
                {
                    return fail("Mixed-origin forms are not supported; no values will be filled.");
                }
                documents.push(Document {
                    element: node.clone(),
                    url,
                });
            } else if in_page
                || !matches!(
                    parsed.scheme(),
                    "chrome" | "resource" | "about" | "chrome-extension" | "moz-extension"
                )
            {
                return fail("The browser document origin could not be verified.");
            }
            // Firefox exposes its outer chrome as a Document too. Traverse it to find
            // the actual HTTP(S) page, but never count chrome-owned fields as page input.
        }
        if in_page {
            page_paths.insert(address.1.to_string());
        }
        let editable = interfaces
            .iter()
            .any(|i| i == "org.a11y.atspi.EditableText");
        if usable(&state)
            && state_has(&state, 7)
            && editable
            && matches!(node.role, 11 | 40 | 61 | 79)
        {
            if in_page {
                page_fields.push(node);
            } else {
                native_fields.push(node);
            }
            continue;
        } else if usable(&state) && node.role == 43 && !node.label.trim().is_empty() {
            if in_page {
                page_buttons.push(node);
            } else {
                native_buttons.push(node);
            }
        }
        let descendants = children(&connection, &address).await?;
        for child in descendants.into_iter().rev() {
            stack.push((child, depth + 1, in_page));
        }
    }
    let mut protected = if documents.is_empty() {
        seen.iter()
            .map(|(_, path): &Address| path.to_string())
            .collect()
    } else {
        page_paths
    };
    protected.insert(frame.1.to_string());
    if identity(pid)? != process || changes.changed(&protected).await {
        return fail(REFUSED);
    }
    let (field_elements, button_elements) = if documents.is_empty() {
        (native_fields, native_buttons)
    } else {
        (page_fields, page_buttons)
    };
    let fields = field_elements
        .iter()
        .map(|field| FieldReading {
            label: field.label.clone(),
            secure: field.role == 40,
        })
        .collect();
    let buttons = button_elements
        .iter()
        .map(|button| button.label.clone())
        .collect();
    let executable = std::fs::read_link(format!("/proc/{pid}/exe")).map_err(fixed)?;
    if documents.is_empty()
        && executable
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                matches!(
                    name,
                    "chrome"
                        | "chromium"
                        | "chromium-browser"
                        | "firefox"
                        | "brave"
                        | "vivaldi"
                        | "opera"
                        | "epiphany"
                )
            })
    {
        return fail("The browser page origin is unavailable; browser chrome will not be filled.");
    }
    Ok(Form {
        pid,
        window_id,
        app: executable.to_string_lossy().into_owned(),
        window_title: frame_meta.label,
        origin: documents.first().map(|doc| super::origin_of(&doc.url)),
        fields,
        buttons,
        connection,
        process,
        frame,
        documents,
        field_elements,
        button_elements,
        guard,
        changes,
        protected,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_keeps_large_handles_and_refuses_locked_desktops_before_bus_access() {
        assert_eq!(
            input_windows_with_guard(0, || true).err().unwrap().0,
            crate::LOCKED
        );
        let window = InputWindow {
            pid: 100_000,
            window_id: 100_000u64 << 16,
            app: "/owned/fixture".into(),
            window_title: "Sign in".into(),
        };
        let value = serde_json::to_value(window).unwrap();
        assert_eq!(value["window_id"].as_u64(), Some(100_000u64 << 16));
        assert!(value["window_id"].as_u64().unwrap() > u32::MAX as u64);
    }
    #[test]
    #[ignore = "run linux/gui-input-smoke.sh with the isolated GTK fixture"]
    fn real_gui_form_uses_exact_fields_without_focus_or_secret_readback() {
        assert_eq!(
            std::env::var("AXO_LINUX_ISOLATED_DESKTOP").as_deref(),
            Ok("1")
        );
        let pid: i32 = std::env::var("AXO_LINUX_FIXTURE_PID")
            .unwrap()
            .parse()
            .unwrap();
        let window_id = (pid as u64) << 16;
        let mut form = None;
        for _ in 0..20 {
            if let Ok(found) =
                bounded(async { read(connection().await?, pid, window_id, || false).await })
            {
                if found.fields.len() == 2 {
                    form = Some(found);
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(150));
        }
        let form = form.expect("the owned GTK form should expose two verifiable inputs");
        assert_eq!(form.window_id, window_id);
        let windows = input_windows_with_guard(pid, || false).unwrap();
        assert!(windows.iter().any(|window| window.pid == pid
            && window.window_id == window_id
            && window.window_title == form.window_title));
        static LOCK_CHECKS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        assert!(
            input_windows_with_guard(pid, || LOCK_CHECKS
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                > 0)
            .is_err()
        );
        let email = form.fields.iter().position(|f| f.label == "Email").unwrap();
        let password = form
            .fields
            .iter()
            .position(|f| f.label == "Password")
            .unwrap();
        assert!(form.fields[password].secure);
        assert!(!form.fields[email].secure);
        assert!(
            crate::form::pick_field(
                &form.fields,
                Some("Email"),
                crate::form::FieldKind::Password
            )
            .is_err()
        );
        form.check_unchanged(&[email, password], None).unwrap();
        form.fill(email, "fixture@example.test").unwrap();
        form.fill(password, "synthetic-gui-password").unwrap();
        static FORM_LOCK_CHECKS: std::sync::atomic::AtomicUsize =
            std::sync::atomic::AtomicUsize::new(0);
        assert!(
            Form::read_with_guard(pid, window_id, || FORM_LOCK_CHECKS
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                > 0)
            .is_err()
        );
        let reading = Form::read_with_guard(pid, window_id, || false).unwrap();
        let metadata =
            serde_json::to_value(crate::input_targets::FormReading::from(reading)).unwrap();
        assert_eq!(metadata["binding_available"], true);
        assert_eq!(metadata["delivery_confirmation"], "required_per_operation");
        assert!(!metadata.to_string().contains("synthetic-gui-password"));
        assert!(!metadata.to_string().contains("fixture@example.test"));
        let verify = form
            .buttons
            .iter()
            .position(|label| label == "Verify input")
            .unwrap();
        form.press(verify).unwrap();
        let report = std::path::PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap())
            .join("gui-input-digest");
        for _ in 0..30 {
            if report.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert_eq!(
            std::fs::read_to_string(report).unwrap(),
            "5aebc6a3473826cfb7d6d806fef0fa8aff728fa97783dbf1b0050c2bd4640b94"
        );
        let replace = form
            .buttons
            .iter()
            .position(|label| label == "Replace password")
            .unwrap();
        form.press(replace).unwrap();
        let replaced = std::path::PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap())
            .join("gui-input-replaced");
        for _ in 0..30 {
            if replaced.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(
            replaced.exists(),
            "the replacement button must actually run"
        );
        let now = bounded(read(form.connection.clone(), pid, window_id, || false)).unwrap();
        assert_ne!(form.field_elements[password], now.field_elements[password]);
        assert!(
            form.check_unchanged(&[password], None).is_err(),
            "a replacement field must not inherit an old approval"
        );
        assert!(form.fill(password, "must-not-be-delivered").is_err());
    }

    #[test]
    #[ignore = "run the private browser fixture through linux/computer-smoke.sh"]
    fn real_browser_form_checks_origin_and_never_fills_browser_chrome() {
        assert_eq!(
            std::env::var("AXO_LINUX_ISOLATED_DESKTOP").as_deref(),
            Ok("1")
        );
        let root = std::path::PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap());
        let pid_file = root.join("gui-browser-pid");
        for _ in 0..100 {
            if pid_file.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let pid: i32 = std::fs::read_to_string(pid_file).unwrap().parse().unwrap();
        let window_id = (pid as u64) << 16;
        let mut form = None;
        for _ in 0..40 {
            match bounded(async { read(connection().await?, pid, window_id, || false).await }) {
                Ok(found)
                    if found.fields.len() == 2
                        && found.window_title.contains("Axo secure browser fixture") =>
                {
                    form = Some(found);
                    break;
                }
                Ok(_) => {}
                Err(error) => eprintln!("private browser fixture not ready: {error}"),
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        let form = form.expect("the private browser must expose a bound document form");
        let url = std::fs::read_to_string(root.join("gui-browser-url")).unwrap();
        assert_eq!(form.origin, Some(super::super::origin_of(&url)));
        let password = form.fields.iter().position(|field| field.secure).unwrap();
        let email = form.fields.iter().position(|field| !field.secure).unwrap();
        form.fill(email, "fixture@example.test").unwrap();
        form.fill(password, "synthetic-gui-password").unwrap();
        let verify = form
            .buttons
            .iter()
            .position(|label| label == "Verify input")
            .unwrap();
        form.press(verify).unwrap();
        let report = root.join("gui-browser-digest");
        for _ in 0..50 {
            if report.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert_eq!(
            std::fs::read_to_string(report).unwrap(),
            "5aebc6a3473826cfb7d6d806fef0fa8aff728fa97783dbf1b0050c2bd4640b94"
        );
        let navigate = form
            .buttons
            .iter()
            .position(|label| label == "Change page")
            .unwrap();
        form.press(navigate).unwrap();
        for _ in 0..30 {
            if form.check_unchanged(&[password], None).is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("navigation must invalidate the old form approval");
    }
}

impl Form {
    pub fn read(pid: i32, window_id: u64) -> Result<Self, FormError> {
        Self::read_with_guard(pid, window_id, crate::screen_locked)
    }
    fn read_with_guard(pid: i32, window_id: u64, guard: fn() -> bool) -> Result<Self, FormError> {
        if guard() {
            return fail(crate::LOCKED);
        }
        let form = bounded(async { read(connection().await?, pid, window_id, guard).await })?;
        if guard() {
            return fail(crate::LOCKED);
        }
        Ok(form)
    }
    pub fn check_unchanged(
        &self,
        fields: &[usize],
        button: Option<usize>,
    ) -> Result<(), FormError> {
        if (self.guard)() {
            return fail(crate::LOCKED);
        }
        if bounded(async { Ok(self.changes.changed(&self.protected).await) })? {
            return fail("The form structure changed; its old approval cannot be reused.");
        }
        let now = bounded(read(
            self.connection.clone(),
            self.pid,
            self.window_id,
            self.guard,
        ))?;
        if (self.guard)() {
            return fail(crate::LOCKED);
        }
        if bounded(async { Ok(self.changes.changed(&self.protected).await) })? {
            return fail("The form structure changed; its old approval cannot be reused.");
        }
        if now.process != self.process
            || now.app != self.app
            || now.window_title != self.window_title
            || now.frame != self.frame
            || now.documents != self.documents
        {
            return fail("The app, window or page changed; nothing will be filled.");
        }
        if fields.iter().any(|&index| {
            self.field_elements
                .get(index)
                .is_none_or(|old| !now.field_elements.contains(old))
        }) || button.is_some_and(|index| {
            self.button_elements
                .get(index)
                .is_none_or(|old| !now.button_elements.contains(old))
        }) {
            return fail("The requested fields or button changed; nothing will be filled.");
        }
        Ok(())
    }
    pub fn fill(&self, index: usize, value: &str) -> Result<(), FormError> {
        self.check_unchanged(&[index], None)?;
        let field = self
            .field_elements
            .get(index)
            .ok_or_else(|| fixed("missing field"))?;
        bounded(async {
            let address = (field.bus.clone(), field.path.clone());
            let target = proxy(&self.connection, &address, "org.a11y.atspi.EditableText").await?;
            let text = proxy(&self.connection, &address, "org.a11y.atspi.Text").await?;
            let count: i32 = text.get_property("CharacterCount").await.map_err(fixed)?;
            if count < 0 {
                return fail(REFUSED);
            }
            if count > 0 {
                let cleared: bool = target
                    .call("DeleteText", &(0i32, count))
                    .await
                    .map_err(fixed)?;
                if !cleared {
                    return fail("The field refused replacement; no input fallback was attempted.");
                }
            }
            // Gecko can acknowledge SetTextContents without editing the DOM. Use one
            // explicit replacement sequence, not a speculative write followed by retry.
            let accepted: bool = target
                .call("InsertText", &(0i32, value, value.chars().count() as i32))
                .await
                .map_err(fixed)?;
            if !accepted {
                return fail(
                    "The field input was not confirmed; it may have changed. Do not retry automatically.",
                );
            }
            // Observe queued renderer IPC settling, never repeat a write on stale readback.
            let settle = tokio::time::Instant::now() + Duration::from_secs(2);
            loop {
                let confirmed = if self.fields[index].secure {
                    let count: i32 = text.get_property("CharacterCount").await.map_err(fixed)?;
                    count == value.chars().count() as i32
                } else {
                    let count: i32 = text.get_property("CharacterCount").await.map_err(fixed)?;
                    if count < 0 {
                        return fail(REFUSED);
                    }
                    let kept: String = text.call("GetText", &(0i32, count)).await.map_err(fixed)?;
                    let kept = zeroize::Zeroizing::new(kept);
                    kept.as_str() == value
                };
                if confirmed {
                    return Ok(());
                }
                if tokio::time::Instant::now() >= settle {
                    return fail(
                        "The field did not confirm the intended value; do not retry automatically.",
                    );
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
    }
    pub fn press(&self, index: usize) -> Result<(), FormError> {
        self.check_unchanged(&[], Some(index))?;
        let button = self
            .button_elements
            .get(index)
            .ok_or_else(|| fixed("missing button"))?;
        bounded(async {
            let address = (button.bus.clone(), button.path.clone());
            let action = proxy(&self.connection, &address, "org.a11y.atspi.Action").await?;
            let count: i32 = action.get_property("NActions").await.map_err(fixed)?;
            if !(1..=16).contains(&count) {
                return fail("The button action list could not be verified.");
            }
            // Firefox can return placeholder strings from GetActions. Query canonical
            // action names individually, never guess what action zero does.
            let mut safe = Vec::new();
            for index in 0..count {
                let name: String = action.call("GetName", &(index,)).await.map_err(fixed)?;
                if matches!(name.to_lowercase().as_str(), "click" | "press" | "activate") {
                    safe.push(index);
                }
            }
            if safe.len() != 1 {
                return fail("The button has no single verified activation action.");
            }
            let accepted: bool = action
                .call("DoAction", &(safe[0] as i32,))
                .await
                .map_err(fixed)?;
            if accepted {
                Ok(())
            } else {
                fail("The button refused activation; it was not retried.")
            }
        })
    }
}
