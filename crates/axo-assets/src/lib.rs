//! The assets extension: `axo.assets.fetch` on `axod.sock` (RFD0030), for axod's own
//! `axod mcp`, which shows the agent the images a script returned.
//!
//! Assets live in the account; this Mac reaches them with its credential while the relay is
//! connected. The relay fills an [`AssetSlot`] when it connects and empties it when it drops;
//! the extension reads it per call, so a fetch while offline fails at once instead of waiting.

use std::sync::{Arc, Mutex};

use axo_ipc::peer::Signer;
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
        methods.add_typed_only(
            Only {
                signer: Signer::ThisBinary,
                code: -32003,
                message: "only axod's own tools fetch assets here",
            },
            ASSETS_FETCH,
            "expected {attachments}",
            move |request: FetchAssets| {
                let fetched = fetch(&slot, &request.attachments)?;
                Ok(Fetched {
                    files: fetched.into_iter().map(FetchedFile::from).collect(),
                })
            },
        );
    }
}

/// Fetches attachments into `~/.axo/assets`, as a prompt's are, with this Mac's credential.
fn fetch(slot: &AssetSlot, attachments: &Attachments) -> Result<Vec<FetchedAttachment>, RpcError> {
    let source = slot.get().ok_or_else(|| RpcError {
        code: ErrorCode::ServerError(NOT_CONNECTED),
        message: "this Mac is not connected to its account".into(),
        data: None,
    })?;
    axo_relay::assets::fetch_all(&source, attachments).map_err(|error| RpcError {
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

    #[test]
    fn only_axods_own_binary_fetches_and_an_empty_slot_is_not_connected() {
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
        let refused = fetch(&slot, &Attachments::default()).unwrap_err();
        assert_eq!(refused.code, ErrorCode::ServerError(NOT_CONNECTED));
    }
}
