//! Whether this host is linked to an Axo account, and how it becomes linked.
//!
//! The link lives in axod's database (via [`HostLinkStore`]); the secret it refers to lives in
//! the [`HostCredentialStore`]. A host connects to the relay if and only if it is linked.

use std::io;

use axo_protocol::HostKind;

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::host::RelayHost;
use crate::pairing::{self, is_uuid};

/// The account this host belongs to, and the credential it connects with.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountLink {
    account_id: String,
    credential_id: String,
}

/// A redemption that was sent but never confirmed. Retrying it reuses the same credential and
/// host generation, so the relay can recognise the retry of a code it already consumed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingRedemption {
    credential_id: String,
    host_generation: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HostLink {
    account: Option<AccountLink>,
    pending: Option<PendingRedemption>,
}

fn malformed() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "stored host link is malformed")
}

impl AccountLink {
    pub fn parse(account_id: String, credential_id: String) -> io::Result<Self> {
        if !is_uuid(&account_id) || !is_uuid(&credential_id) {
            return Err(malformed());
        }
        Ok(Self {
            account_id,
            credential_id,
        })
    }

    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    pub fn credential_id(&self) -> &str {
        &self.credential_id
    }
}

impl PendingRedemption {
    pub fn parse(credential_id: String, host_generation: String) -> io::Result<Self> {
        if !is_uuid(&credential_id) || !is_uuid(&host_generation) {
            return Err(malformed());
        }
        Ok(Self {
            credential_id,
            host_generation,
        })
    }

    pub fn credential_id(&self) -> &str {
        &self.credential_id
    }

    pub fn host_generation(&self) -> &str {
        &self.host_generation
    }
}

impl HostLink {
    /// A redemption always creates a fresh credential, so it never shares the linked one.
    pub fn new(
        account: Option<AccountLink>,
        pending: Option<PendingRedemption>,
    ) -> io::Result<Self> {
        if let (Some(account), Some(pending)) = (&account, &pending)
            && account.credential_id == pending.credential_id
        {
            return Err(malformed());
        }
        Ok(Self { account, pending })
    }

    pub fn account(&self) -> Option<&AccountLink> {
        self.account.as_ref()
    }

    pub fn pending(&self) -> Option<&PendingRedemption> {
        self.pending.as_ref()
    }
}

/// Where axod persists the link. Implemented over axod's database.
pub trait HostLinkStore: Send + Sync {
    fn load_link(&self) -> io::Result<HostLink>;
    fn save_link(&self, link: &HostLink) -> io::Result<()>;
}

/// Redeems a pairing code and links this host to the account that created it. Returns the
/// label the host registered with.
///
/// The credential is created and the pending redemption saved before anything is sent, so a
/// crash mid-redemption retries with the same identity. An existing link keeps working until
/// the new one is confirmed, and its credential is deleted only after.
pub fn link_host(
    endpoint: &RelayEndpoint,
    code: &str,
    host: &dyn RelayHost,
    links: &dyn HostLinkStore,
    credentials: &dyn HostCredentialStore,
) -> io::Result<String> {
    pairing::validate_code(code)?;
    let mut link = links.load_link()?;
    let pending = match link.pending.clone() {
        Some(pending) => pending,
        None => {
            let pending = PendingRedemption {
                credential_id: pairing::prepare_credential(credentials)?,
                host_generation: host.host_generation().to_owned(),
            };
            link.pending = Some(pending.clone());
            if let Err(error) = links.save_link(&link) {
                let _ = credentials.delete(&pending.credential_id);
                return Err(error);
            }
            pending
        }
    };

    let label = host_label();
    let linked = pairing::redeem(
        pairing::RedemptionRequest {
            endpoint,
            code,
            host_id: host.host_id(),
            host_generation: &pending.host_generation,
            credential_id: &pending.credential_id,
            label: &label,
            host_kind: HostKind::MacOS,
        },
        credentials,
    )?;

    let previous = link.account.replace(AccountLink {
        account_id: linked.account_id,
        credential_id: pending.credential_id,
    });
    link.pending = None;
    links.save_link(&link)?;
    // A redemption always uses a fresh credential, so the previous one is now unused.
    if let Some(previous) = previous {
        let _ = credentials.delete(&previous.credential_id);
    }
    Ok(label)
}

/// How this host names itself to the account: its hostname.
pub fn host_label() -> String {
    let mut bytes = [0_u8; 256];
    // SAFETY: bytes is writable storage for gethostname's NUL-terminated output.
    if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len()) } == 0 {
        let length = bytes
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(bytes.len());
        if let Ok(name) = std::str::from_utf8(&bytes[..length]) {
            let name = name.trim_end_matches('.').trim();
            if !name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control) {
                return name.to_owned();
            }
        }
    }
    "This Mac".to_owned()
}

#[cfg(test)]
pub(crate) mod testing {
    use super::{HostLink, HostLinkStore};
    use std::io;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct MemoryLinkStore(pub Mutex<HostLink>);

    impl HostLinkStore for MemoryLinkStore {
        fn load_link(&self) -> io::Result<HostLink> {
            Ok(self.0.lock().unwrap().clone())
        }

        fn save_link(&self, link: &HostLink) -> io::Result<()> {
            *self.0.lock().unwrap() = link.clone();
            Ok(())
        }
    }

    pub const HOST_GENERATION: &str = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";

    /// Just enough of a host for code that reads only its identity; any other call is a bug.
    pub struct IdentityOnlyHost;

    impl crate::RelayHost for IdentityOnlyHost {
        fn host_id(&self) -> &str {
            "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe"
        }
        fn host_generation(&self) -> &str {
            HOST_GENERATION
        }
        fn publish_relay_status(&self, _: &axo_protocol::RelayStatus) {}
        fn remote_session_snapshots(
            &self,
            _: &str,
        ) -> std::io::Result<Vec<axo_protocol::RemoteSessionSnapshot>> {
            unreachable!()
        }
        fn subscribe_remote_events(&self) -> std::io::Result<String> {
            unreachable!()
        }
        fn next_remote_event(
            &self,
            _: &str,
            _: std::time::Duration,
        ) -> std::io::Result<Option<axo_protocol::Event>> {
            unreachable!()
        }
        fn remote_resync_events(&self) -> std::io::Result<Vec<axo_protocol::Event>> {
            unreachable!()
        }
        fn unsubscribe_remote_events(&self, _: &str) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_create_session(
            &self,
            _: &str,
        ) -> std::io::Result<axo_protocol::RemoteSessionSnapshot> {
            unreachable!()
        }
        fn remote_create_workspace_session(
            &self,
            _: &str,
            _: &str,
        ) -> std::io::Result<axo_protocol::RemoteSessionSnapshot> {
            unreachable!()
        }
        fn remote_close_session(
            &self,
            _: axo_protocol::SessionId,
            _: &str,
        ) -> std::io::Result<Option<axo_protocol::RemoteSessionSnapshot>> {
            unreachable!()
        }
        fn remote_workspaces(&self) -> std::io::Result<Vec<axo_protocol::RemoteWorkspace>> {
            unreachable!()
        }
        fn remote_rename_session(
            &self,
            _: axo_protocol::SessionId,
            _: &str,
        ) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_create_shell(
            &self,
            _: axo_protocol::SessionId,
        ) -> std::io::Result<axo_protocol::ShellId> {
            unreachable!()
        }
        fn remote_close_shell(
            &self,
            _: axo_protocol::SessionId,
            _: axo_protocol::ShellId,
        ) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_set_layout(
            &self,
            _: axo_protocol::SessionId,
            _: axo_protocol::LayoutNode,
        ) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_terminal_input(
            &self,
            _: axo_protocol::SessionId,
            _: axo_protocol::ShellId,
            _: u64,
            _: &str,
        ) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_prompt_pi(&self, _: axo_protocol::SessionId, _: &str) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_press_pi_key(
            &self,
            _: axo_protocol::SessionId,
            _: crate::PiKey,
        ) -> std::io::Result<()> {
            unreachable!()
        }
        fn remote_terminal_resize(
            &self,
            _: axo_protocol::SessionId,
            _: axo_protocol::ShellId,
            _: u32,
            _: u32,
        ) -> std::io::Result<()> {
            unreachable!()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::MemoryLinkStore;
    use super::{AccountLink, HostLink, HostLinkStore, PendingRedemption};

    const ACCOUNT: &str = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
    const CREDENTIAL: &str = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
    const GENERATION: &str = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";

    fn linked(account: &str, credential: &str) -> HostLink {
        HostLink::new(
            Some(AccountLink::parse(account.into(), credential.into()).unwrap()),
            None,
        )
        .unwrap()
    }

    fn pending(credential: &str, generation: &str) -> HostLink {
        HostLink::new(
            None,
            Some(PendingRedemption::parse(credential.into(), generation.into()).unwrap()),
        )
        .unwrap()
    }

    #[test]
    fn stored_links_are_parsed_strictly() {
        assert_eq!(
            linked(ACCOUNT, CREDENTIAL).account().unwrap().account_id(),
            ACCOUNT
        );
        assert_eq!(
            pending(CREDENTIAL, GENERATION)
                .pending()
                .unwrap()
                .host_generation(),
            GENERATION
        );
        assert!(AccountLink::parse("not-a-uuid".into(), CREDENTIAL.into()).is_err());
        assert!(PendingRedemption::parse(CREDENTIAL.into(), "not-a-uuid".into()).is_err());
        // A redemption always uses a fresh credential.
        assert!(
            HostLink::new(
                linked(ACCOUNT, CREDENTIAL).account().cloned(),
                pending(CREDENTIAL, GENERATION).pending().cloned(),
            )
            .is_err()
        );
    }

    #[test]
    fn a_failed_redemption_keeps_the_existing_link_and_retries_with_the_same_identity() {
        let unreachable_relay = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            drop(listener);
            crate::RelayEndpoint::parse(&format!("http://127.0.0.1:{port}")).unwrap()
        };
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        crate::credential::HostCredentialStore::store(&credentials, CREDENTIAL, &[1; 32]).unwrap();
        let links = MemoryLinkStore(std::sync::Mutex::new(linked(ACCOUNT, CREDENTIAL)));

        let link = |code: &str| {
            super::link_host(
                &unreachable_relay,
                code,
                &super::testing::IdentityOnlyHost,
                &links,
                &credentials,
            )
        };
        assert!(link("not-a-code").is_err());
        assert_eq!(
            links.load_link().unwrap(),
            linked(ACCOUNT, CREDENTIAL),
            "invalid codes change nothing"
        );

        assert!(link("ABCD-1234").is_err());
        let after_first = links.load_link().unwrap();
        assert_eq!(
            after_first.account(),
            linked(ACCOUNT, CREDENTIAL).account(),
            "the current link keeps working"
        );
        let pending = after_first
            .pending()
            .expect("the attempt is remembered")
            .clone();
        assert_eq!(pending.host_generation(), GENERATION);
        assert!(
            crate::credential::HostCredentialStore::load(&credentials, pending.credential_id())
                .is_ok()
        );

        assert!(link("ABCD-1234").is_err());
        assert_eq!(
            links.load_link().unwrap().pending(),
            Some(&pending),
            "a retry reuses the same credential"
        );
        assert!(crate::credential::HostCredentialStore::load(&credentials, CREDENTIAL).is_ok());
    }
}
