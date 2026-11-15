//! Read-only startup observations from axod, the responsible process for Session tools.
//! Only an explicit signed-app request may ask for a grant. Never prompt on daemon boot.
use axo_ipc::{
    ErrorCode, IoHandler, Only, RpcError, TypedMethods,
    peer::{Caller, Signer},
};
use axo_protocol::rpc::{
    self, AutomationPermissionTarget as Target, PermissionAccess as Access, PermissionState,
};
use std::sync::Mutex;

pub fn developer_tools() -> Option<PermissionState> {
    tcc::preflight("kTCCServiceDeveloperTool")
}
fn access(state: Option<PermissionState>) -> Access {
    match state {
        Some(PermissionState::Granted) => Access::Granted,
        Some(PermissionState::Denied) => Access::NotGranted,
        Some(PermissionState::NotAsked) => Access::NotAsked,
        None => Access::Unknown,
    }
}
fn granted(value: bool) -> Access {
    if value {
        Access::Granted
    } else {
        Access::NotGranted
    }
}

pub fn snapshot() -> rpc::DaemonPermissions {
    let supported = axo_computer::AVAILABLE;
    let (ax, screen) = axo_computer::permissions();
    rpc::DaemonPermissions {
        process_id: std::process::id(),
        supported,
        accessibility: if supported {
            granted(ax)
        } else {
            Access::Unsupported
        },
        screen_recording: if supported {
            granted(screen)
        } else {
            Access::Unsupported
        },
        input_control: platform::input_control(),
        developer_tools: if supported {
            access(developer_tools())
        } else {
            Access::Unsupported
        },
        full_disk_access: if supported {
            access(tcc::preflight("kTCCServiceSystemPolicyAllFiles"))
        } else {
            Access::Unsupported
        },
        automation_finder: platform::automation(Target::Finder),
        automation_system_events: platform::automation(Target::SystemEvents),
        locked: axo_computer::screen_locked(),
    }
}
fn error(code: i64, message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::ServerError(code),
        message: message.into(),
        data: None,
    }
}
pub fn register(handler: &mut IoHandler) {
    handler.add_typed(
        rpc::method::DAEMON_PERMISSIONS,
        "expected no parameters",
        |_: rpc::NoParams| async {
            tokio::task::spawn_blocking(snapshot)
                .await
                .map_err(|_| error(-32000, "permission check failed"))
        },
    );
    handler.add_typed_only(
        Only {
            caller: Caller::Signed(Signer::AxoApp),
            code: -32099,
            message: "only Axo.app may request OS permission from an explicit setup action",
        },
        rpc::method::DAEMON_PERMISSION_REQUEST,
        "expected {target: finder|systemEvents}",
        |request: rpc::RequestAutomationPermission| async move {
            tokio::task::spawn_blocking(move || request_automation(request.target))
                .await
                .map_err(|_| error(-32000, "permission request failed; recheck before retrying"))?
        },
    );
}
fn target(target: Target) -> (&'static str, &'static str) {
    match target {
        Target::Finder => ("com.apple.finder", "count every Finder window"),
        Target::SystemEvents => ("com.apple.systemevents", "count every process"),
    }
}
fn request_automation(request: Target) -> Result<Access, RpcError> {
    if !cfg!(target_os = "macos") {
        return Err(error(
            -32000,
            "Automation permission is supported on macOS only",
        ));
    }
    static REQUEST: Mutex<()> = Mutex::new(());
    // The blocking worker owns the slot through OS completion, even after a lost receipt.
    let _slot = match REQUEST.try_lock() {
        Ok(slot) => slot,
        Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => {
            return Err(error(
                -32006,
                "another permission request is still in progress",
            ));
        }
    };
    let (bundle, event) = target(request);
    let child = std::process::Command::new("/usr/bin/osascript")
        .args([
            "-e",
            &format!("tell application id \"{bundle}\" to {event}"),
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|_| error(-32000, "could not ask macOS for Automation permission"))?;
    let mut owned = OwnedPrompt(child);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
    loop {
        match owned.0.try_wait() {
            Ok(Some(status)) => {
                return Ok(if status.success() {
                    Access::Granted
                } else {
                    platform::automation(request)
                });
            }
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(100))
            }
            _ => {
                return Err(error(
                    -32008,
                    "permission request did not finish; recheck before trying again",
                ));
            }
        }
    }
}
/// Receipt loss cannot orphan the prompt process. On deadline/unwind kill and reap before
/// releasing the request slot; successful/failed exits are already reaped by try_wait.
struct OwnedPrompt(std::process::Child);
impl Drop for OwnedPrompt {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}
#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::ffi::c_void;
    // Apple AEDataModel.h uses #pragma pack(push, 2), including on LP64.
    #[repr(C, packed(2))]
    struct Descriptor {
        kind: u32,
        data: *mut c_void,
    }
    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn AECreateDesc(
            kind: u32,
            data: *const c_void,
            length: libc::c_long,
            result: *mut Descriptor,
        ) -> i16;
        fn AEDisposeDesc(desc: *mut Descriptor) -> i16;
        fn AEDeterminePermissionToAutomateTarget(
            desc: *const Descriptor,
            class: u32,
            event: u32,
            ask: u8,
        ) -> i32;
    }
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGPreflightPostEventAccess() -> bool;
    }
    pub fn input_control() -> Access {
        // SAFETY: public, argument-free, read-only preflight on supported macOS versions.
        granted(unsafe { CGPreflightPostEventAccess() })
    }
    pub fn automation(request: Target) -> Access {
        let bundle = target(request).0.as_bytes();
        let mut desc = Descriptor {
            kind: 0,
            data: std::ptr::null_mut(),
        };
        // SAFETY: the packed descriptor matches Apple's ABI; bytes live through creation,
        // the successful descriptor is disposed exactly once. ask=0 never prompts or launches.
        unsafe {
            if AECreateDesc(
                u32::from_be_bytes(*b"bund"),
                bundle.as_ptr().cast(),
                bundle.len() as libc::c_long,
                &mut desc,
            ) != 0
            {
                return Access::Unknown;
            }
            let result = AEDeterminePermissionToAutomateTarget(
                &desc,
                u32::from_be_bytes(*b"****"),
                u32::from_be_bytes(*b"****"),
                0,
            );
            AEDisposeDesc(&mut desc);
            classify(result)
        }
    }
    fn classify(code: i32) -> Access {
        match code {
            0 => Access::Granted,
            -1743 => Access::NotGranted,
            -1744 => Access::NotAsked,
            -600 => Access::NotRunning,
            _ => Access::Unknown,
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn apple_event_abi_and_unknown_results_are_explicit() {
            assert_eq!(std::mem::size_of::<Descriptor>(), 12);
            assert_eq!(std::mem::align_of::<Descriptor>(), 2);
            assert_eq!(classify(-600), Access::NotRunning);
            assert_eq!(classify(-1744), Access::NotAsked);
            assert_eq!(classify(1234), Access::Unknown);
        }
    }
}
#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;
    pub fn input_control() -> Access {
        Access::Unsupported
    }
    pub fn automation(_: Target) -> Access {
        Access::Unsupported
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

#[cfg(test)]
mod wire_tests {
    use super::*;
    #[tokio::test]
    async fn report_is_live_and_unsigned_callers_cannot_request_any_permission() {
        let mut methods = IoHandler::new();
        register(&mut methods);
        let report = methods
            .handle_request(r#"{"jsonrpc":"2.0","id":1,"method":"axo.daemon.permissions"}"#)
            .await
            .unwrap();
        let value: serde_json::Value = serde_json::from_str(&report).unwrap();
        assert_eq!(value["result"]["processId"], std::process::id());
        assert!(value["result"]["supported"].is_boolean());
        for key in [
            "accessibility",
            "inputControl",
            "screenRecording",
            "developerTools",
            "fullDiskAccess",
            "automationFinder",
            "automationSystemEvents",
        ] {
            assert!(matches!(
                value["result"][key].as_str(),
                Some(
                    "granted"
                        | "notGranted"
                        | "notAsked"
                        | "notRunning"
                        | "unknown"
                        | "unsupported"
                )
            ));
        }
        // Admission precedes parsing/effects. Even malformed input must not open a prompt.
        for params in [
            r#"{"target":"finder"}"#,
            r#"{"target":"anything","script":"never execute"}"#,
        ] {
            let request = format!(
                r#"{{"jsonrpc":"2.0","id":2,"method":"axo.daemon.permissions.request","params":{params}}}"#
            );
            let response = methods.handle_request(&request).await.unwrap();
            let value: serde_json::Value = serde_json::from_str(&response).unwrap();
            assert_eq!(value["error"]["code"], -32099);
        }
    }
}
