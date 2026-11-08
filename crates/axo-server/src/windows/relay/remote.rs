//! The Windows host answers the account's AXP methods (RFD0034).
//! Retains the typed remote wire vocabulary moved out of axo-relay upstream.
use super::Host;
use axo_protocol::{LayoutNode, RemoteSessionSnapshot, SessionId, ShellId};
use axo_relay::current_timestamp;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io;

pub(super) fn answer(host: &Host, request: Value) -> Option<Value> {
    let id = request
        .get("id")
        .filter(|id| id.is_number() || id.is_string())?
        .clone();
    let name = request["method"].as_str()?;
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    let result = dispatch_remote_call(name, &params, host, &host.id, &host.generation);
    Some(match result {
        Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
        Err((code, message)) => {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
        }
    })
}

fn dispatch_remote_call(
    method: &str,
    params: &Value,
    sessions: &Host,
    host_id: &str,
    host_generation: &str,
) -> Result<RemoteResult, (i64, &'static str)> {
    macro_rules! parsed {
        ($type:ty) => {
            serde_json::from_value::<$type>(params.clone())
                .map_err(|_| (-32602, "Invalid params"))?
        };
    }
    macro_rules! target_ok {
        ($target:expr) => {
            if $target.host_id != host_id || $target.host_generation != host_generation {
                return Err((-32002, "Stale host"));
            }
        };
    }

    match method {
        "axo.remote.session.create" => {
            let request = parsed!(TargetParams);
            target_ok!(request.target);
            let session = sessions
                .remote_create_session(&current_timestamp())
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Session { session })
        }
        "axo.remote.workspace.session.create" => {
            let request = parsed!(WorkspaceSessionTargetParams);
            target_ok!(request.target);
            let session = sessions
                .remote_create_workspace_session(&request.workspace_id, &current_timestamp())
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Session { session })
        }
        "axo.remote.session.close" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let replacement = sessions
                .remote_close_session(request.session_id, &current_timestamp())
                .map_err(map_operation_error)?;
            Ok(RemoteResult::SessionClosed {
                closed: true,
                session_id: request.session_id,
                replacement,
            })
        }
        "axo.remote.workspace.list" => {
            let request = parsed!(TargetParams);
            target_ok!(request.target);
            let workspaces = sessions.remote_workspaces().map_err(map_operation_error)?;
            Ok(RemoteResult::Workspaces { workspaces })
        }
        "axo.remote.session.rename" => {
            let request = parsed!(RenameSessionParams);
            target_ok!(request.target);
            sessions
                .remote_rename_session(request.session_id, &request.name)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Saved { saved: true })
        }
        "axo.remote.shell.create" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let shell_id = sessions
                .remote_create_shell(request.session_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::ShellCreated {
                host_id: host_id.to_owned(),
                session_id: request.session_id,
                shell_id,
            })
        }
        "axo.remote.shell.close" => {
            let request = parsed!(ShellTargetParams);
            target_ok!(request.target);
            sessions
                .remote_close_shell(request.session_id, request.shell_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::ShellClosed {
                closed: true,
                host_id: host_id.to_owned(),
                session_id: request.session_id,
                shell_id: request.shell_id,
            })
        }
        "axo.remote.session.layout.set" => {
            let request = parsed!(LayoutSetParams);
            target_ok!(request.target);
            sessions
                .remote_set_layout(request.session_id, request.layout)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Saved { saved: true })
        }
        "axo.remote.terminal.input" => {
            let request = parsed!(TerminalInputParams);
            target_ok!(request.target);
            sessions
                .remote_terminal_input(
                    request.session_id,
                    request.shell_id,
                    request.sequence,
                    &request.data,
                )
                .map_err(map_operation_error)?;
            Ok(RemoteResult::InputAccepted {
                accepted: true,
                sequence: request.sequence,
            })
        }
        "axo.remote.session.prompt" => {
            let request = parsed!(PromptParams);
            if !request.attachments.is_empty() {
                return Err((
                    -32003,
                    "Attachments are not supported by the Windows Codex backend",
                ));
            }
            target_ok!(request.target);
            sessions
                .remote_prompt_pi(
                    request.session_id,
                    &request.text,
                    request.command_id.as_ref(),
                    &[],
                    request.delivery,
                )
                .map_err(map_operation_error)?;
            Ok(RemoteResult::PromptAccepted { accepted: true })
        }
        "axo.remote.session.commands" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let commands = sessions
                .remote_pi_commands(request.session_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Commands { commands })
        }
        "axo.remote.session.models" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let models = sessions
                .remote_pi_models(request.session_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Models { models })
        }
        "axo.remote.session.model.set" => {
            let request = parsed!(ModelSetParams);
            target_ok!(request.target);
            if request.model.is_none() && request.thinking_level.is_none() {
                return Err((-32602, "Invalid params"));
            }
            sessions
                .remote_set_pi_model(
                    request.session_id,
                    request.model.as_ref(),
                    request.thinking_level,
                )
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Saved { saved: true })
        }
        "axo.remote.session.restart" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            sessions
                .remote_restart_pi(request.session_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Restarted { restarted: true })
        }
        "axo.remote.session.stop" => {
            let request = parsed!(StopParams);
            target_ok!(request.target);
            let stop =
                axo_relay::StopTarget::new(request.turn_id, request.seen, request.command_ids)
                    .map_err(|_| (-32602, "Invalid params"))?;
            let stopped = sessions
                .remote_stop_pi_turn(request.session_id, &stop)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Stopped { stopped })
        }
        "axo.remote.session.key" => {
            let request = parsed!(KeyParams);
            target_ok!(request.target);
            sessions
                .remote_press_pi_key(request.session_id, request.key)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::KeyAccepted { accepted: true })
        }
        "axo.remote.terminal.resize" => {
            let request = parsed!(TerminalResizeParams);
            target_ok!(request.target);
            sessions
                .remote_terminal_resize(
                    request.session_id,
                    request.shell_id,
                    request.rows,
                    request.columns,
                )
                .map_err(map_operation_error)?;
            Ok(RemoteResult::ResizeAccepted {
                accepted: true,
                rows: request.rows,
                columns: request.columns,
            })
        }
        _ => Err((-32601, "Method not found")),
    }
}

pub(super) fn map_operation_error(error: io::Error) -> (i64, &'static str) {
    match error.kind() {
        io::ErrorKind::InvalidInput => (-32602, "Invalid params"),
        io::ErrorKind::NotFound => (-32004, "Resource not found"),
        io::ErrorKind::AddrInUse | io::ErrorKind::WouldBlock => (-32006, "Resource busy"),
        io::ErrorKind::PermissionDenied => (-32007, "Not signed in to that model's provider"),
        io::ErrorKind::TimedOut => (-32008, "Pi is still starting; try again"),
        _ => (-32003, "Operation failed"),
    }
}

/// Results of `axo.remote.*` calls.
#[derive(Serialize)]
#[serde(untagged, rename_all_fields = "camelCase")]
pub(super) enum RemoteResult {
    Session {
        session: RemoteSessionSnapshot,
    },
    SessionClosed {
        closed: bool,
        session_id: SessionId,
        replacement: Option<RemoteSessionSnapshot>,
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
    Workspaces {
        workspaces: Vec<axo_protocol::RemoteWorkspace>,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct KeyParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) key: axo_relay::PiKey,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PromptParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) text: String,
    #[serde(default)]
    pub(super) command_id: Option<axo_relay::CommandId>,
    #[serde(default)]
    pub(super) attachments: axo_protocol::asset::Attachments,
    /// When a working Pi takes it (RFD0033); a follow-up when absent.
    #[serde(default)]
    pub(super) delivery: axo_relay::ClientDelivery,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ModelSetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    #[serde(default)]
    pub(super) model: Option<axo_relay::ModelChoice>,
    #[serde(default)]
    pub(super) thinking_level: Option<axo_protocol::ThinkingLevel>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StopParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    #[serde(default)]
    pub(super) turn_id: Option<axo_relay::TurnId>,
    #[serde(default)]
    pub(super) seen: Option<axo_relay::TurnId>,
    #[serde(default)]
    pub(super) command_ids: Vec<axo_relay::CommandId>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct HostRef {
    pub(super) host_id: String,
    pub(super) host_generation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TargetParams {
    pub(super) target: HostRef,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SessionTargetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RenameSessionParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct WorkspaceSessionTargetParams {
    pub(super) target: HostRef,
    pub(super) workspace_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ShellTargetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct LayoutSetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) layout: LayoutNode,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TerminalInputParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) sequence: u64,
    pub(super) data: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TerminalResizeParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) rows: u32,
    pub(super) columns: u32,
}
