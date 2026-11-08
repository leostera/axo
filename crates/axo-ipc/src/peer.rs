//! Who is on the other end of `axod.sock`, by code signature (RFD0029).
//!
//! Any process running as the person can connect, including an agent's scripts, so the socket's
//! file mode says nothing about *which* program is asking. For the few methods where that
//! matters, a handler asks [`current`] and checks it with [`Peer::is`]:
//! - [`Signer::ThisBinary`]: the same program as this daemon, such as `axod mcp`. Its computer-use
//!   gate asks the person as Axo, not as the agent.
//! - [`Signer::AxoApp`]: Axo.app, the only local client that answers the person's questions.
//!
//! The account's calls arrive over the relay connection inside axod, not the socket: they run as
//! [`Peer::Relay`], which no socket client can be, and a method meant for them admits only
//! [`Caller::Relay`].
//!
//! The check uses the connection's audit token (`LOCAL_PEERTOKEN`), not its pid, so a process that
//! exits and whose pid is reused cannot pass for it. The kernel validates the peer's code
//! signature as it runs, so a modified binary fails. Off macOS nothing passes.

use std::cell::Cell;

/// Who sent the request being handled.
#[derive(Clone, Copy, Debug)]
pub enum Peer {
    /// A program connected to the socket, with its audit token if the kernel gave one.
    Socket { token: Option<[u8; 32]> },
    /// The account, through this process's relay connection.
    Relay,
}

impl Default for Peer {
    /// Outside any request: a socket peer nobody can verify.
    fn default() -> Self {
        Self::Socket { token: None }
    }
}

/// Whom a method answers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Caller {
    /// A local program signed as this.
    Signed(Signer),
    /// The account, through the relay.
    Relay,
}

/// What a peer may be signed as.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Signer {
    /// The same signed program as this process: same team and identifier, or, for an
    /// unsigned build, the same binary.
    ThisBinary,
    /// Axo.app, signed by the same team as this process. An unsigned build has no Axo.app.
    AxoApp,
}

tokio::task_local! {
    static TASK_PEER: Peer;
}

thread_local! {
    static THREAD_PEER: Cell<Option<Peer>> = const { Cell::new(None) };
}

/// The peer of the request being handled: nobody outside a connection.
pub fn current() -> Peer {
    THREAD_PEER
        .with(Cell::get)
        .or_else(|| TASK_PEER.try_with(|peer| *peer).ok())
        .unwrap_or_default()
}

/// Runs `request` with `peer` as [`current`], for an async handler.
pub(crate) async fn scope<F: Future>(peer: Peer, request: F) -> F::Output {
    TASK_PEER.scope(peer, request).await
}

/// Runs `method` as the account's request through the relay.
pub fn as_relay<R>(method: impl FnOnce() -> R) -> R {
    on_this_thread(Peer::Relay, method)
}

/// Runs `method` with `peer` as [`current`], for a handler on the blocking pool.
pub(crate) fn on_this_thread<R>(peer: Peer, method: impl FnOnce() -> R) -> R {
    let previous = THREAD_PEER.with(|cell| cell.replace(Some(peer)));
    let result = method();
    THREAD_PEER.with(|cell| cell.set(previous));
    result
}

impl Peer {
    /// The peer of a connected Unix socket.
    pub(crate) fn of(stream: &tokio::net::UnixStream) -> Self {
        Self::Socket {
            token: platform::audit_token(stream),
        }
    }

    /// Whether the peer is a local program running code signed as `signer`, checked now.
    pub fn is(&self, signer: Signer) -> bool {
        match self {
            Self::Socket { token } => {
                token.is_some_and(|token| platform::satisfies(&token, signer))
            }
            Self::Relay => false,
        }
    }

    /// Whether a method that answers `caller` answers this peer.
    pub fn is_caller(&self, caller: Caller) -> bool {
        match caller {
            Caller::Signed(signer) => self.is(signer),
            Caller::Relay => matches!(self, Self::Relay),
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::os::fd::AsRawFd;
    use std::sync::OnceLock;

    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework::os::macos::code_signing::{
        Flags, GuestAttributes, SecCode, SecRequirement,
    };

    type OSStatus = i32;
    type SecRequirementRef = *mut std::ffi::c_void;

    use super::Signer;

    unsafe extern "C" {
        fn SecCodeCopyDesignatedRequirement(
            code: *const std::ffi::c_void,
            flags: u32,
            requirement: *mut SecRequirementRef,
        ) -> OSStatus;
        fn SecRequirementCopyString(
            requirement: SecRequirementRef,
            flags: u32,
            text: *mut CFStringRef,
        ) -> OSStatus;
    }

    pub(super) fn audit_token(stream: &tokio::net::UnixStream) -> Option<[u8; 32]> {
        let mut token = [0u8; 32];
        let mut length = token.len() as libc::socklen_t;
        // SAFETY: LOCAL_PEERTOKEN writes an audit_token_t (32 bytes) into a buffer of that size.
        let status = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_LOCAL,
                libc::LOCAL_PEERTOKEN,
                token.as_mut_ptr().cast(),
                &mut length,
            )
        };
        (status == 0 && length as usize == token.len()).then_some(token)
    }

    pub(super) fn satisfies(token: &[u8; 32], signer: Signer) -> bool {
        let Some(requirement) = requirement(signer) else {
            return false;
        };
        let Ok(requirement) = requirement.parse::<SecRequirement>() else {
            return false;
        };
        let mut attributes = GuestAttributes::new();
        let token = CFData::from_buffer(token);
        attributes.set_audit_token(token.as_concrete_TypeRef());
        SecCode::copy_guest_with_attribues(None, &attributes, Flags::NONE)
            .and_then(|code| code.check_validity(Flags::NONE, &requirement))
            .is_ok()
    }

    /// This process's designated requirement, as text: who "the same program" is.
    fn own_requirement() -> Option<&'static str> {
        static OWN: OnceLock<Option<String>> = OnceLock::new();
        OWN.get_or_init(|| {
            let code = SecCode::for_self(Flags::NONE).ok()?;
            let mut requirement: SecRequirementRef = std::ptr::null_mut();
            // SAFETY: a SecCode is a SecStaticCode for this call; both out-pointers are owned
            // (Create rule) and wrapped at once.
            unsafe {
                if SecCodeCopyDesignatedRequirement(
                    code.as_concrete_TypeRef().cast(),
                    0,
                    &mut requirement,
                ) != 0
                {
                    return None;
                }
                let requirement = SecRequirement::wrap_under_create_rule(requirement.cast());
                let mut text: CFStringRef = std::ptr::null();
                if SecRequirementCopyString(requirement.as_concrete_TypeRef().cast(), 0, &mut text)
                    != 0
                {
                    return None;
                }
                Some(CFString::wrap_under_create_rule(text).to_string())
            }
        })
        .as_deref()
    }

    fn requirement(signer: Signer) -> Option<String> {
        let own = own_requirement()?;
        match signer {
            Signer::ThisBinary => Some(own.to_owned()),
            // Same certificate, Axo.app's identifier. An ad hoc build's requirement is a cdhash,
            // which names no identifier and so no app.
            Signer::AxoApp => app_requirement(own),
        }
    }

    /// `identifier axod and <certificate>` becomes `identifier "dev.leostera.axo" and <certificate>`.
    pub(super) fn app_requirement(own: &str) -> Option<String> {
        let rest = own.strip_prefix("identifier ")?;
        let (_, certificate) = rest.split_once(" and ")?;
        Some(format!(
            "identifier \"{}\" and {certificate}",
            super::APP_IDENTIFIER
        ))
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::Signer;

    pub(super) fn audit_token(_: &tokio::net::UnixStream) -> Option<[u8; 32]> {
        None
    }

    pub(super) fn satisfies(_: &[u8; 32], _: Signer) -> bool {
        false
    }
}

/// Axo.app's bundle identifier (`config.json` `bundleIds.mac`).
const APP_IDENTIFIER: &str = "dev.leostera.axo";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nobody_outside_a_connection_passes() {
        assert!(!current().is(Signer::ThisBinary));
        assert!(!current().is(Signer::AxoApp));
    }

    #[test]
    fn the_peer_is_seen_on_the_blocking_pool_and_only_there() {
        let token = |peer: Peer| match peer {
            Peer::Socket { token } => token,
            Peer::Relay => panic!("not a socket peer"),
        };
        let peer = Peer::Socket {
            token: Some([7; 32]),
        };
        let seen = on_this_thread(peer, || token(current()));
        assert_eq!(seen, Some([7; 32]));
        assert_eq!(token(current()), None);
    }

    #[test]
    fn the_relay_is_its_own_caller_and_never_a_signed_program() {
        as_relay(|| {
            let peer = current();
            assert!(peer.is_caller(Caller::Relay));
            assert!(!peer.is(Signer::ThisBinary) && !peer.is(Signer::AxoApp));
            assert!(!peer.is_caller(Caller::Signed(Signer::ThisBinary)));
        });
        assert!(!current().is_caller(Caller::Relay), "only inside as_relay");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn axo_app_shares_this_binary_s_certificate() {
        let own = "identifier axod and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: L (W)\"";
        assert_eq!(
            platform::app_requirement(own).as_deref(),
            Some(
                "identifier \"dev.leostera.axo\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: L (W)\""
            )
        );
        assert_eq!(platform::app_requirement("cdhash H\"67f8\""), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_process_is_this_binary_to_itself() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _entered = runtime.enter();
        let (left, right) = tokio::net::UnixStream::pair().unwrap();
        let peer = Peer::of(&left);
        drop(right);
        assert!(matches!(peer, Peer::Socket { token: Some(_) }));
        assert!(!peer.is_caller(Caller::Relay));
        // The test binary connects to itself: the same program, and not Axo.app.
        assert!(peer.is(Signer::ThisBinary));
        assert!(!peer.is(Signer::AxoApp));
    }
}
