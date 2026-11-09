//! Reading a window's sign-in form and filling it, for input requests (RFD0029, the side channel
//! for input). axod does this itself, in its own process, so what the person types never passes
//! through `axod mcp` or the agent.
//!
//! The reading is axod's own: the fields and buttons it finds, their labels, the app and the
//! page's address (a browser web area's `AXURL`, never the address bar the agent can type in).
//! The person is shown that reading, and the fill goes to exactly the elements it found: if the
//! page changed in between (another address, or those elements gone), nothing is filled.
//!
//! Built on Cua's Accessibility bindings (`platform_macos::ax::bindings`).

use std::fmt;

/// What a field is for, as the person's form shows it (autofill hints, a secure entry).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldKind {
    Username,
    Email,
    Password,
    /// A one-time code.
    Code,
    Text,
}

impl FieldKind {
    pub fn parse(kind: &str) -> Option<Self> {
        Some(match kind {
            "username" => Self::Username,
            "email" => Self::Email,
            "password" => Self::Password,
            "code" => Self::Code,
            "text" => Self::Text,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Username => "username",
            Self::Email => "email",
            Self::Password => "password",
            Self::Code => "code",
            Self::Text => "text",
        }
    }
}

/// One text entry axod found in the window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldReading {
    /// Its title, description, placeholder or titling element: what the person sees beside it.
    pub label: String,
    /// A secure text field: the app itself never shows its value.
    pub secure: bool,
}

/// Why a form could not be read or filled.
#[derive(Debug, PartialEq, Eq)]
pub struct FormError(pub String);

impl fmt::Display for FormError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

fn fail<T>(message: impl Into<String>) -> Result<T, FormError> {
    Err(FormError(message.into()))
}

/// The origin of `url` (`scheme://host[:port]`), or the URL itself when it has no host.
pub fn origin_of(url: &str) -> String {
    match url.split_once("://") {
        Some((scheme, rest)) => {
            let host = rest.split(['/', '?', '#']).next().unwrap_or("");
            let host = host.rsplit_once('@').map_or(host, |(_, host)| host);
            format!(
                "{}://{}",
                scheme.to_ascii_lowercase(),
                host.to_ascii_lowercase()
            )
        }
        None => url.to_owned(),
    }
}

/// Picks the field for a requested `(label, kind)`: by its label when the agent named one, else
/// the only secure field for a password, or the entry just before it for a username or email.
pub fn pick_field(
    fields: &[FieldReading],
    label: Option<&str>,
    kind: FieldKind,
) -> Result<usize, FormError> {
    let labels = || {
        fields
            .iter()
            .map(|field| format!("\"{}\"", field.label))
            .collect::<Vec<_>>()
            .join(", ")
    };
    if fields.is_empty() {
        return fail("the window has no text fields to fill");
    }
    if let Some(label) = label {
        let wanted = label.trim().to_lowercase();
        let matches: Vec<usize> = (0..fields.len())
            .filter(|&index| fields[index].label.trim().to_lowercase() == wanted)
            .collect();
        return match matches.as_slice() {
            [index] if kind == FieldKind::Password && !fields[*index].secure => fail(format!(
                "\"{label}\" is not a secure field; a password goes only into one"
            )),
            [index] => Ok(*index),
            [] => fail(format!(
                "no field labelled \"{label}\"; the window's fields are {}",
                labels()
            )),
            _ => fail(format!(
                "more than one field is labelled \"{label}\"; the window's fields are {}",
                labels()
            )),
        };
    }
    let secure: Vec<usize> = (0..fields.len())
        .filter(|&index| fields[index].secure)
        .collect();
    match kind {
        FieldKind::Password => match secure.as_slice() {
            [index] => Ok(*index),
            [] => fail(format!(
                "the window has no password field; its fields are {}",
                labels()
            )),
            _ => fail(format!(
                "the window has more than one password field: name one by `label`; its fields are {}",
                labels()
            )),
        },
        FieldKind::Username | FieldKind::Email => {
            let plain: Vec<usize> = (0..fields.len())
                .filter(|&index| !fields[index].secure)
                .collect();
            let before_password = secure
                .first()
                .and_then(|&first| plain.iter().rev().find(|&&index| index < first).copied());
            match (before_password, plain.as_slice()) {
                (Some(index), _) | (None, &[index]) => Ok(index),
                _ => fail(format!(
                    "name the {} field by `label`; the window's fields are {}",
                    kind.as_str(),
                    labels()
                )),
            }
        }
        FieldKind::Code | FieldKind::Text => match (0..fields.len())
            .filter(|&index| !fields[index].secure)
            .collect::<Vec<_>>()
            .as_slice()
        {
            [index] => Ok(*index),
            _ => fail(format!(
                "name the field by `label`; the window's fields are {}",
                labels()
            )),
        },
    }
}

pub use imp::Form;

#[cfg(target_os = "macos")]
mod imp {
    use core_foundation::base::{CFRelease, CFRetain, CFType, CFTypeRef, TCFType};
    use platform_macos::ax::bindings::{
        self as ax, AXUIElementRef, copy_ax_window_by_remote_token, copy_ax_windows, copy_children,
        copy_element_attr, copy_string_attr, copy_url_attr, kAXErrorSuccess,
    };

    use super::{FieldReading, FormError, fail, origin_of};

    /// Elements visited at most, and how deep: a sign-in page is far smaller.
    const MAX_ELEMENTS: usize = 6_000;
    const MAX_DEPTH: usize = 80;

    /// A retained Accessibility element.
    struct Element(AXUIElementRef);

    // An AXUIElement is an immutable CoreFoundation reference: safe to hold on any thread.
    unsafe impl Send for Element {}

    impl Element {
        fn same_as(&self, other: &Element) -> bool {
            unsafe {
                let a = CFType::wrap_under_get_rule(self.0 as CFTypeRef);
                let b = CFType::wrap_under_get_rule(other.0 as CFTypeRef);
                a == b
            }
        }

        fn string(&self, attribute: &str) -> Option<String> {
            unsafe { copy_string_attr(self.0, attribute) }.filter(|value| !value.trim().is_empty())
        }
    }

    impl Clone for Element {
        fn clone(&self) -> Self {
            unsafe { CFRetain(self.0 as CFTypeRef) };
            Element(self.0)
        }
    }

    impl Drop for Element {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0 as CFTypeRef) };
        }
    }

    /// A window's form as axod read it.
    pub struct Form {
        pub pid: i32,
        pub window_id: u32,
        /// The app's name, from the running-apps list.
        pub app: String,
        pub window_title: String,
        /// The page's origin, from the web area's `AXURL`; `None` outside a browser.
        pub origin: Option<String>,
        pub fields: Vec<FieldReading>,
        /// Buttons by their titles, in the page when there is one.
        pub buttons: Vec<String>,
        field_elements: Vec<Element>,
        button_elements: Vec<Element>,
    }

    struct Walk {
        visited: usize,
        web_area: Option<Element>,
        fields: Vec<(FieldReading, Element)>,
        buttons: Vec<(String, Element)>,
    }

    fn label_of(element: &Element) -> String {
        element
            .string("AXTitle")
            .or_else(|| element.string("AXDescription"))
            .or_else(|| element.string("AXPlaceholderValue"))
            .or_else(|| {
                let titled =
                    unsafe { copy_element_attr(element.0, "AXTitleUIElement") }.map(Element)?;
                titled
                    .string("AXValue")
                    .or_else(|| titled.string("AXTitle"))
            })
            .unwrap_or_default()
    }

    fn walk(element: &Element, depth: usize, in_page: bool, walk: &mut Walk) {
        if walk.visited >= MAX_ELEMENTS || depth > MAX_DEPTH {
            return;
        }
        walk.visited += 1;
        let role = element.string("AXRole").unwrap_or_default();
        let subrole = element.string("AXSubrole").unwrap_or_default();
        let mut in_page = in_page;
        if role == "AXWebArea" && walk.web_area.is_none() {
            walk.web_area = Some(element.clone());
            // A page's form only: the browser's own address bar and search fields are not it.
            walk.fields.clear();
            walk.buttons.clear();
            in_page = true;
        }
        let counts = walk.web_area.is_none() || in_page;
        let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField";
        if counts
            && (secure
                || matches!(
                    role.as_str(),
                    "AXTextField" | "AXTextArea" | "AXComboBox" | "AXSearchField"
                ))
        {
            walk.fields.push((
                FieldReading {
                    label: label_of(element),
                    secure,
                },
                element.clone(),
            ));
            return;
        }
        if counts && role == "AXButton" {
            let label = label_of(element);
            if !label.is_empty() {
                walk.buttons.push((label, element.clone()));
            }
        }
        for child in unsafe { copy_children(element.0) } {
            self::walk(&Element(child), depth + 1, in_page, walk);
        }
    }

    fn window(pid: i32, window_id: u32) -> Result<Element, FormError> {
        unsafe {
            if !ax::AXIsProcessTrusted() {
                return fail("Axo has no Accessibility permission on this Mac");
            }
            let app = ax::AXUIElementCreateApplication(pid);
            if app.is_null() {
                return fail(format!("no app with pid {pid}"));
            }
            let app = Element(app);
            ax::AXUIElementSetMessagingTimeout(app.0, 2.0);
            let windows: Vec<Element> = copy_ax_windows(app.0).into_iter().map(Element).collect();
            if let Some(found) = windows
                .into_iter()
                .find(|w| ax::ax_get_window_id(w.0) == Some(window_id))
            {
                return Ok(found);
            }
            copy_ax_window_by_remote_token(pid, window_id)
                .map(Element)
                .ok_or_else(|| FormError(format!("pid {pid} has no window {window_id}")))
        }
    }

    impl Form {
        /// Reads the form in `window_id` of `pid`.
        pub fn read(pid: i32, window_id: u32) -> Result<Form, FormError> {
            let window = window(pid, window_id)?;
            let mut found = Walk {
                visited: 0,
                web_area: None,
                fields: Vec::new(),
                buttons: Vec::new(),
            };
            walk(&window, 0, false, &mut found);
            let origin = found
                .web_area
                .as_ref()
                .and_then(|area| unsafe { copy_url_attr(area.0) })
                .map(|url| origin_of(&url));
            let app = platform_macos::apps::list_running_apps()
                .into_iter()
                .find(|app| app.pid == pid)
                .map(|app| app.name)
                .unwrap_or_else(|| format!("pid {pid}"));
            let (fields, field_elements) = found.fields.into_iter().unzip();
            let (buttons, button_elements) = found.buttons.into_iter().unzip();
            Ok(Form {
                pid,
                window_id,
                app,
                window_title: window.string("AXTitle").unwrap_or_default(),
                origin,
                fields,
                buttons,
                field_elements,
                button_elements,
            })
        }

        /// Whether the window still shows this form: the same address, and these exact fields
        /// (and button) still in it. Otherwise nothing may be filled.
        pub fn check_unchanged(
            &self,
            fields: &[usize],
            button: Option<usize>,
        ) -> Result<(), FormError> {
            let now = Form::read(self.pid, self.window_id)
                .map_err(|_| FormError("the window is gone".into()))?;
            if now.origin != self.origin {
                return fail(format!(
                    "the page changed: it is now {}",
                    now.origin.as_deref().unwrap_or("not a web page")
                ));
            }
            let present = |mine: &Element, theirs: &[Element]| {
                theirs.iter().any(|element| element.same_as(mine))
            };
            let fields_present = fields
                .iter()
                .all(|&index| present(&self.field_elements[index], &now.field_elements));
            let button_present = button
                .is_none_or(|index| present(&self.button_elements[index], &now.button_elements));
            if fields_present && button_present {
                Ok(())
            } else {
                fail("the page changed: the fields it asked for are gone")
            }
        }

        /// Puts `value` into field `index`.
        pub fn fill(&self, index: usize, value: &str) -> Result<(), FormError> {
            let element = &self.field_elements[index];
            unsafe {
                let _ = ax::set_bool_attr_true(element.0, "AXFocused");
                if ax::set_string_attr(element.0, "AXValue", value) != kAXErrorSuccess {
                    return fail(format!(
                        "\"{}\" did not take a value",
                        self.fields[index].label
                    ));
                }
            }
            // A secure field reads back masked; a plain one must read back what was put in.
            if !self.fields[index].secure && element.string("AXValue").as_deref() != Some(value) {
                return fail(format!(
                    "\"{}\" did not keep its value",
                    self.fields[index].label
                ));
            }
            Ok(())
        }

        /// Presses button `index`.
        pub fn press(&self, index: usize) -> Result<(), FormError> {
            if unsafe { ax::perform_action(self.button_elements[index].0, "AXPress") }
                == kAXErrorSuccess
            {
                Ok(())
            } else {
                fail(format!("\"{}\" could not be pressed", self.buttons[index]))
            }
        }
    }
}

#[cfg(windows)]
#[path = "form_windows.rs"]
mod imp;

#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    use super::{FieldReading, FormError, fail};

    pub struct Form {
        pub pid: i32,
        pub window_id: u32,
        pub app: String,
        pub window_title: String,
        pub origin: Option<String>,
        pub fields: Vec<FieldReading>,
        pub buttons: Vec<String>,
    }

    impl Form {
        pub fn read(_pid: i32, _window_id: u32) -> Result<Form, FormError> {
            fail("computer use is only available on macOS")
        }
        pub fn check_unchanged(&self, _: &[usize], _: Option<usize>) -> Result<(), FormError> {
            fail("computer use is only available on macOS")
        }
        pub fn fill(&self, _: usize, _: &str) -> Result<(), FormError> {
            fail("computer use is only available on macOS")
        }
        pub fn press(&self, _: usize) -> Result<(), FormError> {
            fail("computer use is only available on macOS")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(label: &str, secure: bool) -> FieldReading {
        FieldReading {
            label: label.into(),
            secure,
        }
    }

    #[test]
    fn an_origin_is_its_scheme_and_host() {
        assert_eq!(
            origin_of("https://GitHub.com/login?return_to=%2F"),
            "https://github.com"
        );
        assert_eq!(origin_of("http://localhost:8765/"), "http://localhost:8765");
        assert_eq!(
            origin_of("https://user:pw@evil.test/x"),
            "https://evil.test"
        );
    }

    #[test]
    fn fields_are_picked_by_label_or_by_what_they_are_for() {
        let form = [
            field("Search", false),
            field("Email", false),
            field("Password", true),
        ];
        assert_eq!(pick_field(&form, None, FieldKind::Password), Ok(2));
        assert_eq!(pick_field(&form, None, FieldKind::Email), Ok(1));
        assert_eq!(pick_field(&form, Some("email"), FieldKind::Username), Ok(1));
        assert!(
            pick_field(&form, Some("Email"), FieldKind::Password)
                .unwrap_err()
                .0
                .contains("not a secure field")
        );
        assert!(
            pick_field(&form, Some("Name"), FieldKind::Text)
                .unwrap_err()
                .0
                .contains("\"Search\", \"Email\", \"Password\"")
        );
        assert!(
            pick_field(
                &[field("A", true), field("B", true)],
                None,
                FieldKind::Password
            )
            .is_err()
        );
        assert!(pick_field(&[], None, FieldKind::Password).is_err());
    }
}
