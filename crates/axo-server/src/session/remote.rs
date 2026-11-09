//! The account's calls to this Mac: `axo.remote.*`, from the web and the phone through the relay
//! (RFD0019, RFD0024, RFD0034 step 6).
//!
//! They are ordinary methods of axod, beside the local ones, that answer only
//! [`Caller::Relay`]: the relay is a transport that hands each request to axod as the account
//! and sends the answer back. The account sees a redacted view: Sessions as
//! [`RemoteSessionSnapshot`]s (folder names, no paths) and layouts pruned to terminals.
//!
//! Every call names the Mac it is for (`target`); a call for an earlier identity of this Mac is
//! refused as stale, so a phone holding an old list can't act on a Mac that was reset.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axo_ipc::peer::Caller;
use axo_ipc::{Extension, Only, TypedMethods};
use axo_protocol::rpc::{self, PromptDelivery};
use axo_protocol::{Layout, LayoutNode, RemoteSessionSnapshot, SessionId, SessionRecord, ShellId};
use axo_pty::WindowSize;
use axo_relay::{ClientDelivery, CommandId, ModelChoice, PiKey, StopTarget, TurnId};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::SessionManager;

/// What a local client is told when it calls a method meant for the account: there is none.
const RELAY_ONLY: Only = Only {
    caller: Caller::Relay,
    code: -32601,
    message: "Method not found",
};

/// Prompts on their way to Pi on this Mac at once; more are refused until one ends.
const MAX_PROMPTS: usize = 16;
/// The longest prompt text the account may send.
const MAX_PROMPT_BYTES: usize = 16_000;

/// The account's methods, answered with the Session manager.
pub(crate) struct Remote {
    manager: Arc<SessionManager>,
    prompts: Arc<AtomicUsize>,
}

impl Remote {
    pub(crate) fn new(manager: Arc<SessionManager>) -> Self {
        Self {
            manager,
            prompts: Arc::default(),
        }
    }
}

/// A call's failure as the account sees it: a code and a fixed message.
type Refusal = (i64, &'static str);

/// Registers `name` to parse its parameters as `P`, check they are for this Mac, and run `call`.
fn add<P, R>(
    handler: &mut IoHandler,
    manager: &Arc<SessionManager>,
    name: &'static str,
    call: impl Fn(&Arc<SessionManager>, P) -> Result<R, Refusal> + Send + Sync + 'static,
) where
    P: for<'de> Deserialize<'de> + Targeted + 'static,
    R: Serialize + 'static,
{
    let manager = Arc::clone(manager);
    handler.add_typed_only(RELAY_ONLY, name, "Invalid params", move |params: Value| {
        let request: P = serde_json::from_value(params).map_err(|_| refusal(INVALID))?;
        let target = request.target();
        if target.host_id != manager.host_id || target.host_generation != manager.host_generation {
            return Err(refusal((-32002, "Stale host")));
        }
        call(&manager, request).map_err(refusal)
    });
}

const INVALID: Refusal = (-32602, "Invalid params");

fn refusal((code, message): Refusal) -> RpcError {
    RpcError {
        code: ErrorCode::from(code),
        message: message.to_owned(),
        data: None,
    }
}

/// How the account is told an operation failed; the details stay on this Mac.
fn failed(error: io::Error) -> Refusal {
    match error.kind() {
        io::ErrorKind::InvalidInput => INVALID,
        io::ErrorKind::NotFound => (-32004, "Resource not found"),
        io::ErrorKind::AddrInUse | io::ErrorKind::WouldBlock => (-32006, "Resource busy"),
        io::ErrorKind::PermissionDenied => (-32007, "Not signed in to that model's provider"),
        io::ErrorKind::TimedOut => (-32008, "Pi is still starting; try again"),
        _ => (-32003, "Operation failed"),
    }
}

impl SessionManager {
    fn remote(&self, session: &SessionRecord) -> RemoteSessionSnapshot {
        RemoteSessionSnapshot::from_record(session, &self.host_id, &axo_relay::current_timestamp())
    }
}

impl Extension for Remote {
    fn name(&self) -> &'static str {
        "remote"
    }

    fn register(&self, handler: &mut IoHandler) {
        let manager = &self.manager;
        add(
            handler,
            manager,
            "axo.remote.session.create",
            // The account names no paths: a new Session starts beside another, or at home.
            |m, request: CreateSessionParams| {
                let session = m
                    .create_session(rpc::CreateSession {
                        folder: None,
                        like: request.like,
                    })
                    .map_err(failed)?;
                Ok(Answer::Session {
                    session: m.remote(&session),
                })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.close",
            |m, request: SessionTargetParams| {
                m.close_session_and_publish(request.session_id)
                    .map_err(failed)?;
                Ok(Answer::SessionClosed {
                    closed: true,
                    session_id: request.session_id,
                })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.rename",
            |m, request: RenameSessionParams| {
                m.rename_session(request.session_id, &request.name)
                    .map_err(failed)?;
                Ok(Answer::Saved { saved: true })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.shell.create",
            |m, request: SessionTargetParams| {
                let shell = m
                    .create_shell_and_publish(request.session_id)
                    .map_err(failed)?;
                Ok(Answer::ShellCreated {
                    host_id: m.host_id.clone(),
                    session_id: request.session_id,
                    shell_id: shell.id,
                })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.shell.close",
            |m, request: ShellTargetParams| {
                m.close_shell_and_publish(request.session_id, request.shell_id)
                    .map_err(failed)?;
                Ok(Answer::ShellClosed {
                    closed: true,
                    host_id: m.host_id.clone(),
                    session_id: request.session_id,
                    shell_id: request.shell_id,
                })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.layout.set",
            |m, request: LayoutSetParams| {
                let layout = Layout::try_from(request.layout).map_err(|_| INVALID)?;
                m.set_layout_and_publish(request.session_id, layout)
                    .map_err(failed)?;
                Ok(Answer::Saved { saved: true })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.terminal.input",
            |m, request: TerminalInputParams| {
                // Typing into a dormant Pi starts it; this keystroke is lost, as it has nowhere
                // to go yet.
                if !m
                    .wake_dormant_pane(request.session_id, request.shell_id)
                    .map_err(failed)?
                {
                    m.write_terminal_input(
                        request.session_id,
                        request.shell_id,
                        request.sequence,
                        &request.data,
                    )
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
            manager,
            "axo.remote.session.prompt",
            move |m, request: PromptParams| {
                prompt(m, &prompts, request)?;
                Ok(Answer::PromptAccepted { accepted: true })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.commands",
            |m, request: SessionTargetParams| {
                let commands = m.pi_commands(request.session_id).map_err(failed)?;
                Ok(Answer::Commands { commands })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.models",
            |m, request: SessionTargetParams| {
                let models = m.pi_models(request.session_id).map_err(failed)?;
                Ok(Answer::Models { models })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.model.set",
            |m, request: ModelSetParams| {
                if request.model.is_none() && request.thinking_level.is_none() {
                    return Err(INVALID);
                }
                m.set_pi_model(
                    request.session_id,
                    request
                        .model
                        .as_ref()
                        .map(|model| (model.provider.as_str(), model.id.as_str())),
                    request.thinking_level,
                )
                .map_err(failed)?;
                Ok(Answer::Saved { saved: true })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.restart",
            |m, request: SessionTargetParams| {
                m.restart_pi_for_client(request.session_id)
                    .map_err(failed)?;
                Ok(Answer::Restarted { restarted: true })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.stop",
            |m, request: StopParams| {
                let stop = StopTarget::new(request.turn_id, request.seen, request.command_ids)
                    .map_err(|_| INVALID)?;
                let stopped = m.stop_pi_turn(request.session_id, &stop).map_err(failed)?;
                Ok(Answer::Stopped { stopped })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.session.key",
            |m, request: KeyParams| {
                if !m.wake_dormant_pi(request.session_id).map_err(failed)? {
                    m.press_pi_key(request.session_id, request.key)
                        .map_err(failed)?;
                }
                Ok(Answer::KeyAccepted { accepted: true })
            },
        );
        add(
            handler,
            manager,
            "axo.remote.terminal.resize",
            |m, request: TerminalResizeParams| {
                let size = WindowSize::new(request.rows, request.columns).ok_or(INVALID)?;
                // A client sizing the pane is showing the Session: its Pi starts, at that size.
                m.wake_dormant_pane(request.session_id, request.shell_id)
                    .map_err(failed)?;
                m.resize_terminal(request.session_id, request.shell_id, size)
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
fn prompt(
    manager: &Arc<SessionManager>,
    prompts: &AtomicUsize,
    request: PromptParams,
) -> Result<(), Refusal> {
    if request.text.len() > MAX_PROMPT_BYTES
        || (request.text.is_empty() && request.attachments.is_empty())
    {
        return Err(INVALID);
    }
    let source = manager.asset_slot().get();
    if source.is_none() && !request.attachments.is_empty() {
        return Err((-32003, "this Mac can't fetch attachments"));
    }
    if prompts.fetch_add(1, Ordering::SeqCst) >= MAX_PROMPTS {
        prompts.fetch_sub(1, Ordering::SeqCst);
        return Err((-32006, "too many prompts are on their way on this Mac"));
    }
    let delivered = deliver(manager, source.as_ref(), request);
    prompts.fetch_sub(1, Ordering::SeqCst);
    delivered
}

fn deliver(
    manager: &Arc<SessionManager>,
    source: Option<&axo_relay::assets::AssetSource>,
    request: PromptParams,
) -> Result<(), Refusal> {
    let fetched = match source {
        Some(source) if !request.attachments.is_empty() => {
            axo_relay::assets::fetch_all(source, &request.attachments).map_err(|error| {
                (
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
            .ok_or((-32003, "Operation failed"))?,
    };
    let delivery = match request.delivery {
        ClientDelivery::FollowUp => PromptDelivery::FollowUp,
        ClientDelivery::Steer => PromptDelivery::Steer,
        ClientDelivery::Interrupt => PromptDelivery::Interrupt,
    };
    manager
        .prompt_pi(
            request.session_id,
            &request.text,
            &command_id,
            &fetched,
            delivery,
        )
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
    TerminalInputParams { session_id: SessionId, shell_id: ShellId, sequence: u64, data: String }
    TerminalResizeParams { session_id: SessionId, shell_id: ShellId, rows: u32, columns: u32 }
    KeyParams { session_id: SessionId, key: PiKey }
    PromptParams {
        session_id: SessionId,
        text: String,
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
    use crate::session::test_support::LifecycleFixture;
    use axo_protocol::parity::{PARITY, Remote as Parity};
    use serde_json::json;

    fn methods(fixture: &LifecycleFixture) -> IoHandler {
        let mut handler = IoHandler::new();
        Remote::new(Arc::clone(&fixture.manager)).register(&mut handler);
        handler
    }

    fn call(handler: &IoHandler, method: &str, params: Value) -> Value {
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        serde_json::from_str(&handler.handle_request_sync(&request.to_string()).unwrap()).unwrap()
    }

    fn as_account(handler: &IoHandler, method: &str, params: Value) -> Value {
        axo_ipc::peer::as_relay(|| call(handler, method, params))
    }

    fn target(fixture: &LifecycleFixture) -> Value {
        json!({ "hostId": fixture.manager.host_id, "hostGeneration": fixture.manager.host_generation })
    }

    #[test]
    fn every_remote_call_the_parity_table_promises_is_answered_and_no_planned_one() {
        let fixture = LifecycleFixture::new();
        let handler = methods(&fixture);
        for parity in PARITY {
            match parity.remote {
                // Empty params fail parsing, so nothing runs; "method not found" would mean the
                // call is not wired.
                Parity::Call(name) => assert_eq!(
                    as_account(&handler, name, json!({}))["error"]["code"],
                    -32602,
                    "{name} is promised but not answered"
                ),
                Parity::Planned(name) => assert_eq!(
                    as_account(&handler, name, json!({}))["error"]["code"],
                    -32601,
                    "{name} is answered: move it to Remote::Call"
                ),
                _ => {}
            }
        }
    }

    #[test]
    fn only_the_account_is_answered_and_only_for_this_mac() {
        let fixture = LifecycleFixture::new();
        let handler = methods(&fixture);
        let params = json!({ "target": target(&fixture) });

        // A local program sees no such method, even with a valid call.
        let local = call(&handler, "axo.remote.session.create", params.clone());
        assert_eq!(
            local["error"],
            json!({ "code": -32601, "message": "Method not found" })
        );

        let created = as_account(&handler, "axo.remote.session.create", params);
        let session = &created["result"]["session"];
        let beside = as_account(
            &handler,
            "axo.remote.session.create",
            json!({ "target": target(&fixture), "like": session["sessionId"] }),
        );
        assert_eq!(
            beside["result"]["session"]["folderName"], session["folderName"],
            "{beside}"
        );
        // The account sees names, not paths.
        for answer in [&created, &beside] {
            assert!(
                !answer
                    .to_string()
                    .contains(&*fixture.manager.home.to_string_lossy()),
                "{answer}"
            );
        }

        let stale = as_account(
            &handler,
            "axo.remote.session.create",
            json!({ "target": { "hostId": fixture.manager.host_id, "hostGeneration": "an-earlier-one" } }),
        );
        assert_eq!(
            stale["error"],
            json!({ "code": -32002, "message": "Stale host" })
        );
    }

    #[test]
    fn a_failed_operation_tells_the_account_only_its_kind() {
        let fixture = LifecycleFixture::new();
        let handler = methods(&fixture);
        let unknown = SessionId::from_u128(42);
        let renamed = as_account(
            &handler,
            "axo.remote.session.rename",
            json!({ "target": target(&fixture), "sessionId": unknown, "name": "x" }),
        );
        assert_eq!(
            renamed["error"],
            json!({ "code": -32004, "message": "Resource not found" })
        );
        let empty = as_account(
            &handler,
            "axo.remote.session.prompt",
            json!({ "target": target(&fixture), "sessionId": unknown, "text": "" }),
        );
        assert_eq!(empty["error"]["code"], -32602);
        let model = as_account(
            &handler,
            "axo.remote.session.model.set",
            json!({ "target": target(&fixture), "sessionId": unknown }),
        );
        assert_eq!(
            model["error"]["code"], -32602,
            "neither a model nor a level"
        );
    }
}
