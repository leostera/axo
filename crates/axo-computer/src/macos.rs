use cua_driver_core::tool::ToolRegistry;

pub(super) fn registry() -> ToolRegistry {
    let cursor = cursor_overlay::CursorConfig {
        enabled: false,
        ..Default::default()
    };
    // Axo owns permission UX; Cua must not prompt or start another host app.
    platform_macos::register_tools_with_cursor(cursor, false, true, Some("dev.leostera.axo".into()))
}

pub(super) fn permissions() -> (bool, bool) {
    let status = platform_macos::permissions::current_status();
    (status.accessibility, status.screen_recording)
}

pub(super) async fn locked() -> bool {
    screen_locked()
}

pub(super) async fn preflight() -> Option<String> {
    None
}

/// The login session's CGSSessionScreenIsLocked; preserve the existing macOS probe.
pub fn screen_locked() -> bool {
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::string::CFString;

    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGSessionCopyCurrentDictionary() -> CFDictionaryRef;
    }
    // SAFETY: Copy returns an owned dictionary, or null outside a login session.
    let session = unsafe { CGSessionCopyCurrentDictionary() };
    if session.is_null() {
        return false;
    }
    // SAFETY: the non-null dictionary follows the Copy ownership rule.
    let session: CFDictionary<CFString, core_foundation::base::CFType> =
        unsafe { CFDictionary::wrap_under_create_rule(session) };
    session
        .find(CFString::from_static_string("CGSSessionScreenIsLocked"))
        .and_then(|value| value.downcast::<CFBoolean>())
        .is_some_and(bool::from)
}
