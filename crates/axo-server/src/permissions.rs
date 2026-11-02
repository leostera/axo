//! The macOS privacy permissions (TCC) what Sessions run needs.
//!
//! macOS charges everything axod's shells, Pi and their commands do to axod, the process
//! responsible for them, not to Axo.app: axod is the one that must hold these grants, and the
//! one whose prompts the person answers.
//!
//! - Automation: scripting other apps (`osascript`, Shortcuts). axod asks for the apps Sessions
//!   script most when launchd starts it, so the prompts come up once, while the person is there,
//!   rather than in the middle of a Session's work, where a command would hang on them.
//! - Developer Tools: a developer tool's children skip the scan macOS gives every new program
//!   before it first runs, which makes builds and test runs much faster. macOS has no prompt for
//!   it; the person adds axod in System Settings. axod reports whether it is allowed in
//!   `axo.daemon.health`, and Axo offers to open that pane.

use axo_protocol::rpc::PermissionState;

/// launchd's label for the axod Axo.app runs; set in `XPC_SERVICE_NAME` for its agents.
const LAUNCH_AGENT_LABEL: &str = "dev.leostera.axo.axod";

/// The apps Sessions script most, by bundle ID, with an Apple Event each answers, so asking
/// for permission changes nothing.
const AUTOMATION_TARGETS: &[(&str, &str)] = &[
    ("com.apple.systemevents", "count every process"),
    ("com.apple.finder", "count every Finder window"),
];

/// Whether axod is allowed as a developer tool; `None` off macOS or when TCC cannot say.
pub fn developer_tools() -> Option<PermissionState> {
    tcc::preflight("kTCCServiceDeveloperTool")
}

/// Asks for Automation of [`AUTOMATION_TARGETS`] on a thread of its own, when this is the axod
/// launchd runs for Axo.app. Tests and a hand-started axod never put prompts up.
pub fn request_automation_if_launch_agent() {
    if std::env::var("XPC_SERVICE_NAME").as_deref() != Ok(LAUNCH_AGENT_LABEL) {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("axod-permissions".to_owned())
        .spawn(|| {
            for (target, event) in AUTOMATION_TARGETS {
                request_automation(target, event);
            }
            match developer_tools() {
                Some(state) => log::info!("event=permissions.developer_tools state={state:?}"),
                None => log::info!("event=permissions.developer_tools state=unknown"),
            }
        });
    if let Err(error) = spawned {
        log::warn!(
            "event=permissions.request_failed error_kind={:?}",
            error.kind()
        );
    }
}

/// Sends `target` one Apple Event through `osascript`, as a Session would: TCC asks the person
/// the first time, and answers at once after.
fn request_automation(target: &str, event: &str) {
    let output = std::process::Command::new("/usr/bin/osascript")
        .args([
            "-e",
            &format!("tell application id \"{target}\" to {event}"),
        ])
        .stdin(std::process::Stdio::null())
        .output();
    match output {
        Ok(output) if output.status.success() => {
            log::info!("event=permissions.automation target={target} state=granted");
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            // errAEEventNotPermitted: the person said no, now or before.
            let state = if stderr.contains("-1743") {
                "denied"
            } else {
                "failed"
            };
            log::info!(
                "event=permissions.automation target={target} state={state} detail={:?}",
                stderr.trim()
            );
        }
        Err(error) => log::warn!(
            "event=permissions.automation target={target} state=failed error_kind={:?}",
            error.kind()
        ),
    }
}

#[cfg(target_os = "macos")]
mod tcc {
    use std::ffi::c_void;
    use std::sync::OnceLock;

    use axo_protocol::rpc::PermissionState;
    use core_foundation::base::TCFType;
    use core_foundation::string::{CFString, CFStringRef};

    type Preflight = unsafe extern "C" fn(CFStringRef, *const c_void) -> i32;

    /// TCC's `TCCAccessPreflight`, which says how the calling process stands for a service
    /// without asking: 0 allowed, 1 denied (or not in the list, for Developer Tools), 2 never
    /// asked. TCC.framework is private, so it is looked up rather than linked, and a macOS
    /// without it just cannot say.
    fn preflight_function() -> Option<Preflight> {
        static FUNCTION: OnceLock<Option<Preflight>> = OnceLock::new();
        *FUNCTION.get_or_init(|| {
            // SAFETY: dlopen and dlsym take NUL-terminated names; the library is never closed,
            // so the symbol stays valid, and it has the signature TCC has shipped since 10.14.
            unsafe {
                let library = libc::dlopen(
                    c"/System/Library/PrivateFrameworks/TCC.framework/TCC".as_ptr(),
                    libc::RTLD_NOW | libc::RTLD_LOCAL,
                );
                if library.is_null() {
                    return None;
                }
                let symbol = libc::dlsym(library, c"TCCAccessPreflight".as_ptr());
                (!symbol.is_null()).then(|| std::mem::transmute::<*mut c_void, Preflight>(symbol))
            }
        })
    }

    pub(super) fn preflight(service: &str) -> Option<PermissionState> {
        let function = preflight_function()?;
        let service = CFString::new(service);
        // SAFETY: a valid CFString for the call's duration and no options.
        match unsafe { function(service.as_concrete_TypeRef(), std::ptr::null()) } {
            0 => Some(PermissionState::Granted),
            1 => Some(PermissionState::Denied),
            2 => Some(PermissionState::NotAsked),
            _ => None,
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod tcc {
    use axo_protocol::rpc::PermissionState;

    pub(super) fn preflight(_service: &str) -> Option<PermissionState> {
        None
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn tcc_answers_for_developer_tools_on_a_mac() {
        assert!(
            developer_tools().is_some(),
            "TCCAccessPreflight is found and answers one of its three states"
        );
    }
}
