//! Only this host Mac's existing Axo sidebar pins keep its agents running (RFD0085).
//! No network synchronization, new pin store, or writes to the person's preferences.
use crate::core::Core;
use axo_protocol::SessionId;
use std::collections::HashSet;
use std::io;
use std::sync::Arc;
use std::time::Duration;

type PinSet = HashSet<SessionId>;
pub(crate) struct LocalPins {
    slot: Arc<tokio::sync::Semaphore>,
    #[cfg(test)]
    source: std::sync::Mutex<Box<dyn Fn() -> io::Result<PinSet> + Send>>,
}
impl Default for LocalPins {
    fn default() -> Self {
        Self {
            slot: Arc::new(tokio::sync::Semaphore::new(1)),
            #[cfg(test)]
            source: std::sync::Mutex::new(Box::new(|| Ok(PinSet::new()))),
        }
    }
}
impl LocalPins {
    fn load(&self) -> io::Result<PinSet> {
        #[cfg(test)]
        {
            (crate::core::lock(&self.source))()
        }
        #[cfg(not(test))]
        {
            platform::load()
        }
    }
    #[cfg(test)]
    pub(crate) fn use_source(&self, source: impl Fn() -> io::Result<PinSet> + Send + 'static) {
        *crate::core::lock(&self.source) = Box::new(source);
    }
}

/// One bounded blocking preferences read per core. A timeout skips sleep rather than assuming
/// nothing is pinned; its worker retains the slot until it actually returns.
pub(crate) async fn read(core: &Arc<Core>) -> io::Result<PinSet> {
    let permit = Arc::clone(&core.local_pins.slot)
        .try_acquire_owned()
        .map_err(|_| io::Error::new(io::ErrorKind::WouldBlock, "pin preferences reader busy"))?;
    let core = Arc::clone(core);
    let task = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        core.local_pins.load()
    });
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .map_err(io::Error::other)?
        .map_err(io::Error::other)?
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, CFTypeRef, TCFType};
    use core_foundation::string::{CFString, CFStringRef};

    unsafe extern "C" {
        fn CFPreferencesCopyAppValue(key: CFStringRef, application: CFStringRef) -> CFTypeRef;
        fn CFPreferencesAppSynchronize(application: CFStringRef) -> u8;
    }

    pub(super) fn load() -> io::Result<PinSet> {
        let app = CFString::new("dev.leostera.axo");
        let key = CFString::new("sidebar.pinnedSessions.v1");
        // SAFETY: both strings live across these calls. Copy returns an owned CF object;
        // null means this existing preference has never been set.
        unsafe {
            if CFPreferencesAppSynchronize(app.as_concrete_TypeRef()) == 0 {
                return Err(io::Error::other("could not refresh local pin preferences"));
            }
            let value =
                CFPreferencesCopyAppValue(key.as_concrete_TypeRef(), app.as_concrete_TypeRef());
            if value.is_null() {
                return Ok(PinSet::new());
            }
            parse(&CFType::wrap_under_create_rule(value))
        }
    }

    fn parse(value: &CFType) -> io::Result<PinSet> {
        let array = value
            .downcast::<CFArray>()
            .ok_or_else(|| io::Error::other("local pins must be an array"))?;
        if array.len() > 256 {
            return Err(io::Error::other("too many local pins"));
        }
        let mut pins = PinSet::new();
        for item in array.iter() {
            // SAFETY: CFArray retains each object for the lifetime of this iteration.
            let value = unsafe { CFType::wrap_under_get_rule(*item) };
            let text = value
                .downcast::<CFString>()
                .ok_or_else(|| io::Error::other("local pin must be a string"))?;
            // Match the Mac's SessionPins parser: stale non-UUID strings do nothing.
            if let Ok(id) = text.to_string().parse::<SessionId>() {
                pins.insert(id);
            }
        }
        Ok(pins)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn parses_only_the_bounded_native_pin_preference_shape() {
            let id = axo_protocol::new_uuid_v4().unwrap();
            let array =
                CFArray::from_CFTypes(&[CFString::new(&id), CFString::new("old-invalid-id")]);
            assert_eq!(parse(&array.as_CFType()).unwrap().len(), 1);
            assert!(parse(&CFString::new("not an array").as_CFType()).is_err());
            let too_many = CFArray::from_CFTypes(&vec![CFString::new(&id); 257]);
            assert!(parse(&too_many.as_CFType()).is_err());
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;
    pub(super) fn load() -> io::Result<PinSet> {
        Ok(PinSet::new())
    }
}
