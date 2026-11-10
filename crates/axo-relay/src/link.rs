//! Whether this host is linked to an Axo account, and how it becomes linked.
//!
//! The link lives in axod's database (via [`HostLinkStore`]); the secret it refers to lives in
//! the [`HostCredentialStore`]. A host connects to the relay if and only if it is linked.

use std::io;
use std::sync::Arc;

use axo_protocol::HostKind;

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::host::{HostFuture, HostIdentity};
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
    fn load_link(&self) -> HostFuture<'_, io::Result<HostLink>>;
    fn save_link(&self, link: HostLink) -> HostFuture<'_, io::Result<()>>;
}

/// Redeems a pairing code and links this host to the account that created it. Returns the
/// label the host registered with.
///
/// The credential is created and the pending redemption saved before anything is sent, so a
/// crash mid-redemption retries with the same identity. An existing link keeps working until
/// the new one is confirmed, and its credential is deleted only after.
pub async fn link_host(
    endpoint: &RelayEndpoint,
    code: &str,
    identity: &HostIdentity,
    links: &dyn HostLinkStore,
    credentials: Arc<dyn HostCredentialStore>,
) -> io::Result<String> {
    pairing::validate_code(code)?;
    let mut link = links.load_link().await?;
    let pending = match link.pending.clone() {
        Some(pending) => pending,
        None => {
            let keychain = Arc::clone(&credentials);
            let pending = PendingRedemption {
                credential_id: crate::blocking(move || pairing::prepare_credential(&*keychain))
                    .await?,
                host_generation: identity.host_generation.clone(),
            };
            link.pending = Some(pending.clone());
            if let Err(error) = links.save_link(link.clone()).await {
                forget_credential(&credentials, pending.credential_id).await;
                return Err(error);
            }
            pending
        }
    };

    let redemption = Redemption {
        endpoint: endpoint.clone(),
        code: code.to_owned(),
        host_id: identity.host_id.clone(),
        pending: pending.clone(),
    };
    let redeemed = redemption.redeem(Arc::clone(&credentials)).await?;

    let previous = link.account.replace(AccountLink {
        account_id: redeemed.account_id,
        credential_id: pending.credential_id,
    });
    link.pending = None;
    links.save_link(link).await?;
    // A redemption always uses a fresh credential, so the previous one is now unused.
    if let Some(previous) = previous {
        forget_credential(&credentials, previous.credential_id).await;
    }
    Ok(redeemed.label)
}

/// One pairing code's redemption, including the pending identity saved before the request.
struct Redemption {
    endpoint: RelayEndpoint,
    code: String,
    host_id: String,
    pending: PendingRedemption,
}

/// A redeemed code: the account this Mac now belongs to, and the label it registered with.
struct Redeemed {
    account_id: String,
    label: String,
}

impl Redemption {
    async fn redeem(self, credentials: Arc<dyn HostCredentialStore>) -> io::Result<Redeemed> {
        let label = crate::blocking(host_label).await;
        let linked = pairing::redeem(
            pairing::RedemptionRequest {
                endpoint: &self.endpoint,
                code: &self.code,
                host_id: &self.host_id,
                host_generation: &self.pending.host_generation,
                credential_id: &self.pending.credential_id,
                label: &label,
                host_kind: HostKind::MacOS,
            },
            credentials,
        )
        .await?;
        Ok(Redeemed {
            account_id: linked.account_id,
            label,
        })
    }
}

/// Deletes a credential nothing uses; one that cannot be deleted is left behind, unused.
async fn forget_credential(credentials: &Arc<dyn HostCredentialStore>, credential_id: String) {
    let keychain = Arc::clone(credentials);
    let _ = crate::blocking(move || keychain.delete(&credential_id)).await;
}

/// How this host names itself to the account: its Computer Name, or else its hostname. A person
/// may name it otherwise in the account (RFD0022), which reconnecting never undoes.
pub fn host_label() -> String {
    computer_name().unwrap_or_else(network_host_name)
}

/// The name macOS shows for this Mac (System Settings, General, Sharing), as people know it.
fn computer_name() -> Option<String> {
    let output = std::process::Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let name = String::from_utf8(output.stdout).ok()?;
    let name = name.trim();
    (output.status.success() && is_label(name)).then(|| name.to_owned())
}

fn is_label(name: &str) -> bool {
    !name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control)
}

/// The network's name for this Mac, when macOS has no Computer Name.
fn network_host_name() -> String {
    let mut bytes = [0_u8; 256];
    // SAFETY: bytes is writable storage for gethostname's NUL-terminated output.
    if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len()) } == 0 {
        let length = bytes
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(bytes.len());
        if let Ok(name) = std::str::from_utf8(&bytes[..length]) {
            let name = name.trim_end_matches('.').trim();
            if is_label(name) {
                return name.to_owned();
            }
        }
    }
    "This Mac".to_owned()
}

#[cfg(test)]
pub(crate) mod testing {
    use super::{HostLink, HostLinkStore};
    use crate::host::{HostFuture, HostIdentity};
    use std::io;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct MemoryLinkStore(pub Mutex<HostLink>);

    impl HostLinkStore for MemoryLinkStore {
        fn load_link(&self) -> HostFuture<'_, io::Result<HostLink>> {
            Box::pin(std::future::ready(Ok(self.0.lock().unwrap().clone())))
        }

        fn save_link(&self, link: HostLink) -> HostFuture<'_, io::Result<()>> {
            *self.0.lock().unwrap() = link;
            Box::pin(std::future::ready(Ok(())))
        }
    }

    pub const HOST_GENERATION: &str = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";

    pub fn identity() -> HostIdentity {
        HostIdentity {
            host_id: "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe".into(),
            host_generation: HOST_GENERATION.into(),
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

    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_redemption_keeps_the_existing_link_and_retries_with_the_same_identity() {
        let unreachable_relay = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            drop(listener);
            crate::RelayEndpoint::parse(&format!("http://127.0.0.1:{port}")).unwrap()
        };
        let credentials =
            std::sync::Arc::new(crate::credential::testing::MemoryCredentialStore::default());
        crate::credential::HostCredentialStore::store(&*credentials, CREDENTIAL, &[1; 32]).unwrap();
        let links = MemoryLinkStore(std::sync::Mutex::new(linked(ACCOUNT, CREDENTIAL)));
        let identity = super::testing::identity();

        let link = |code: &'static str| {
            super::link_host(
                &unreachable_relay,
                code,
                &identity,
                &links,
                credentials.clone(),
            )
        };
        assert!(link("not-a-code").await.is_err());
        assert_eq!(
            links.load_link().await.unwrap(),
            linked(ACCOUNT, CREDENTIAL),
            "invalid codes change nothing"
        );

        assert!(link("ABCD-1234").await.is_err());
        let after_first = links.load_link().await.unwrap();
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
            crate::credential::HostCredentialStore::load(&*credentials, pending.credential_id())
                .is_ok()
        );

        assert!(link("ABCD-1234").await.is_err());
        assert_eq!(
            links.load_link().await.unwrap().pending(),
            Some(&pending),
            "a retry reuses the same credential"
        );
        assert!(crate::credential::HostCredentialStore::load(&*credentials, CREDENTIAL).is_ok());
    }
}
