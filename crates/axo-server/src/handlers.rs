//! The local JSON-RPC methods for Sessions, panes and settings, and how their errors map to RPC
//! codes. Each is async: it asks a Session's task, or the store, and never blocks the runtime.

use std::io;
use std::sync::Arc;

use axo_ipc::{Extension, TypedMethods};
use axo_protocol::rpc::{self, method};
use axo_protocol::{Layout, SessionId, ShellId, Viewport};
use axo_pty::WindowSize;
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};

use crate::core::{Core, lock};
use crate::ops;
use crate::session::prompts::PromptError;
use crate::settings::ParsedConfigValue;

/// `axo.session.reopen` found no closed Session it could reopen.
const SESSION_NOT_REOPENED: i64 = -32005;
const DEFAULT_SCREEN_LINES: u32 = 200;
const MAX_SCREEN_LINES: u32 = 10_000;

/// Sessions, panes, Pi, settings and other Macs' Sessions.
pub(crate) struct Sessions(pub(crate) Arc<Core>);

pub(crate) fn invalid_params(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message: message.to_owned(),
        data: None,
    }
}

pub(crate) fn internal_rpc_error(error: io::Error) -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
        message: error.to_string(),
        data: None,
    }
}

/// `InvalidInput` errors are the caller's fault: answered as invalid params with `message`, or
/// with the error's own text. Anything else is internal.
fn invalid_input_or_internal(error: io::Error, message: Option<&str>) -> RpcError {
    if error.kind() == io::ErrorKind::InvalidInput {
        invalid_params(message.unwrap_or(&error.to_string()))
    } else {
        internal_rpc_error(error)
    }
}

/// RPC errors for `axo.session.prompt`: the caller's mistakes are invalid params; the rate limit
/// has a code of its own so an agent can tell it apart from Pi not taking the prompt.
fn prompt_rpc_error(error: PromptError) -> RpcError {
    let code = match error {
        PromptError::Invalid(_) => ErrorCode::InvalidParams,
        PromptError::RateLimited => ErrorCode::ServerError(-32003),
        PromptError::NoPi
        | PromptError::Busy
        | PromptError::QueueFull
        | PromptError::Unavailable(_) => ErrorCode::ServerError(-32004),
    };
    RpcError {
        code,
        message: error.to_string(),
        data: None,
    }
}

fn automatic_pi_restart_rpc_error(
    session_id: SessionId,
    shell_id: ShellId,
    error: io::Error,
) -> RpcError {
    log::debug!(
        "event=session.pi_auto_restart_deferred session_id={session_id} shell_id={} error_kind={:?}",
        shell_id.get(),
        error.kind()
    );
    RpcError {
        code: ErrorCode::InternalError,
        message: "Automatic Pi restart is waiting for a safe opportunity; the existing process was not force-stopped."
            .to_owned(),
        data: None,
    }
}

fn pi_restart_rpc_error(session_id: SessionId, shell_id: ShellId, error: io::Error) -> RpcError {
    log::error!(
        "event=session.pi_restart_failed session_id={session_id} shell_id={} error_kind={:?}",
        shell_id.get(),
        error.kind()
    );
    let message = match error.kind() {
        io::ErrorKind::WouldBlock => {
            "Another process holds this Pi's conversation, so Axo did not start a second one. Its history was left untouched."
        }
        io::ErrorKind::TimedOut => "Pi is still starting.",
        io::ErrorKind::NotFound => "This Pi pane is no longer available to restart.",
        _ => "Axo could not restart this Pi session. Its conversation history was preserved.",
    };
    RpcError {
        code: ErrorCode::InternalError,
        message: message.to_owned(),
        data: None,
    }
}

/// Registers an async method that gets axod's core.
fn add<P, R, F, Fut>(
    handler: &mut IoHandler,
    core: &Arc<Core>,
    name: &str,
    expected: &'static str,
    method: F,
) where
    P: serde::de::DeserializeOwned + Send + 'static,
    R: serde::Serialize + 'static,
    F: Fn(Arc<Core>, P) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = Result<R, RpcError>> + Send + 'static,
{
    let core = Arc::clone(core);
    handler.add_typed_async(name, expected, move |request: P| {
        method(Arc::clone(&core), request)
    });
}

impl Extension for Sessions {
    fn name(&self) -> &'static str {
        "sessions"
    }

    fn register(&self, handler: &mut IoHandler) {
        let core = &self.0;
        add(
            handler,
            core,
            method::SESSION_LIST,
            "expected no parameters",
            |core, _: rpc::NoParams| async move {
                Ok(rpc::SessionList {
                    sessions: core.catalog.records(),
                    resume_session_id: core.take_pending_focus(),
                })
            },
        );
        add(
            handler,
            core,
            method::SESSION_CATALOG,
            "expected no parameters",
            |core, _: rpc::NoParams| async move {
                let archived = core
                    .store
                    .call(|database| axo_store::read_archived_sessions(database))
                    .await
                    .map_err(internal_rpc_error)?;
                Ok(rpc::SessionCatalog {
                    sessions: core.catalog.records(),
                    archived,
                })
            },
        );
        add(
            handler,
            core,
            method::CONFIG_GET,
            "expected {key}",
            |core, request: rpc::GetConfig| async move {
                Ok(rpc::ConfigValue {
                    key: request.key,
                    value: core.settings().value(request.key),
                })
            },
        );
        add(
            handler,
            core,
            method::CONFIG_SET,
            "expected {key, value}",
            |core, request: rpc::SetConfig| async move {
                let parsed = ParsedConfigValue::parse(request.key, &request.value)
                    .map_err(|error| invalid_input_or_internal(error, None))?;
                let value = parsed.source();
                let (key, stored) = (request.key, value.clone());
                core.store
                    .call(move |database| axo_store::store_config_value(database, key, &stored))
                    .await
                    .map_err(internal_rpc_error)?;
                parsed.apply(&mut lock(&core.settings));
                Ok(rpc::ConfigValue { key, value })
            },
        );
        add(
            handler,
            core,
            method::SESSION_LAYOUT_SET,
            "expected {sessionId, layout}",
            |core, request: rpc::SetLayout| async move {
                let layout = Layout::try_from(request.layout)
                    .map_err(|_| invalid_params("layout is malformed or exceeds its limits"))?;
                ops::set_layout(&core, request.session_id, layout)
                    .await
                    .map(|()| rpc::Saved { saved: true })
                    .map_err(|error| {
                        invalid_input_or_internal(
                            error,
                            Some("layout must contain each open session shell exactly once"),
                        )
                    })
            },
        );
        add(
            handler,
            core,
            method::TERMINAL_INPUT,
            "expected {sessionId, shellId, sequence, data}",
            |core, request: rpc::TerminalInput| async move {
                ops::write_input(
                    &core,
                    request.session_id,
                    request.shell_id,
                    request.sequence,
                    &request.data,
                )
                .await
                .map(|()| rpc::InputAccepted {
                    accepted: true,
                    sequence: request.sequence,
                })
                .map_err(|error| {
                    invalid_input_or_internal(
                        error,
                        Some("terminal input is invalid or out of sequence"),
                    )
                })
            },
        );
        add(
            handler,
            core,
            method::TERMINAL_RESIZE,
            "expected {sessionId, shellId, rows, columns}",
            |core, request: rpc::TerminalResize| async move {
                let size = WindowSize::new(request.rows, request.columns)
                    .ok_or_else(|| invalid_params("terminal dimensions are invalid"))?;
                ops::resize(&core, request.session_id, request.shell_id, size)
                    .await
                    .map(|()| rpc::ResizeAccepted {
                        accepted: true,
                        rows: request.rows,
                        columns: request.columns,
                    })
                    .map_err(internal_rpc_error)
            },
        );
        add(
            handler,
            core,
            method::CLIENT_VIEWPORT_SET,
            "expected {terminalArea, backingScale, cell, padding, dividerThickness} in range",
            |core, viewport: Viewport| async move {
                crate::sessions::set_viewport(&core, viewport)
                    .await
                    .map(|()| rpc::ViewportAccepted { accepted: true })
                    .map_err(internal_rpc_error)
            },
        );
        add(
            handler,
            core,
            method::SHELL_BUSY,
            "expected {sessionId, shellId}",
            |core, request: rpc::ShellRef| async move {
                ops::busy(&core, request.session_id, request.shell_id)
                    .await
                    .map_err(internal_rpc_error)
            },
        );
        add(
            handler,
            core,
            method::PEER_SESSIONS_LIST,
            "expected no parameters",
            |core, _: rpc::NoParams| async move { core.peers.list(&core).map_err(internal_rpc_error) },
        );
        add(
            handler,
            core,
            method::PEER_SESSION_OPEN,
            "expected {hostId, sessionId}",
            |core, request: rpc::PeerSessionRef| async move {
                crate::peers::Peers::open(&core, &request.host_id, request.session_id).map_err(
                    |error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params(&error.to_string()),
                        _ => internal_rpc_error(error),
                    },
                )
            },
        );
        add(
            handler,
            core,
            method::PEER_SESSION_CLOSE,
            "expected {hostId, sessionId}",
            |core, request: rpc::PeerSessionRef| async move {
                let closed = crate::peers::Peers::close(&core, request.session_id);
                Ok(serde_json::json!({ "closed": closed }))
            },
        );
        add(
            handler,
            core,
            method::PEER_SESSION_WATCH,
            "expected {hostId, sessionId, epoch?, cursor?, version?, timeoutMs?, window?}",
            |core, request: rpc::WatchPeerSession| async move {
                core.peers
                    .watch(&core, request)
                    .await
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params(&error.to_string()),
                        _ => internal_rpc_error(error),
                    })
            },
        );
        add(
            handler,
            core,
            method::PEER_COMMAND,
            "expected {hostId, method, params}",
            |core, request: rpc::PeerCommand| async move {
                core.peers.command(request).await.map_err(|error| RpcError {
                    code: ErrorCode::from(error.code),
                    message: error.message,
                    data: None,
                })
            },
        );
        add(
            handler,
            core,
            method::SESSION_PROMPT,
            "expected {sessionId, text, delivery?: steer|followUp|turn, fromSessionId?}",
            |core, request: rpc::PromptSession| async move {
                crate::sessions::prompt(&core, request, None, Vec::new())
                    .await
                    .map_err(prompt_rpc_error)
            },
        );
        add(
            handler,
            core,
            method::TERMINAL_WRITE,
            "expected {sessionId, shellId, text}",
            |core, request: rpc::WriteTerminal| async move {
                ops::write_text(&core, request.session_id, request.shell_id, request.text)
                    .await
                    .map(|()| rpc::WriteAccepted { accepted: true })
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params("shell is not open"),
                        _ => invalid_input_or_internal(error, None),
                    })
            },
        );
        add(
            handler,
            core,
            method::TERMINAL_SCREEN,
            "expected {sessionId, shellId, lines?: 1 to 10000}",
            |core, request: rpc::ReadTerminalScreen| async move {
                let lines = request.lines.unwrap_or(DEFAULT_SCREEN_LINES);
                if !(1..=MAX_SCREEN_LINES).contains(&lines) {
                    return Err(invalid_params("lines must be 1 to 10000"));
                }
                ops::screen(&core, request.session_id, request.shell_id, lines as usize)
                    .await
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params("shell is not open"),
                        _ => internal_rpc_error(error),
                    })
            },
        );
        add(
            handler,
            core,
            method::SESSION_CREATE,
            "expected {folder} or {like}, or no parameters",
            |core, request: rpc::CreateSession| async move {
                crate::sessions::create(&core, request)
                    .await
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::InvalidInput | io::ErrorKind::NotFound => {
                            invalid_params(&error.to_string())
                        }
                        io::ErrorKind::PermissionDenied => {
                            invalid_params("Axo cannot open that folder")
                        }
                        _ => internal_rpc_error(error),
                    })
            },
        );
        add(
            handler,
            core,
            method::SESSION_CLOSE,
            "expected {sessionId}",
            |core, request: rpc::SessionRef| async move {
                ops::close_session(&core, request.session_id)
                    .await
                    .map(|()| rpc::SessionClosed {
                        archived_session_id: request.session_id,
                    })
                    .map_err(internal_rpc_error)
            },
        );
        add(
            handler,
            core,
            method::SESSION_REOPEN,
            "expected no parameters",
            |core, _: rpc::NoParams| async move {
                crate::sessions::reopen_closed(&core)
                    .await
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => RpcError {
                            code: ErrorCode::ServerError(SESSION_NOT_REOPENED),
                            message: error.to_string(),
                            data: None,
                        },
                        _ => internal_rpc_error(error),
                    })
            },
        );
        add(
            handler,
            core,
            method::SESSION_RENAME,
            "expected {sessionId, name}",
            |core, request: rpc::RenameSession| async move {
                ops::rename(&core, request.session_id, request.name)
                    .await
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Session name is invalid"))
                    })
            },
        );
        add(
            handler,
            core,
            method::SESSION_PI_RESTART_AUTO,
            "expected {sessionId, shellId}",
            |core, request: rpc::ShellRef| async move {
                let rpc::ShellRef {
                    session_id,
                    shell_id,
                } = request;
                ops::restart_unavailable(&core, session_id, shell_id)
                    .await
                    .map_err(|error| automatic_pi_restart_rpc_error(session_id, shell_id, error))
            },
        );
        add(
            handler,
            core,
            method::SESSION_PI_RESTART_FORCE,
            "expected {sessionId, shellId}",
            |core, request: rpc::ShellRef| async move {
                let rpc::ShellRef {
                    session_id,
                    shell_id,
                } = request;
                ops::restart_unavailable(&core, session_id, shell_id)
                    .await
                    .map_err(|error| pi_restart_rpc_error(session_id, shell_id, error))
            },
        );
        add(
            handler,
            core,
            method::SHELL_CREATE,
            "expected {sessionId}",
            |core, request: rpc::SessionRef| async move {
                ops::create_shell(&core, request.session_id)
                    .await
                    .map_err(internal_rpc_error)
            },
        );
        add(
            handler,
            core,
            method::SHELL_CLOSE,
            "expected {sessionId, shellId}",
            |core, request: rpc::ShellRef| async move {
                ops::close_shell(&core, request.session_id, request.shell_id)
                    .await
                    .map_err(internal_rpc_error)
            },
        );
    }
}
