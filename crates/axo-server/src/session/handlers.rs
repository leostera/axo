//! The JSON-RPC surface: local methods, the relay's host adapter, and mapping errors to RPC codes.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use super::SessionManager;
use super::prompts::PromptError;
use axo_agent::takeover::TakeoverPolicy;
use axo_ipc::TypedMethods;
use axo_protocol::rpc::{self, method};
use axo_protocol::{Event, Layout, RelayStatus, SessionId, ShellId, Viewport};
use axo_pty::WindowSize;
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};

/// Exposes the session manager to the cloud relay, and answers the account's calls with axod's
/// own methods (`remote`), set once they are assembled.
pub(crate) struct RelayHostAdapter(
    pub(crate) Arc<SessionManager>,
    std::sync::OnceLock<IoHandler>,
);

impl RelayHostAdapter {
    pub(crate) fn new(manager: Arc<SessionManager>) -> Self {
        Self(manager, std::sync::OnceLock::new())
    }

    /// The methods the account's calls are answered with: axod's, as the relay's caller.
    pub(crate) fn answer_with(&self, methods: IoHandler) {
        let _ = self.1.set(methods);
    }
}

impl axo_relay::HostLinkStore for RelayHostAdapter {
    fn load_link(&self) -> io::Result<axo_relay::HostLink> {
        self.0.host_link()
    }

    fn save_link(&self, link: &axo_relay::HostLink) -> io::Result<()> {
        self.0.store_host_link(link)
    }
}

/// Local events the relay takes in one wait.
const REMOTE_EVENTS_PER_WAIT: usize = 64;

impl axo_relay::RelayHost for RelayHostAdapter {
    fn host_id(&self) -> &str {
        &self.0.host_id
    }

    fn host_generation(&self) -> &str {
        &self.0.host_generation
    }

    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        self.0.pending_elicitations()
    }

    fn resolve_elicitation(
        &self,
        id: &str,
        answer: axo_protocol::elicitation::ElicitationAnswer,
        sealed: Option<axo_protocol::elicitation::Sealed>,
        device: Option<axo_protocol::elicitation::DeviceProof>,
    ) -> Result<(), (i64, String)> {
        self.0
            .check_answer(id, answer, sealed.as_ref(), device.as_ref())?;
        let reply = sealed.map_or(
            axo_protocol::elicitation::Reply::Bare,
            axo_protocol::elicitation::Reply::Sealed,
        );
        self.0.resolve_elicitation(id, answer, reply)
    }

    fn remote_computer(
        &self,
        request: &axo_relay::computer::ComputerParams,
    ) -> Result<serde_json::Value, (i64, String)> {
        self.0.remote_computer(request)
    }

    fn computer_status(&self) -> serde_json::Value {
        self.0.computer_status()
    }

    fn set_asset_source(&self, source: Option<axo_relay::assets::AssetSource>) {
        self.0.set_asset_source(source);
    }

    fn publish_relay_status(&self, status: &RelayStatus) {
        self.0.publish_event(Event::RelayStatus {
            status: status.clone(),
        });
    }

    fn sync_catalog(&self) -> io::Result<Vec<axo_relay::SyncSession>> {
        let catalog = self.0.session_catalog()?;
        let in_cloud: std::collections::HashSet<String> = self
            .0
            .sync_states()?
            .into_iter()
            .filter(|state| state.in_cloud)
            .map(|state| state.session_id)
            .collect();
        let open = catalog.sessions.into_iter().map(|session| {
            let workspace_state = self.0.workspace_states.get(session.id);
            if workspace_state.is_none() {
                // Not read since axod started: read it once now, for the next round.
                self.0
                    .workspace_states
                    .refresh(session.id, session.initial_pwd.clone());
            }
            axo_relay::SyncSession {
                session_id: session.id,
                metadata: axo_relay::SessionMetadata {
                    name: Some(
                        session
                            .manual_name
                            .clone()
                            .unwrap_or_else(|| session.name.clone()),
                    ),
                    emoji: session.emoji.clone(),
                    workspace_id: session.workspace_id.clone(),
                    workspace_name: session.workspace_name.clone(),
                    has_agent: session.has_agent(),
                    created_at: (session.created_at > 0).then_some(session.created_at),
                    last_message_at: session.last_message_at,
                    archived: false,
                    workspace_state,
                    pi: session.pi.clone(),
                },
                status: Some(session.status),
                transcript_in_cloud: in_cloud.contains(&session.id.to_string()),
                pi_session_file: session.pi_session_file,
            }
        });
        let archived = catalog
            .archived
            .into_iter()
            .map(|session| axo_relay::SyncSession {
                session_id: session.id,
                metadata: axo_relay::SessionMetadata {
                    name: Some(session.name),
                    emoji: session.emoji,
                    workspace_id: session.workspace_id,
                    workspace_name: session.workspace_name,
                    has_agent: session.pi_session_file.is_some(),
                    created_at: None,
                    last_message_at: session.last_message_at,
                    archived: true,
                    workspace_state: None,
                    pi: None,
                },
                status: None,
                transcript_in_cloud: in_cloud.contains(&session.id.to_string()),
                pi_session_file: session.pi_session_file,
            });
        Ok(open.chain(archived).collect())
    }

    fn sync_states(&self) -> io::Result<Vec<axo_relay::StoredSyncState>> {
        Ok(self
            .0
            .sync_states()?
            .into_iter()
            .map(|state| axo_relay::StoredSyncState {
                session_id: state.session_id,
                position: state.position,
                chain: state.chain,
                metadata_json: state.metadata_json,
                metadata_version: state.metadata_version,
                in_cloud: state.in_cloud,
            })
            .collect())
    }

    fn store_sync_cursor(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
    ) -> io::Result<()> {
        self.0.store_sync_cursor(session_id, position, chain)
    }

    fn store_sync_metadata(
        &self,
        session_id: SessionId,
        metadata_json: &str,
        version: u64,
    ) -> io::Result<()> {
        self.0
            .store_sync_metadata(session_id, metadata_json, version)
    }

    fn evict_transcript(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
        length: u64,
    ) -> io::Result<bool> {
        self.0.evict_transcript(session_id, position, chain, length)
    }

    fn next_sync_round(&self) -> io::Result<u64> {
        self.0.next_sync_round()
    }

    fn subscribe_remote_events(&self) -> io::Result<String> {
        self.0.subscribe(None, true)
    }

    fn next_remote_events<'a>(
        &'a self,
        subscription_id: &'a str,
        timeout: Duration,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Vec<Event>>> + Send + 'a>>
    {
        Box::pin(async move {
            let events = self
                .0
                .next_events_async(subscription_id, timeout, REMOTE_EVENTS_PER_WAIT)
                .await?;
            Ok(events.into_iter().map(Arc::unwrap_or_clone).collect())
        })
    }

    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()> {
        self.0.unsubscribe(subscription_id)
    }

    fn answer_remote(&self, request: serde_json::Value) -> Option<serde_json::Value> {
        let reply = match self.1.get() {
            Some(methods) => {
                let request = request.to_string();
                axo_ipc::peer::as_relay(|| methods.handle_request_sync(&request))?
            }
            None => {
                // A call that arrives while axod is still assembling its methods.
                return Some(serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": request.get("id").cloned().unwrap_or_default(),
                    "error": { "code": -32003, "message": "Operation failed" },
                }));
            }
        };
        serde_json::from_str(&reply).ok()
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

/// `axo.session.reopen` found no closed Session it could reopen.
const SESSION_NOT_REOPENED: i64 = -32005;

const DEFAULT_SCREEN_LINES: u32 = 200;
const MAX_SCREEN_LINES: u32 = 10_000;

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

fn invalid_params(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message: message.to_owned(),
        data: None,
    }
}

fn internal_rpc_error(error: io::Error) -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
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
        "event=session.pi_auto_restart_deferred session_id={} shell_id={} error_kind={:?}",
        session_id,
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
        "event=session.pi_restart_failed session_id={} shell_id={} error_kind={:?}",
        session_id,
        shell_id.get(),
        error.kind()
    );
    let message = match error.kind() {
        io::ErrorKind::ConnectionRefused => {
            "The previous Pi process is not accepting control apps. Its transcript was left untouched."
        }
        io::ErrorKind::PermissionDenied => {
            "Axo could not verify the previous Pi process for this pane, so it was not terminated."
        }
        io::ErrorKind::WouldBlock => {
            "Axo could not establish safe control of the previous Pi process, so it was not terminated."
        }
        io::ErrorKind::TimedOut => {
            "Axo could not acquire the Pi conversation lock after stopping the pane's process. Its history was left untouched."
        }
        io::ErrorKind::NotFound => "This Pi pane is no longer available to restart.",
        _ => "Axo could not restart this Pi session. Its conversation history was preserved.",
    };
    RpcError {
        code: ErrorCode::InternalError,
        message: message.to_owned(),
        data: None,
    }
}

impl SessionManager {
    pub fn register_rpc_methods(self: &Arc<Self>, handler: &mut IoHandler) {
        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_LIST,
            "expected no parameters",
            move |_: rpc::NoParams| {
                let sessions = manager.list_sessions().map_err(internal_rpc_error)?;
                let resume_session_id = manager
                    .take_pending_resume_focus()
                    .map_err(internal_rpc_error)?;
                Ok(rpc::SessionList {
                    sessions,
                    resume_session_id,
                })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::CONFIG_GET,
            "expected {key}",
            move |request: rpc::GetConfig| Ok(manager.config_value(request.key)),
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::CONFIG_SET,
            "expected {key, value}",
            move |request: rpc::SetConfig| {
                manager
                    .set_config_value(request.key, &request.value)
                    .map_err(|error| invalid_input_or_internal(error, None))
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_LAYOUT_SET,
            "expected {sessionId, layout}",
            move |request: rpc::SetLayout| {
                let layout = Layout::try_from(request.layout)
                    .map_err(|_| invalid_params("layout is malformed or exceeds its limits"))?;
                manager
                    .set_layout_and_publish(request.session_id, layout)
                    .map(|()| rpc::Saved { saved: true })
                    .map_err(|error| {
                        invalid_input_or_internal(
                            error,
                            Some("layout must contain each open session shell exactly once"),
                        )
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::TERMINAL_INPUT,
            "expected {sessionId, shellId, sequence, data}",
            move |request: rpc::TerminalInput| {
                manager
                    .write_terminal_input(
                        request.session_id,
                        request.shell_id,
                        request.sequence,
                        &request.data,
                    )
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

        let manager = Arc::clone(self);
        handler.add_typed(
            method::TERMINAL_RESIZE,
            "expected {sessionId, shellId, rows, columns}",
            move |request: rpc::TerminalResize| {
                let size = WindowSize::new(request.rows, request.columns)
                    .ok_or_else(|| invalid_params("terminal dimensions are invalid"))?;
                manager
                    .resize_terminal(request.session_id, request.shell_id, size)
                    .map(|()| rpc::ResizeAccepted {
                        accepted: true,
                        rows: request.rows,
                        columns: request.columns,
                    })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::CLIENT_VIEWPORT_SET,
            "expected {terminalArea, backingScale, cell, padding, dividerThickness} in range",
            move |viewport: Viewport| {
                manager
                    .set_viewport(viewport)
                    .map(|()| rpc::ViewportAccepted { accepted: true })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SHELL_BUSY,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                manager
                    .shell_busy(request.session_id, request.shell_id)
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_LIST,
            "expected no parameters",
            move |_: rpc::NoParams| {
                manager
                    .list_workspaces()
                    .map(|workspaces| rpc::WorkspaceList { workspaces })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::PEER_SESSIONS_LIST,
            "expected no parameters",
            move |_: rpc::NoParams| manager.peer_sessions().map_err(internal_rpc_error),
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::PEER_SESSION_OPEN,
            "expected {hostId, sessionId}",
            move |request: rpc::PeerSessionRef| {
                manager
                    .open_peer_session(&request.host_id, request.session_id)
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params(&error.to_string()),
                        _ => internal_rpc_error(error),
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::PEER_SESSION_CLOSE,
            "expected {hostId, sessionId}",
            move |request: rpc::PeerSessionRef| {
                manager
                    .close_peer_session(request.session_id)
                    .map(|closed| serde_json::json!({ "closed": closed }))
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::PEER_SESSION_WATCH,
            "expected {hostId, sessionId, epoch?, cursor?, version?, timeoutMs?, window?}",
            move |request: rpc::WatchPeerSession| {
                manager
                    .watch_peer_session(&request)
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params(&error.to_string()),
                        _ => internal_rpc_error(error),
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::PEER_COMMAND,
            "expected {hostId, method, params}",
            move |request: rpc::PeerCommand| {
                manager.peer_command(request).map_err(|error| RpcError {
                    code: ErrorCode::from(error.code),
                    message: error.message,
                    data: None,
                })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_CATALOG,
            "expected no parameters",
            move |_: rpc::NoParams| manager.session_catalog().map_err(internal_rpc_error),
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_PROMPT,
            "expected {sessionId, text, delivery?: steer|followUp|turn, fromSessionId?}",
            move |request: rpc::PromptSession| {
                manager.prompt_session(&request).map_err(prompt_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::TERMINAL_WRITE,
            "expected {sessionId, shellId, text}",
            move |request: rpc::WriteTerminal| {
                manager
                    .write_terminal_text(request.session_id, request.shell_id, &request.text)
                    .map(|()| rpc::WriteAccepted { accepted: true })
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params("shell is not open"),
                        _ => invalid_input_or_internal(error, None),
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::TERMINAL_SCREEN,
            "expected {sessionId, shellId, lines?: 1 to 10000}",
            move |request: rpc::ReadTerminalScreen| {
                let lines = request.lines.unwrap_or(DEFAULT_SCREEN_LINES);
                if !(1..=MAX_SCREEN_LINES).contains(&lines) {
                    return Err(invalid_params("lines must be 1 to 10000"));
                }
                manager
                    .terminal_screen(request.session_id, request.shell_id, lines as usize)
                    .map_err(|error| match error.kind() {
                        io::ErrorKind::NotFound => invalid_params("shell is not open"),
                        _ => internal_rpc_error(error),
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_RENAME,
            "expected {workspaceId, name}",
            move |request: rpc::RenameWorkspace| {
                manager
                    .rename_workspace(&request.workspace_id, &request.name)
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Workspace ID or name is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_ARCHIVE,
            "expected {workspaceId}",
            move |request: rpc::WorkspaceRef| {
                manager
                    .archive_workspace(&request.workspace_id)
                    .map(|archived_session_ids| rpc::WorkspaceArchived {
                        archived_workspace_id: request.workspace_id,
                        archived_session_ids,
                    })
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Workspace ID is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_CREATE,
            "expected {name, directoryPath, optional directoryBookmark}",
            move |request: rpc::CreateWorkspace| {
                manager.create_workspace(request).map_err(|error| match error.kind() {
                    io::ErrorKind::InvalidInput => invalid_params(&error.to_string()),
                    io::ErrorKind::NotFound => invalid_params("Workspace directory no longer exists or is unavailable"),
                    io::ErrorKind::PermissionDenied => invalid_params(
                        "Axo cannot access the selected folder; choose it again in the folder picker",
                    ),
                    _ => internal_rpc_error(error),
                })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_SESSION_CREATE,
            "expected {workspaceId}",
            move |request: rpc::WorkspaceRef| {
                manager
                    .create_session_in_workspace(&request.workspace_id)
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Workspace ID is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_CREATE,
            "expected no parameters",
            move |_: rpc::NoParams| {
                manager
                    .create_session_and_publish()
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_CLOSE,
            "expected {sessionId}",
            move |request: rpc::SessionRef| {
                manager
                    .close_session_and_publish(request.session_id)
                    .map(|replacement| rpc::SessionClosed {
                        archived_session_id: request.session_id,
                        replacement,
                    })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_REOPEN,
            "expected no parameters",
            move |_: rpc::NoParams| {
                manager
                    .reopen_closed_session()
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

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_RENAME,
            "expected {sessionId, name}",
            move |request: rpc::RenameSession| {
                manager
                    .rename_session(request.session_id, &request.name)
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Session name is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_PI_RESTART_AUTO,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                let rpc::ShellRef {
                    session_id,
                    shell_id,
                } = request;
                manager
                    .restart_unavailable_pi(
                        session_id,
                        shell_id,
                        TakeoverPolicy::PreserveExistingProcess,
                    )
                    .map_err(|error| automatic_pi_restart_rpc_error(session_id, shell_id, error))
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_PI_RESTART_FORCE,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                let rpc::ShellRef {
                    session_id,
                    shell_id,
                } = request;
                manager
                    .restart_unavailable_pi(
                        session_id,
                        shell_id,
                        TakeoverPolicy::ExplicitUserRestart,
                    )
                    .map_err(|error| pi_restart_rpc_error(session_id, shell_id, error))
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SHELL_CREATE,
            "expected {sessionId}",
            move |request: rpc::SessionRef| {
                manager
                    .create_shell_and_publish(request.session_id)
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SHELL_CLOSE,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                manager
                    .close_shell_and_publish(request.session_id, request.shell_id)
                    .map_err(internal_rpc_error)
            },
        );
    }

    // Catalog commands shared by local RPC and the relay: each performs the change and publishes
    // the events that describe it, so every client sees the same sequence.
}
