//! Credentials this host no longer uses: each is revoked at the account it belongs to, with
//! itself as the proof, and only then deleted from the Keychain (RFD0074). Until both have
//! happened it stays in the link's `retired` list, so a relay that doesn't answer, or a Keychain
//! that refuses, only delays it.
//!
//! The Worker checks the credential and revokes the host in two steps, so a redemption for the
//! same account between them would lose its new link. Every redemption comes from this axod, so
//! callers serialize retiring against linking (axod's `link_operations`).

use std::io;
use std::sync::Arc;

use tokio::io::BufReader;

use crate::assets::{READ_TIMEOUT, read_head, request};
use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::link::{AccountLink, HostLinkStore};

/// Retires every credential in the link's `retired` list that it can, and answers how many are
/// left. Fails, after trying them all, if the Keychain kept a secret it was asked to delete;
/// that one stays on the list.
pub async fn retire_credentials(
    endpoint: &RelayEndpoint,
    host_id: &str,
    links: &dyn HostLinkStore,
    credentials: &Arc<dyn HostCredentialStore>,
) -> io::Result<usize> {
    let retired = links.load_link().await?.retired().to_vec();
    let mut left = 0;
    let mut kept = None;
    for credential in retired {
        match retire(endpoint, host_id, &credential, credentials).await {
            Ok(outcome) => {
                log::info!(
                    "event=relay.credential_retired credential_id={} outcome={outcome}",
                    credential.credential_id()
                );
                let link = links.load_link().await?;
                links
                    .save_link(link.forget_retired(credential.credential_id()))
                    .await?;
            }
            Err(Unretired::Unrevoked(error)) => {
                log::warn!(
                    "event=relay.credential_unrevoked credential_id={} reason={error}",
                    credential.credential_id()
                );
                left += 1;
            }
            Err(Unretired::KeychainKept(error)) => {
                log::error!(
                    "event=relay.credential_keychain_kept credential_id={} reason={error}",
                    credential.credential_id()
                );
                left += 1;
                kept = Some(error);
            }
        }
    }
    kept.map_or(Ok(left), Err)
}

enum Unretired {
    /// Not revoked yet: the relay or the Keychain did not answer. The secret is kept to try again.
    Unrevoked(io::Error),
    /// Revoked, but the Keychain would not delete the secret.
    KeychainKept(io::Error),
}

async fn retire(
    endpoint: &RelayEndpoint,
    host_id: &str,
    credential: &AccountLink,
    credentials: &Arc<dyn HostCredentialStore>,
) -> Result<&'static str, Unretired> {
    let keychain = Arc::clone(credentials);
    let id = credential.credential_id().to_owned();
    let mut secret = match crate::blocking(move || keychain.load(&id)).await {
        Ok(secret) => secret,
        // Nothing holds it, so nothing can use it, or prove it to revoke it.
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok("gone"),
        Err(error) => return Err(Unretired::Unrevoked(error)),
    };
    let token = crate::pairing::encode_base64url(&secret);
    secret.fill(0);
    let outcome = match revoke(endpoint, host_id, credential, &token).await {
        Ok(200 | 204) => "revoked",
        // No longer the host's credential: replaced by a later link, or revoked already.
        Ok(401) => "replaced",
        Ok(status) => {
            return Err(Unretired::Unrevoked(io::Error::other(format!(
                "the revocation answered HTTP {status}"
            ))));
        }
        Err(error) => return Err(Unretired::Unrevoked(error)),
    };
    let keychain = Arc::clone(credentials);
    let id = credential.credential_id().to_owned();
    crate::blocking(move || keychain.delete(&id))
        .await
        .map_err(Unretired::KeychainKept)?;
    Ok(outcome)
}

/// `POST …/credential/revoke` with the credential itself; answers the status.
async fn revoke(
    endpoint: &RelayEndpoint,
    host_id: &str,
    credential: &AccountLink,
    token: &str,
) -> io::Result<u16> {
    let url = endpoint.credential_revocation_url(credential.account_id(), host_id);
    let headers = format!(
        "Authorization: Bearer {token}\r\nX-Axo-Credential-Id: {}\r\nContent-Length: 0\r\n",
        credential.credential_id()
    );
    let stream = request(&url, "POST", &headers, &[], READ_TIMEOUT).await?;
    Ok(read_head(&mut BufReader::new(stream), READ_TIMEOUT)
        .await?
        .status)
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader as StdBufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::credential::testing::MemoryCredentialStore;
    use crate::link::HostLink;
    use crate::link::testing::MemoryLinkStore;

    const ACCOUNT: &str = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
    const OTHER_ACCOUNT: &str = "3f0e6a52-6b0d-4a4f-9d0b-4c8f6f1e2a77";
    const CREDENTIAL: &str = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
    const HOST: &str = "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe";

    /// A relay answering each request with the next status, recording the request line and
    /// headers, and what the Keychain held when it came.
    fn relay(
        statuses: Vec<u16>,
        keychain: Arc<dyn HostCredentialStore>,
    ) -> (RelayEndpoint, Arc<Mutex<Vec<(String, bool)>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&seen);
        std::thread::spawn(move || {
            for status in statuses {
                let Ok((stream, _)) = listener.accept() else {
                    return;
                };
                let mut reader = StdBufReader::new(stream.try_clone().unwrap());
                let mut head = String::new();
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                    head.push_str(&line);
                }
                let still_held = keychain.load(CREDENTIAL).is_ok();
                recorded.lock().unwrap().push((head, still_held));
                let _ = write!(
                    &stream,
                    "HTTP/1.1 {status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
            }
        });
        (
            RelayEndpoint::parse(&format!("http://127.0.0.1:{port}")).unwrap(),
            seen,
        )
    }

    fn unreachable() -> RelayEndpoint {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        RelayEndpoint::parse(&format!("http://127.0.0.1:{port}")).unwrap()
    }

    fn account(account: &str, credential: &str) -> AccountLink {
        AccountLink::parse(account.into(), credential.into()).unwrap()
    }

    fn keychain() -> Arc<dyn HostCredentialStore> {
        let keychain = Arc::new(MemoryCredentialStore::default());
        keychain.store(CREDENTIAL, &[7; 32]).unwrap();
        keychain
    }

    fn retiring(credential: AccountLink) -> MemoryLinkStore {
        MemoryLinkStore(Mutex::new(
            HostLink::default().with_retired(vec![credential]),
        ))
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn unlinking_revokes_the_credential_at_its_account_before_deleting_it() {
        let credentials = keychain();
        let (endpoint, seen) = relay(vec![204], Arc::clone(&credentials));
        let links = MemoryLinkStore(Mutex::new(
            HostLink::new(Some(account(ACCOUNT, CREDENTIAL)), None).unwrap(),
        ));
        crate::unlink_host(&endpoint, HOST, &links, &credentials, || {})
            .await
            .unwrap();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1);
        let (head, still_held) = &seen[0];
        assert!(
            head.starts_with(&format!(
                "POST /api/v1/accounts/{ACCOUNT}/hosts/{HOST}/credential/revoke "
            )),
            "{head}"
        );
        assert!(head.contains(&format!(
            "Authorization: Bearer {}\r\n",
            crate::pairing::encode_base64url(&[7; 32])
        )));
        assert!(head.contains(&format!("X-Axo-Credential-Id: {CREDENTIAL}\r\n")));
        assert!(
            still_held,
            "the secret proves the revocation, so it goes after"
        );
        assert!(credentials.load(CREDENTIAL).is_err());
        assert_eq!(links.load_link().await.unwrap(), HostLink::default());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn linking_to_another_account_revokes_the_old_one() {
        // `link_host` moves the previous credential to `retired` in the write that saves the
        // new link; this is what is left to do then.
        let credentials = keychain();
        let (endpoint, seen) = relay(vec![204], Arc::clone(&credentials));
        let links = MemoryLinkStore(Mutex::new(
            HostLink::new(
                Some(account(
                    OTHER_ACCOUNT,
                    "6a2c3e4f-1111-4222-8333-944455556666",
                )),
                None,
            )
            .unwrap()
            .with_retired(vec![account(ACCOUNT, CREDENTIAL)]),
        ));
        assert_eq!(
            retire_credentials(&endpoint, HOST, &links, &credentials)
                .await
                .unwrap(),
            0
        );
        assert!(
            seen.lock().unwrap()[0]
                .0
                .contains(&format!("/accounts/{ACCOUNT}/"))
        );
        let link = links.load_link().await.unwrap();
        assert!(link.retired().is_empty());
        assert_eq!(link.account().unwrap().account_id(), OTHER_ACCOUNT);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_credential_the_account_no_longer_takes_is_done() {
        let credentials = keychain();
        let (endpoint, _) = relay(vec![401], Arc::clone(&credentials));
        let links = retiring(account(ACCOUNT, CREDENTIAL));
        assert_eq!(
            retire_credentials(&endpoint, HOST, &links, &credentials)
                .await
                .unwrap(),
            0
        );
        assert!(credentials.load(CREDENTIAL).is_err());
        assert!(links.load_link().await.unwrap().retired().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_relay_that_does_not_revoke_keeps_the_credential_to_try_again() {
        for endpoint in [unreachable(), relay(vec![503], keychain()).0] {
            let credentials = keychain();
            let links = retiring(account(ACCOUNT, CREDENTIAL));
            assert_eq!(
                retire_credentials(&endpoint, HOST, &links, &credentials)
                    .await
                    .unwrap(),
                1
            );
            assert!(credentials.load(CREDENTIAL).is_ok());
            assert_eq!(links.load_link().await.unwrap().retired().len(), 1);
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_keychain_that_keeps_the_secret_fails_loudly_and_is_retried() {
        struct Refusing(Arc<dyn HostCredentialStore>);
        impl HostCredentialStore for Refusing {
            fn store(&self, id: &str, secret: &[u8]) -> io::Result<()> {
                self.0.store(id, secret)
            }
            fn load(&self, id: &str) -> io::Result<Vec<u8>> {
                self.0.load(id)
            }
            fn delete(&self, _: &str) -> io::Result<()> {
                Err(io::Error::other("the Keychain is locked"))
            }
        }
        let credentials: Arc<dyn HostCredentialStore> = Arc::new(Refusing(keychain()));
        let (endpoint, _) = relay(vec![204], Arc::clone(&credentials));
        let links = MemoryLinkStore(Mutex::new(
            HostLink::new(Some(account(ACCOUNT, CREDENTIAL)), None).unwrap(),
        ));
        let unlinked = crate::unlink_host(&endpoint, HOST, &links, &credentials, || {}).await;
        assert!(
            matches!(unlinked, Err(crate::UnlinkError::KeychainKept(_))),
            "{unlinked:?}"
        );
        let link = links.load_link().await.unwrap();
        assert!(link.account().is_none(), "the unlink itself stands");
        assert_eq!(link.retired(), &[account(ACCOUNT, CREDENTIAL)]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_secret_the_keychain_no_longer_has_is_forgotten() {
        let credentials: Arc<dyn HostCredentialStore> = Arc::new(MemoryCredentialStore::default());
        let links = retiring(account(ACCOUNT, CREDENTIAL));
        assert_eq!(
            retire_credentials(&unreachable(), HOST, &links, &credentials)
                .await
                .unwrap(),
            0
        );
        assert!(links.load_link().await.unwrap().retired().is_empty());
    }
}
