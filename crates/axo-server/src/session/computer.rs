//! Computer use on this Mac from another Mac's script, and fetching the account's assets for
//! `axod mcp` (RFD0028, Computer use from anywhere).
//!
//! A call runs the same gate as the local `computer` tool. When it must ask, this Mac asks in the
//! *calling* Session (`ask`): its card shows in that chat on the web and the phone, and the answer
//! comes back to this Mac. The tool runs only on the person's Accept or the gate passing it.

use std::sync::Mutex;
use std::time::Duration;

use axo_ipc::peer::Signer;
use axo_ipc::{Only, TypedMethods};
use axo_protocol::asset::{Attachments, FetchedAttachment};
use axo_protocol::elicitation::{Asker, ElicitationAction, MAX_MESSAGE_CHARS, TIMEOUT_MS};
use axo_relay::assets::{AssetSource, FetchError};
use axo_relay::computer::ComputerParams;
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

use super::SessionManager;

/// Why a computer call did not run; the script's call fails with it.
pub const NOT_ALLOWED: i64 = -32031;
/// Kept back from the call's time, so the question ends before the account stops waiting.
const ANSWER_MARGIN: Duration = Duration::from_secs(10);
/// The shortest question worth asking.
const SHORTEST_QUESTION: Duration = Duration::from_secs(15);

use axo_protocol::rpc::method::ASSETS_FETCH;

/// The account's assets, reachable while the relay is connected.
#[derive(Default)]
pub(crate) struct AssetSlot(Mutex<Option<AssetSource>>);

impl AssetSlot {
    pub(crate) fn set(&self, source: Option<AssetSource>) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = source;
        }
    }

    fn get(&self) -> Option<AssetSource> {
        self.0.lock().ok().and_then(|slot| slot.clone())
    }
}

impl SessionManager {
    /// One computer-use tool for another Mac's script. `Err` fails the script's call.
    pub(crate) fn remote_computer(&self, request: &ComputerParams) -> Result<Value, (i64, String)> {
        if !axo_computer::AVAILABLE {
            return Err((-32601, "this Mac has no computer use".into()));
        }
        if request.tool == axo_computer::REQUEST_INPUT {
            let timeout = Duration::from_millis(request.timeout_ms).saturating_sub(ANSWER_MARGIN);
            if timeout < SHORTEST_QUESTION {
                return Err((
                    NOT_ALLOWED,
                    "Not done: no time left to ask the person.".into(),
                ));
            }
            return Ok(self.request_input(
                request.session_id,
                Some(&request.from),
                request.args.clone(),
                timeout,
            ));
        }
        let socket = super::spawn::agent_socket()
            .ok_or_else(|| (-32603, "axod has no socket yet".to_owned()))?;
        let gate = axo_computer::gate::for_socket(socket);
        if let axo_computer::gate::Verdict::Ask(question) =
            gate.check(&request.tool, &request.args, request.confirm)
        {
            self.ask_for_computer(request, &question)?;
        }
        let mut result = axo_computer::call(&request.tool, request.args.clone());
        gate.remember(&request.tool, &result);
        self.redact(&mut result);
        log::info!(
            "event=computer.remote_called tool={} outcome={}",
            request.tool,
            if result["isError"] == json!(true) {
                "error"
            } else {
                "ok"
            }
        );
        Ok(result)
    }

    /// Asks the person in the calling Session; `Ok` only on Accept.
    fn ask_for_computer(
        &self,
        request: &ComputerParams,
        question: &str,
    ) -> Result<(), (i64, String)> {
        let available = Duration::from_millis(request.timeout_ms).saturating_sub(ANSWER_MARGIN);
        let timeout = available.min(Duration::from_millis(TIMEOUT_MS));
        if timeout < SHORTEST_QUESTION {
            return Err((
                NOT_ALLOWED,
                "Not done: no time left to ask the person.".into(),
            ));
        }
        let from = format!("\nAsked from {}'s Session.", request.from);
        let room = MAX_MESSAGE_CHARS.saturating_sub(from.chars().count());
        let message: String = question.chars().take(room).collect::<String>() + &from;
        let outcome = self
            .ask(request.session_id, &message, Asker::ComputerUse, timeout)
            .map_err(|error| {
                (
                    NOT_ALLOWED,
                    format!(
                        "Not done: the person could not be asked ({}).",
                        error.message
                    ),
                )
            })?;
        match outcome.action {
            ElicitationAction::Accept => Ok(()),
            ElicitationAction::Decline => {
                Err((NOT_ALLOWED, "Not done: the person declined.".into()))
            }
            ElicitationAction::Cancel => {
                Err((NOT_ALLOWED, "Not done: nobody answered in time.".into()))
            }
        }
    }

    /// Whether this Mac can do computer use now, from Cua's own probe.
    pub(crate) fn computer_status(&self) -> Value {
        let (accessibility, screen_recording) = axo_computer::permissions();
        json!({
            "available": axo_computer::AVAILABLE && accessibility && screen_recording,
            "accessibility": accessibility,
            "screenRecording": screen_recording,
        })
    }

    pub(crate) fn set_asset_source(&self, source: Option<AssetSource>) {
        self.asset_source.set(source);
    }

    /// Fetches attachments into `~/.axo/assets`, as a prompt's are, with this Mac's credential.
    fn fetch_assets(&self, attachments: &Attachments) -> Result<Vec<FetchedAttachment>, RpcError> {
        let source = self.asset_source.get().ok_or_else(|| RpcError {
            code: ErrorCode::ServerError(-32003),
            message: "this Mac is not connected to its account".into(),
            data: None,
        })?;
        axo_relay::assets::fetch_all(&source, attachments).map_err(|error| RpcError {
            code: ErrorCode::ServerError(-32010),
            message: match error {
                FetchError::NotFound => "an asset is no longer in the account".into(),
                FetchError::Mismatch => "an asset did not match its name".into(),
                FetchError::Failed(error) => format!("an asset could not be fetched: {error}"),
            },
            data: None,
        })
    }
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

/// Registers `axo.assets.fetch`, for axod's own `axod mcp` (by code signature): it shows the
/// agent the images a connections script returned.
pub(crate) fn add_methods(manager: &Arc<SessionManager>, handler: &mut IoHandler) {
    let manager = Arc::clone(manager);
    handler.add_typed_only(
        Only {
            signer: Signer::ThisBinary,
            code: -32003,
            message: "only axod's own tools fetch assets here",
        },
        ASSETS_FETCH,
        "expected {attachments}",
        move |request: FetchAssets| {
            let fetched = manager.fetch_assets(&request.attachments)?;
            Ok(Fetched {
                files: fetched
                    .into_iter()
                    .map(|file| FetchedFile {
                        path: file.path.to_string_lossy().into_owned(),
                        asset: file.asset.to_string(),
                        name: file.name.as_str().to_owned(),
                        mime_type: file.mime_type.as_str().to_owned(),
                        size: file.size,
                    })
                    .collect(),
            })
        },
    );
}
