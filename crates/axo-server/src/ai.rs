//! Host-side AI boundary: parse first, fetch account-scoped image assets, then run locally.
use std::collections::BTreeMap;
use std::io::Read;
use std::time::{Duration, Instant};

use axo_protocol::asset::Attachments;
use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::{BUSY, INVALID_PARAMS, REFUSED};
use axod_infer::api::Image;
use axod_infer::service::{Error, Request};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::core::Core;

pub(crate) async fn execute(
    core: &Core,
    request: axo_relay::ai::AiParams,
) -> Result<Value, MethodError> {
    let mut operation = Request::parse(request.request).map_err(error)?;
    let started = Instant::now();
    if let Some(input) = operation.input_mut() {
        let attachments = Attachments::parse(
            input
                .images()
                .iter()
                .filter_map(|image| match image {
                    Image::Asset(asset) => Some(asset.clone()),
                    _ => None,
                })
                .collect(),
        )
        .map_err(MethodError::invalid_params)?;
        if !attachments.is_empty() {
            let source = core.assets.get().ok_or_else(|| {
                error(Error::unavailable(
                    "this Mac is not connected to its account's image assets",
                ))
            })?;
            if source.account.account_id() != request.account_id {
                return Err(error(Error::unavailable(
                    "this Mac changed accounts while preparing image assets; retry from its current account",
                )));
            }
            let fetched = tokio::time::timeout(
                Duration::from_millis(request.timeout_ms),
                axo_relay::assets::fetch_all(&source, &attachments),
            )
            .await
            .map_err(|_| error(Error::failed("image asset fetch timed out")))?
            .map_err(|_| {
                error(Error::failed(
                    "could not fetch or verify an account image asset",
                ))
            })?;
            let urls = tokio::task::spawn_blocking(move || {
                let mut urls = BTreeMap::new();
                for asset in fetched {
                    let mut bytes = Vec::new();
                    std::fs::File::open(&asset.path)
                        .map_err(|_| Error::failed("could not open verified image asset"))?
                        .take(asset.size + 1)
                        .read_to_end(&mut bytes)
                        .map_err(|_| Error::failed("could not read verified image asset"))?;
                    if bytes.len() as u64 != asset.size
                        || axo_protocol::asset::AssetHash::from_digest(
                            Sha256::digest(&bytes).into(),
                        ) != asset.asset
                    {
                        return Err(Error::failed("verified image asset changed size or hash"));
                    }
                    urls.insert(
                        asset.asset.to_string(),
                        format!(
                            "data:{};base64,{}",
                            asset.mime_type.as_str(),
                            axo_protocol::base64::encode(&bytes)
                        ),
                    );
                }
                Ok::<_, Error>(urls)
            })
            .await
            .map_err(|_| error(Error::failed("image preparation failed")))?
            .map_err(error)?;
            input.replace_assets(&urls).map_err(error)?;
        }
    }
    let remaining = request
        .timeout_ms
        .saturating_sub(started.elapsed().as_millis().min(u64::MAX as u128) as u64);
    if remaining == 0 {
        return Err(error(Error::failed(
            "AI deadline expired preparing image inputs",
        )));
    }
    core.ai.execute(operation, remaining).await.map_err(error)
}
fn error(error: Error) -> MethodError {
    let code = match &error {
        Error::Invalid(_) => INVALID_PARAMS,
        Error::Busy => BUSY,
        _ => REFUSED,
    };
    MethodError::new(code, error.to_string())
}
