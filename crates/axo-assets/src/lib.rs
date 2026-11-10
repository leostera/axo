//! The assets extension: `axo.assets.fetch` on `axod.sock` (RFD0030), for axod's own
//! `axod mcp`, which shows the agent the images a script returned.
//!
//! Assets live in the account; this Mac reaches them with its credential while the relay is
//! connected. The relay fills an [`AssetSlot`] when it connects and empties it when it drops;
//! the extension reads it per call, so a fetch while offline fails at once instead of waiting.

use std::sync::{Arc, Mutex};

use axo_ipc::peer::{Caller, Signer};
use axo_ipc::{ErrorCode, Extension, Only, RpcError, TypedMethods};
use axo_protocol::asset::{Attachments, FetchedAttachment};
use axo_protocol::rpc::method::ASSETS_FETCH;
use axo_relay::assets::{AssetSource, FetchError};
use jsonrpc_core::IoHandler;
use serde::{Deserialize, Serialize};

/// Not connected to the account, so no asset can be fetched.
pub const NOT_CONNECTED: i64 = -32003;
/// An asset could not be fetched, or was not what its name says.
pub const FETCH_FAILED: i64 = -32010;

/// The account's assets, reachable while the relay is connected.
#[derive(Default)]
pub struct AssetSlot(Mutex<Option<AssetSource>>);

impl AssetSlot {
    pub fn set(&self, source: Option<AssetSource>) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = source;
        }
    }

    pub fn get(&self) -> Option<AssetSource> {
        self.0.lock().ok().and_then(|slot| slot.clone())
    }
}

/// `axo.assets.fetch`, answered only to axod's own binary.
pub struct Assets {
    slot: Arc<AssetSlot>,
}

impl Assets {
    pub fn new(slot: Arc<AssetSlot>) -> Self {
        Self { slot }
    }
}

impl Extension for Assets {
    fn name(&self) -> &'static str {
        "assets"
    }

    fn register(&self, methods: &mut IoHandler) {
        let slot = Arc::clone(&self.slot);
        methods.add_typed_only_async(
            Only {
                caller: Caller::Signed(Signer::ThisBinary),
                code: -32003,
                message: "only axod's own tools fetch assets here",
            },
            ASSETS_FETCH,
            "expected {attachments}",
            move |request: FetchAssets| {
                let slot = Arc::clone(&slot);
                async move { fetch_files(&slot, &request).await }
            },
        );
    }
}

/// `axo.assets.fetch`'s answer: where each attachment now is.
async fn fetch_files(slot: &AssetSlot, request: &FetchAssets) -> Result<Fetched, RpcError> {
    let fetched = fetch(slot, &request.attachments).await?;
    Ok(Fetched {
        files: fetched.into_iter().map(FetchedFile::from).collect(),
    })
}

/// Fetches attachments into `~/.axo/assets`, as a prompt's are, with this Mac's credential.
async fn fetch(
    slot: &AssetSlot,
    attachments: &Attachments,
) -> Result<Vec<FetchedAttachment>, RpcError> {
    let source = slot.get().ok_or_else(|| RpcError {
        code: ErrorCode::ServerError(NOT_CONNECTED),
        message: "this Mac is not connected to its account".into(),
        data: None,
    })?;
    axo_relay::assets::fetch_all(&source, attachments)
        .await
        .map_err(|error| RpcError {
            code: ErrorCode::ServerError(FETCH_FAILED),
            message: match error {
                FetchError::NotFound => "an asset is no longer in the account".into(),
                FetchError::Mismatch => "an asset did not match its name".into(),
                FetchError::Failed(error) => format!("an asset could not be fetched: {error}"),
            },
            data: None,
        })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FetchAssets {
    attachments: Attachments,
}

#[derive(Serialize)]
struct Fetched {
    files: Vec<FetchedFile>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FetchedFile {
    path: String,
    asset: String,
    name: String,
    mime_type: String,
    size: u64,
}

impl From<FetchedAttachment> for FetchedFile {
    fn from(file: FetchedAttachment) -> Self {
        Self {
            path: file.path.to_string_lossy().into_owned(),
            asset: file.asset.to_string(),
            name: file.name.as_str().to_owned(),
            mime_type: file.mime_type.as_str().to_owned(),
            size: file.size,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_axods_own_binary_fetches_and_an_empty_slot_is_not_connected() {
        let mut handler = IoHandler::new();
        Assets::new(Arc::default()).register(&mut handler);
        // Outside a connection nobody is axod's binary: refused before anything else.
        let reply = handler
            .handle_request_sync(&format!(
                r#"{{"jsonrpc":"2.0","id":1,"method":"{ASSETS_FETCH}","params":{{"attachments":[]}}}}"#
            ))
            .unwrap();
        assert!(
            reply.contains("only axod's own tools fetch assets here"),
            "{reply}"
        );
        // The slot itself: empty until the relay fills it.
        let slot = AssetSlot::default();
        assert!(slot.get().is_none());
        let refused = fetch(&slot, &Attachments::default()).await.unwrap_err();
        assert_eq!(refused.code, ErrorCode::ServerError(NOT_CONNECTED));
    }

    // A stand-in for the account: answers each request with the next canned response.
    struct Store;
    impl axo_relay::credential::HostCredentialStore for Store {
        fn store(&self, _: &str, _: &[u8]) -> std::io::Result<()> {
            Ok(())
        }
        fn load(&self, _: &str) -> std::io::Result<Vec<u8>> {
            Ok(vec![7; 32])
        }
        fn delete(&self, _: &str) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn account(responses: Vec<Vec<u8>>) -> String {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buffer = [0_u8; 4096];
                while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                    let read = stream.read(&mut buffer).unwrap();
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..read]);
                }
                let _ = stream.write_all(&response);
            }
        });
        origin
    }

    fn answer(status: &str, body: &[u8]) -> Vec<u8> {
        let mut response = format!(
            "HTTP/1.1 {status}\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(body);
        response
    }

    /// A slot filled as the relay fills it, pointing at `origin`, keeping files in a directory of
    /// its own.
    fn connected(origin: &str) -> (AssetSlot, std::path::PathBuf) {
        let directory = std::env::temp_dir().join(format!(
            "axo-assets-ext-{}",
            axo_protocol::new_uuid_v4().unwrap()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let slot = AssetSlot::default();
        slot.set(Some(AssetSource {
            endpoint: axo_relay::RelayEndpoint::parse(origin).unwrap(),
            account: axo_relay::AccountLink::parse(
                "b6b4cc11-b541-40ca-8aa5-b84276fa9939".to_owned(),
                "0d6b0f0a-5f4e-4b1c-9a0e-1f2e3d4c5b6a".to_owned(),
            )
            .unwrap(),
            host_id: "18355f00-95fd-4c93-8586-a71a8a52bf73".to_owned(),
            credentials: Arc::new(Store),
            directory: directory.clone(),
        }));
        (slot, directory)
    }

    fn request(bytes: &[u8], name: &str) -> FetchAssets {
        use sha2::Digest;
        let digest: [u8; 32] = sha2::Sha256::digest(bytes).into();
        serde_json::from_value(serde_json::json!({ "attachments": [{
            "asset": axo_protocol::asset::AssetHash::from_digest(digest).to_string(),
            "name": name,
            "mimeType": "image/png",
            "size": bytes.len(),
        }] }))
        .unwrap()
    }

    #[tokio::test]
    async fn a_fetched_asset_is_answered_with_where_it_now_is() {
        let bytes = b"a screenshot of the build".as_slice();
        let (slot, directory) = connected(&account(vec![answer("200 OK", bytes)]));
        let fetched = fetch_files(&slot, &request(bytes, "build.png"))
            .await
            .unwrap();
        let file = &fetched.files[0];
        assert_eq!(std::fs::read(&file.path).unwrap(), bytes);
        assert!(file.path.ends_with("/build.png"), "{}", file.path);
        assert!(file.asset.starts_with("sha256:"));
        assert_eq!(
            (file.name.as_str(), file.mime_type.as_str(), file.size),
            ("build.png", "image/png", bytes.len() as u64)
        );
        let _ = std::fs::remove_dir_all(directory);
    }

    #[tokio::test]
    async fn an_asset_that_is_gone_or_not_what_its_name_says_is_refused_plainly() {
        let (slot, directory) = connected(&account(vec![
            answer("404 Not Found", b""),
            answer("200 OK", b"BBBBBBBBBB"),
            answer("500 Internal Server Error", b""),
        ]));
        let refused = |bytes: &'static [u8]| {
            let slot = &slot;
            async move {
                fetch_files(slot, &request(bytes, "a.png"))
                    .await
                    .err()
                    .unwrap()
            }
        };
        let gone = refused(b"gone").await;
        assert_eq!(gone.code, ErrorCode::ServerError(FETCH_FAILED));
        assert_eq!(gone.message, "an asset is no longer in the account");
        // Same length, so only the hash tells.
        let other = refused(b"AAAAAAAAAA").await;
        assert_eq!(other.message, "an asset did not match its name");
        let failed = refused(b"broken").await;
        assert!(
            failed.message.starts_with("an asset could not be fetched:"),
            "{}",
            failed.message
        );
        let _ = std::fs::remove_dir_all(directory);
    }
}
