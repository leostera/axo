//! The account's calls to this Mac: `axo.remote.*`, from the web and the phone through the relay
//! (RFD0024, RFD0034 step 6).
//!
//! They are ordinary methods of axod, beside the local ones, that answer only
//! [`Caller::Relay`]: the relay is a transport that hands each request to axod as the account
//! and sends the answer back. The account sees a redacted view: Sessions as
//! [`RemoteSessionSnapshot`]s (folder names, no paths) and layouts pruned to terminals.
//!
//! Every call names the Mac it is for (`target`); a call for an earlier identity of this Mac is
//! refused as stale, so a phone holding an old list can't act on a Mac that was reset.

use std::future::Future;
use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axo_ipc::peer::Caller;
use axo_ipc::{Extension, Only, TypedMethods};
use axo_protocol::rpc::error_code::{
    BUSY, INVALID_PARAMS, NOT_FOUND, REFUSED, STALE_HOST, TIMED_OUT,
};
use axo_protocol::rpc::{self, MethodError, PromptDelivery};
use axo_protocol::{Layout, LayoutNode, RemoteSessionSnapshot, SessionId, SessionRecord, ShellId};
use axo_pty::WindowSize;
use axo_relay::{ClientDelivery, CommandId, ModelChoice, PiKey, StopTarget, TurnId};
use jsonrpc_core::IoHandler;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::core::Core;
use crate::ops;

/// What a local client is told when it calls a method meant for the account: there is none.
const RELAY_ONLY: Only = Only {
    caller: Caller::Relay,
    code: -32601,
    message: "Method not found",
};

/// Prompts on their way to Pi on this Mac at once; more are refused until one ends.
const MAX_PROMPTS: usize = 16;
/// The longest prompt text the account may send.

/// The account's methods.
pub(crate) struct Remote {
    core: Arc<Core>,
    prompts: Arc<AtomicUsize>,
}

impl Remote {
    pub(crate) fn new(core: Arc<Core>) -> Self {
        Self {
            core,
            prompts: Arc::default(),
        }
    }
}

/// A call's failure as the account sees it: a code and a fixed message.

/// Registers `name` to parse its parameters as `P`, check they are for this Mac, and run `call`.
fn add<P, R, F, Fut>(handler: &mut IoHandler, core: &Arc<Core>, name: &'static str, call: F)
where
    P: for<'de> Deserialize<'de> + Targeted + Send + 'static,
    R: Serialize + 'static,
    F: Fn(Arc<Core>, P) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<R, MethodError>> + Send + 'static,
{
    let core = Arc::clone(core);
    let call = Arc::new(call);
    handler.add_typed_only(RELAY_ONLY, name, "Invalid params", move |params: Value| {
        let core = Arc::clone(&core);
        let call = Arc::clone(&call);
        async move {
            let request: P =
                serde_json::from_value(params).map_err(|_| axo_ipc::rpc_error(invalid()))?;
            let target = request.target();
            if target.host_id != core.host_id || target.host_generation != core.host_generation {
                return Err(axo_ipc::rpc_error(MethodError::new(
                    STALE_HOST,
                    "Stale host",
                )));
            }
            call(core, request).await.map_err(axo_ipc::rpc_error)
        }
    });
}

/// Pi has no credentials for the model's provider.
const NOT_SIGNED_IN: i64 = -32007;

fn invalid() -> MethodError {
    MethodError::new(INVALID_PARAMS, "Invalid params")
}

/// How the account is told an operation failed; the details stay on this Mac.
fn failed(error: io::Error) -> MethodError {
    match error.kind() {
        io::ErrorKind::InvalidInput => invalid(),
        io::ErrorKind::NotFound => MethodError::new(NOT_FOUND, "Resource not found"),
        io::ErrorKind::AddrInUse | io::ErrorKind::WouldBlock => {
            MethodError::new(BUSY, "Resource busy")
        }
        io::ErrorKind::PermissionDenied => {
            MethodError::new(NOT_SIGNED_IN, "Not signed in to that model's provider")
        }
        io::ErrorKind::TimedOut => MethodError::new(TIMED_OUT, "Pi is still starting; try again"),
        _ => MethodError::new(REFUSED, "Operation failed"),
    }
}

fn remote(core: &Core, session: &SessionRecord) -> RemoteSessionSnapshot {
    RemoteSessionSnapshot::from_record(session, &core.host_id, &axo_relay::current_timestamp())
}

impl Extension for Remote {
    fn name(&self) -> &'static str {
        "remote"
    }

    fn register(&self, handler: &mut IoHandler) {
        let core = &self.core;
        add(
            handler,
            core,
            "axo.remote.session.create",
            // The account names no paths: a new Session starts beside another, or at home.
            |core, request: CreateSessionParams| async move {
                let session = crate::sessions::create(
                    &core,
                    request
                        .like
                        .map_or(rpc::CreateSession::AtHome, rpc::CreateSession::Like),
                )
                .await
                .map_err(failed)?;
                Ok(Answer::Session {
                    session: remote(&core, &session),
                })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.close",
            |core, request: SessionTargetParams| async move {
                ops::close_session(&core, request.session_id)
                    .await
                    .map_err(failed)?;
                Ok(Answer::SessionClosed {
                    closed: true,
                    session_id: request.session_id,
                })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.rename",
            |core, request: RenameSessionParams| async move {
                ops::rename(&core, request.session_id, request.name)
                    .await
                    .map_err(failed)?;
                Ok(Answer::Saved { saved: true })
            },
        );
        add(
            handler,
            core,
            "axo.remote.shell.create",
            |core, request: SessionTargetParams| async move {
                let shell = ops::create_shell(&core, request.session_id)
                    .await
                    .map_err(failed)?;
                Ok(Answer::ShellCreated {
                    host_id: core.host_id.clone(),
                    session_id: request.session_id,
                    shell_id: shell.id,
                })
            },
        );
        add(
            handler,
            core,
            "axo.remote.shell.close",
            |core, request: ShellTargetParams| async move {
                ops::close_shell(&core, request.session_id, request.shell_id)
                    .await
                    .map_err(failed)?;
                Ok(Answer::ShellClosed {
                    closed: true,
                    host_id: core.host_id.clone(),
                    session_id: request.session_id,
                    shell_id: request.shell_id,
                })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.layout.set",
            |core, request: LayoutSetParams| async move {
                let layout = Layout::try_from(request.layout).map_err(|_| invalid())?;
                ops::set_layout(&core, request.session_id, layout)
                    .await
                    .map_err(failed)?;
                Ok(Answer::Saved { saved: true })
            },
        );
        add(
            handler,
            core,
            "axo.remote.terminal.input",
            |core, request: TerminalInputParams| async move {
                // Typing into a dormant Pi starts it; this keystroke is lost, as it has nowhere
                // to go yet.
                if !ops::wake(&core, request.session_id, Some(request.shell_id))
                    .await
                    .map_err(failed)?
                {
                    ops::write_input(
                        &core,
                        request.session_id,
                        request.shell_id,
                        request.sequence,
                        request.data,
                    )
                    .await
                    .map_err(failed)?;
                }
                Ok(Answer::InputAccepted {
                    accepted: true,
                    sequence: request.sequence,
                })
            },
        );
        let prompts = Arc::clone(&self.prompts);
        add(
            handler,
            core,
            "axo.remote.session.prompt",
            move |core, request: PromptParams| {
                let prompts = Arc::clone(&prompts);
                async move {
                    prompt(&core, &prompts, request).await?;
                    Ok(Answer::PromptAccepted { accepted: true })
                }
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.commands",
            |core, request: SessionTargetParams| async move {
                let commands = ops::pi_commands(&core, request.session_id)
                    .await
                    .map_err(failed)?;
                Ok(Answer::Commands { commands })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.models",
            |core, request: SessionTargetParams| async move {
                let models = ops::pi_models(&core, request.session_id)
                    .await
                    .map_err(failed)?;
                Ok(Answer::Models { models })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.model.set",
            |core, request: ModelSetParams| async move {
                if request.model.is_none() && request.thinking_level.is_none() {
                    return Err(invalid());
                }
                ops::set_model(
                    &core,
                    request.session_id,
                    request.model.map(|model| {
                        (
                            model.provider.as_str().to_owned(),
                            model.id.as_str().to_owned(),
                        )
                    }),
                    request.thinking_level,
                )
                .await
                .map_err(failed)?;
                Ok(Answer::Saved { saved: true })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.restart",
            |core, request: SessionTargetParams| async move {
                ops::restart_for_client(&core, request.session_id)
                    .await
                    .map_err(failed)?;
                Ok(Answer::Restarted { restarted: true })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.stop",
            |core, request: StopParams| async move {
                let stop = StopTarget::new(request.turn_id, request.seen, request.command_ids)
                    .map_err(|_| invalid())?;
                let stopped = ops::stop_turn(&core, request.session_id, stop)
                    .await
                    .map_err(failed)?;
                Ok(Answer::Stopped { stopped })
            },
        );
        add(
            handler,
            core,
            "axo.remote.session.key",
            |core, request: KeyParams| async move {
                if !ops::wake(&core, request.session_id, None)
                    .await
                    .map_err(failed)?
                {
                    ops::press_key(&core, request.session_id, request.key)
                        .await
                        .map_err(failed)?;
                }
                Ok(Answer::KeyAccepted { accepted: true })
            },
        );
        add(
            handler,
            core,
            "axo.remote.terminal.resize",
            |core, request: TerminalResizeParams| async move {
                let size = WindowSize::new(request.rows, request.columns).ok_or_else(invalid)?;
                // A client sizing the pane is showing the Session: its Pi starts, at that size.
                ops::wake(&core, request.session_id, Some(request.shell_id))
                    .await
                    .map_err(failed)?;
                ops::resize(&core, request.session_id, request.shell_id, size)
                    .await
                    .map_err(failed)?;
                Ok(Answer::ResizeAccepted {
                    accepted: true,
                    rows: request.rows,
                    columns: request.columns,
                })
            },
        );
    }
}

/// A person away from the Mac prompts a Session's Pi: its attachments are fetched, all of them
/// or none (RFD0030), then Pi gets it, and this returns once Pi has it in its log (RFD0033).
async fn prompt(
    core: &Arc<Core>,
    prompts: &AtomicUsize,
    request: PromptParams,
) -> Result<(), MethodError> {
    // Refused before any attachment is fetched or a slot is taken.
    if request.text.is_blank() && request.attachments.is_empty() {
        return Err(invalid());
    }
    let source = core.assets.get();
    if source.is_none() && !request.attachments.is_empty() {
        return Err(MethodError::new(
            REFUSED,
            "this Mac can't fetch attachments",
        ));
    }
    if prompts.fetch_add(1, Ordering::SeqCst) >= MAX_PROMPTS {
        prompts.fetch_sub(1, Ordering::SeqCst);
        return Err(MethodError::new(
            BUSY,
            "too many prompts are on their way on this Mac",
        ));
    }
    let delivered = deliver(core, source, request).await;
    prompts.fetch_sub(1, Ordering::SeqCst);
    delivered
}

async fn deliver(
    core: &Arc<Core>,
    source: Option<axo_relay::assets::AssetSource>,
    request: PromptParams,
) -> Result<(), MethodError> {
    let fetched = match source {
        Some(source) if !request.attachments.is_empty() => {
            let attachments = request.attachments.clone();
            axo_relay::assets::fetch_all(&source, &attachments)
                .await
                .map_err(|error| {
                    MethodError::new(
                        -32010,
                        match error {
                            axo_relay::assets::FetchError::NotFound => {
                                "an attachment is no longer in the account"
                            }
                            axo_relay::assets::FetchError::Mismatch => {
                                "an attachment did not match its name"
                            }
                            axo_relay::assets::FetchError::Failed(_) => {
                                "an attachment could not be fetched"
                            }
                        },
                    )
                })?
        }
        _ => Vec::new(),
    };
    // A client that sends no commandId still gets one, so pi-axo queues its prompt in the log
    // while Pi works rather than steering it into a queue a stop would empty (RFD0024).
    let command_id = match request.command_id {
        Some(command_id) => command_id,
        None => axo_protocol::new_uuid_v4()
            .ok()
            .and_then(|id| CommandId::try_from(id).ok())
            .ok_or_else(|| MethodError::new(REFUSED, "Operation failed"))?,
    };
    let delivery = match request.delivery {
        ClientDelivery::FollowUp => PromptDelivery::FollowUp,
        ClientDelivery::Steer => PromptDelivery::Steer,
        ClientDelivery::Interrupt => PromptDelivery::Interrupt,
    };
    crate::sessions::prompt_from_client(
        core,
        request.session_id,
        request.text,
        command_id,
        fetched,
        delivery,
    )
    .await
    .map_err(failed)
}

/// What `axo.remote.*` calls answer.
#[derive(Serialize)]
#[serde(untagged, rename_all_fields = "camelCase")]
enum Answer {
    Session {
        session: RemoteSessionSnapshot,
    },
    SessionClosed {
        closed: bool,
        session_id: SessionId,
    },
    ShellCreated {
        host_id: String,
        session_id: SessionId,
        shell_id: ShellId,
    },
    ShellClosed {
        closed: bool,
        host_id: String,
        session_id: SessionId,
        shell_id: ShellId,
    },
    Saved {
        saved: bool,
    },
    InputAccepted {
        accepted: bool,
        sequence: u64,
    },
    ResizeAccepted {
        accepted: bool,
        rows: u32,
        columns: u32,
    },
    PromptAccepted {
        accepted: bool,
    },
    KeyAccepted {
        accepted: bool,
    },
    /// Whether the turn the stop named was running, and is now stopping.
    Stopped {
        stopped: bool,
    },
    Commands {
        commands: Vec<axo_protocol::PiCommandInfo>,
    },
    Models {
        models: Vec<axo_protocol::PiModelInfo>,
    },
    Restarted {
        restarted: bool,
    },
}

/// The Mac a call is for, by its current identity.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HostRef {
    host_id: String,
    host_generation: String,
}

/// A call's parameters, each naming the Mac it is for.
trait Targeted {
    fn target(&self) -> &HostRef;
}

macro_rules! params {
    ($($name:ident { $($field:ident: $type:ty $(= $default:ident)?),* $(,)? })*) => {
        $(
            #[derive(Debug, Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct $name {
                target: HostRef,
                $($(#[serde($default)])? $field: $type,)*
            }

            impl Targeted for $name {
                fn target(&self) -> &HostRef {
                    &self.target
                }
            }
        )*
    };
}

params! {
    SessionTargetParams { session_id: SessionId }
    CreateSessionParams { like: Option<SessionId> = default }
    RenameSessionParams { session_id: SessionId, name: String }
    ShellTargetParams { session_id: SessionId, shell_id: ShellId }
    LayoutSetParams { session_id: SessionId, layout: LayoutNode }
    TerminalInputParams { session_id: SessionId, shell_id: ShellId, sequence: u64, data: rpc::TerminalBytes }
    TerminalResizeParams { session_id: SessionId, shell_id: ShellId, rows: u32, columns: u32 }
    KeyParams { session_id: SessionId, key: PiKey }
    PromptParams {
        session_id: SessionId,
        text: rpc::PromptText,
        command_id: Option<CommandId> = default,
        attachments: axo_protocol::asset::Attachments = default,
        // When a working Pi takes it (RFD0033); a follow-up when absent.
        delivery: ClientDelivery = default,
    }
    ModelSetParams {
        session_id: SessionId,
        model: Option<ModelChoice> = default,
        thinking_level: Option<axo_protocol::ThinkingLevel> = default,
    }
    StopParams {
        session_id: SessionId,
        turn_id: Option<TurnId> = default,
        seen: Option<TurnId> = default,
        command_ids: Vec<CommandId> = default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::Fixture;
    use axo_protocol::parity::{PARITY, Remote as Parity};
    use serde_json::json;

    fn methods(fixture: &Fixture) -> IoHandler {
        let mut handler = IoHandler::new();
        Remote::new(Arc::clone(&fixture.core)).register(&mut handler);
        handler
    }

    async fn call(handler: &IoHandler, method: &str, params: Value) -> Value {
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let answer = handler.handle_request(&request.to_string()).await;
        serde_json::from_str(&answer.unwrap()).unwrap()
    }

    async fn as_account(handler: &IoHandler, method: &str, params: Value) -> Value {
        axo_ipc::peer::as_relay(call(handler, method, params)).await
    }

    fn target(fixture: &Fixture) -> Value {
        json!({ "hostId": fixture.core.host_id, "hostGeneration": fixture.core.host_generation })
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn every_remote_call_the_parity_table_promises_is_answered_and_no_planned_one() {
        let fixture = Fixture::new().await;
        let handler = methods(&fixture);
        for parity in PARITY {
            match parity.remote {
                // Empty params fail parsing, so nothing runs; "method not found" would mean the
                // call is not wired.
                Parity::Call(name) => assert_eq!(
                    as_account(&handler, name, json!({})).await["error"]["code"],
                    -32602,
                    "{name} is promised but not answered"
                ),
                Parity::Planned(name) => assert_eq!(
                    as_account(&handler, name, json!({})).await["error"]["code"],
                    -32601,
                    "{name} is answered: move it to Remote::Call"
                ),
                _ => {}
            }
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn only_the_account_is_answered_and_only_for_this_mac() {
        let fixture = Fixture::new().await;
        let handler = methods(&fixture);
        let params = json!({ "target": target(&fixture) });

        // A local program sees no such method, even with a valid call.
        let local = call(&handler, "axo.remote.session.create", params.clone()).await;
        assert_eq!(
            local["error"],
            json!({ "code": -32601, "message": "Method not found" })
        );

        let created = as_account(&handler, "axo.remote.session.create", params).await;
        let session = &created["result"]["session"];
        let beside = as_account(
            &handler,
            "axo.remote.session.create",
            json!({ "target": target(&fixture), "like": session["sessionId"] }),
        )
        .await;
        assert_eq!(
            beside["result"]["session"]["folderName"], session["folderName"],
            "{beside}"
        );
        // The account sees names, not paths.
        for answer in [&created, &beside] {
            assert!(
                !answer
                    .to_string()
                    .contains(&*fixture.core.home.to_string_lossy()),
                "{answer}"
            );
        }

        let stale = as_account(
            &handler,
            "axo.remote.session.create",
            json!({ "target": { "hostId": fixture.core.host_id, "hostGeneration": "an-earlier-one" } }),
        ).await;
        assert_eq!(
            stale["error"],
            json!({ "code": -32002, "message": "Stale host" })
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_operation_tells_the_account_only_its_kind() {
        let fixture = Fixture::new().await;
        let handler = methods(&fixture);
        let unknown = SessionId::from_u128(42);
        let renamed = as_account(
            &handler,
            "axo.remote.session.rename",
            json!({ "target": target(&fixture), "sessionId": unknown, "name": "x" }),
        )
        .await;
        assert_eq!(
            renamed["error"],
            json!({ "code": -32004, "message": "Resource not found" })
        );
        let empty = as_account(
            &handler,
            "axo.remote.session.prompt",
            json!({ "target": target(&fixture), "sessionId": unknown, "text": "" }),
        )
        .await;
        assert_eq!(empty["error"]["code"], -32602);
        let model = as_account(
            &handler,
            "axo.remote.session.model.set",
            json!({ "target": target(&fixture), "sessionId": unknown }),
        )
        .await;
        assert_eq!(
            model["error"]["code"], -32602,
            "neither a model nor a level"
        );
    }
}
