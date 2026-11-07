//! Answering the relay's `axo.remote.*` requests by calling into the host.

use std::io;
use std::sync::Arc;

use serde_json::Value;

use super::session::current_timestamp;
use super::wire::{
    ErrorBody, IncomingMessage, JSONRPC, KeyParams, LayoutSetParams, ModelSetParams, OutgoingError,
    OutgoingResponse, OutgoingResult, PromptParams, RemoteResult, RenameSessionParams,
    SessionTargetParams, ShellTargetParams, StopParams, TargetParams, TerminalInputParams,
    TerminalResizeParams, WorkspaceSessionTargetParams,
};
use crate::host::RelayHost;

/// Answers a request from the relay; `None` for anything that is not a request.
pub(super) fn remote_request_reply(
    message: &IncomingMessage,
    sessions: &Arc<dyn RelayHost>,
    host_id: &str,
    host_generation: &str,
) -> Option<OutgoingResponse> {
    let id = message.id.clone()?;
    let method = message.method.as_deref()?;
    let result = dispatch_remote_call(method, &message.params, sessions, host_id, host_generation);
    Some(match result {
        Ok(result) => OutgoingResponse::Result(Box::new(OutgoingResult {
            jsonrpc: JSONRPC,
            id,
            result,
        })),
        Err((code, message)) => OutgoingResponse::Error(OutgoingError {
            jsonrpc: JSONRPC,
            id,
            error: ErrorBody { code, message },
        }),
    })
}

fn dispatch_remote_call(
    method: &str,
    params: &Value,
    sessions: &Arc<dyn RelayHost>,
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
            let stopped = sessions
                .remote_stop_pi_turn(request.session_id, &request.turn_id)
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_remote_call_the_parity_table_promises_is_dispatched() {
        use axo_protocol::parity::{PARITY, Remote};
        let host: Arc<dyn RelayHost> = Arc::new(crate::link::testing::IdentityOnlyHost);
        for parity in PARITY {
            let Remote::Call(name) = parity.remote else {
                continue;
            };
            // Empty params fail parsing, so no host method runs; "method not found" is the
            // only answer that means the call is not wired.
            let answer = dispatch_remote_call(name, &json!({}), &host, "host", "generation");
            assert!(
                matches!(answer, Err((-32602, _))),
                "{name} is promised but not dispatched: {:?}",
                answer.map(|_| ())
            );
        }
    }

    #[test]
    fn planned_remote_calls_are_not_dispatched_yet() {
        use axo_protocol::parity::{PARITY, Remote};
        let host: Arc<dyn RelayHost> = Arc::new(crate::link::testing::IdentityOnlyHost);
        for parity in PARITY {
            if let Remote::Planned(name) = parity.remote {
                let answer = dispatch_remote_call(name, &json!({}), &host, "host", "generation");
                assert!(
                    matches!(answer, Err((-32601, _))),
                    "{name} is dispatched: move it to Remote::Call"
                );
            }
        }
    }
}
