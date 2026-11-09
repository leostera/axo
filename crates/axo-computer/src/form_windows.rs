//! Retained UI Automation elements, never agent-supplied selectors or keystrokes.
use super::{FieldReading, FormError, fail, origin_of};
use windows::Win32::{
    Foundation::HWND,
    System::Com::*,
    UI::{Accessibility::*, WindowsAndMessaging::*},
};
use windows::core::BSTR;

fn error(_: windows::core::Error) -> FormError {
    FormError("The form is unavailable or does not support secure filling.".into())
}
struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

pub struct Form {
    pub pid: i32,
    pub window_id: u32,
    pub app: String,
    pub window_title: String,
    pub origin: Option<String>,
    pub fields: Vec<FieldReading>,
    pub buttons: Vec<String>,
    fields_native: Vec<IUIAutomationElement>,
    buttons_native: Vec<IUIAutomationElement>,
    document: Option<IUIAutomationElement>,
    automation: IUIAutomation,
    // COM elements must be released before the apartment.
    _apartment: Apartment,
}

impl Form {
    pub fn read(pid: i32, window_id: u32) -> Result<Self, FormError> {
        if crate::screen_locked() {
            return fail(crate::LOCKED);
        }
        unsafe {
            let hwnd = HWND(window_id as usize as *mut _);
            let mut owner = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut owner));
            if owner != pid as u32 || !IsWindow(hwnd).as_bool() {
                return fail("The target window is gone.");
            }
            CoInitializeEx(None, COINIT_MULTITHREADED)
                .ok()
                .map_err(error)?;
            let apartment = Apartment;
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).map_err(error)?;
            let root = automation.ElementFromHandle(hwnd).map_err(error)?;
            let title = root.CurrentName().map_err(error)?.to_string();
            let class = root.CurrentClassName().map_err(error)?.to_string();
            let app = platform_windows::win32::apps::list_processes()
                .into_iter()
                .find(|p| p.pid == pid as u32)
                .map(|p| p.name)
                .unwrap_or_else(|| format!("Process {pid}"));
            let mut result = Self {
                pid,
                window_id,
                app,
                window_title: title,
                origin: None,
                fields: vec![],
                buttons: vec![],
                fields_native: vec![],
                buttons_native: vec![],
                document: None,
                automation,
                _apartment: apartment,
            };
            let walker = result.automation.ControlViewWalker().map_err(error)?;
            let mut remaining = 6000;
            result.walk(&walker, &root, 0, &mut remaining, false)?;
            if (class.starts_with("Chrome_") || class == "MozillaWindowClass")
                && result.origin.is_none()
            {
                return fail(
                    "The browser did not expose a document URL. Axo cannot verify this form's origin.",
                );
            }
            Ok(result)
        }
    }

    fn walk(
        &mut self,
        walker: &IUIAutomationTreeWalker,
        element: &IUIAutomationElement,
        depth: usize,
        left: &mut usize,
        in_document: bool,
    ) -> Result<(), FormError> {
        if *left == 0 || depth > 80 {
            return fail("The form is too large to verify completely.");
        }
        *left -= 1;
        unsafe {
            let kind = element.CurrentControlType().map_err(error)?;
            if element.CurrentIsOffscreen().map_err(error)?.as_bool() {
                return Ok(());
            }
            let mut in_document = in_document;
            if kind == UIA_DocumentControlTypeId {
                if self.document.is_some() {
                    return fail("Multiple documents are visible; choose a window with one form.");
                }
                let pattern: IUIAutomationValuePattern = element
                    .GetCurrentPatternAs(UIA_ValuePatternId)
                    .map_err(error)?;
                let url = pattern.CurrentValue().map_err(error)?.to_string();
                if !(url.starts_with("https://") || url.starts_with("http://")) {
                    return fail("The document has no verifiable web origin.");
                }
                self.origin = Some(origin_of(&url));
                self.document = Some(element.clone());
                self.fields.clear();
                self.fields_native.clear();
                self.buttons.clear();
                self.buttons_native.clear();
                in_document = true;
            }
            if (self.document.is_none() || in_document)
                && element.CurrentIsEnabled().map_err(error)?.as_bool()
            {
                let mut label = element.CurrentName().map_err(error)?.to_string();
                if label.is_empty() {
                    if let Ok(labeled) = element.CurrentLabeledBy() {
                        label = labeled.CurrentName().map_err(error)?.to_string();
                    }
                }
                if kind == UIA_EditControlTypeId {
                    // A value pattern is required; never paste or send keyboard secrets.
                    let pattern: IUIAutomationValuePattern = element
                        .GetCurrentPatternAs(UIA_ValuePatternId)
                        .map_err(error)?;
                    if !pattern.CurrentIsReadOnly().map_err(error)?.as_bool() {
                        self.fields.push(FieldReading {
                            label,
                            secure: element.CurrentIsPassword().map_err(error)?.as_bool(),
                        });
                        self.fields_native.push(element.clone());
                    }
                } else if kind == UIA_ButtonControlTypeId && !label.is_empty() {
                    self.buttons.push(label);
                    self.buttons_native.push(element.clone());
                }
            }
            if let Ok(mut child) = walker.GetFirstChildElement(element) {
                loop {
                    self.walk(walker, &child, depth + 1, left, in_document)?;
                    match walker.GetNextSiblingElement(&child) {
                        Ok(next) => child = next,
                        Err(_) => break,
                    }
                }
            }
        }
        Ok(())
    }

    pub fn check_unchanged(
        &self,
        fields: &[usize],
        button: Option<usize>,
    ) -> Result<(), FormError> {
        let now = Self::read(self.pid, self.window_id)?;
        unsafe {
            let same = |a: &IUIAutomationElement, b: &IUIAutomationElement| {
                self.automation
                    .CompareElements(a, b)
                    .is_ok_and(|v| v.as_bool())
            };
            if self.origin != now.origin
                || self.window_title != now.window_title
                || match (&self.document, &now.document) {
                    (Some(a), Some(b)) => !same(a, b),
                    (None, None) => false,
                    _ => true,
                }
            {
                return fail("The page or window changed. Read it again and ask again.");
            }
            for &index in fields {
                if !now.fields_native.iter().enumerate().any(|(j, e)| {
                    same(&self.fields_native[index], e) && self.fields[index] == now.fields[j]
                }) {
                    return fail("The form fields changed.");
                }
            }
            if let Some(i) = button {
                if !now.buttons_native.iter().enumerate().any(|(j, e)| {
                    same(&self.buttons_native[i], e) && self.buttons[i] == now.buttons[j]
                }) {
                    return fail("The submit button changed.");
                }
                if now
                    .buttons
                    .iter()
                    .filter(|b| **b == self.buttons[i])
                    .count()
                    != 1
                {
                    return fail("The submit button is ambiguous.");
                }
            }
        }
        Ok(())
    }
    pub fn fill(&self, index: usize, value: &str) -> Result<(), FormError> {
        self.check_unchanged(&[index], None)?;
        if value.contains('\0') {
            return fail("A field value cannot contain a null character.");
        }
        let wide = BSTR::from(value);
        let result = unsafe {
            self.fields_native[index]
                .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                .and_then(|p| p.SetValue(&wide))
        };
        for index in 0..wide.len() {
            unsafe {
                std::ptr::write_volatile(wide.as_ptr().cast_mut().add(index), 0);
            }
        }
        result.map_err(error)
    }
    pub fn press(&self, index: usize) -> Result<(), FormError> {
        self.check_unchanged(&[], Some(index))?;
        unsafe {
            self.buttons_native[index]
                .GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                .and_then(|p| p.Invoke())
                .map_err(error)
        }
    }
}
