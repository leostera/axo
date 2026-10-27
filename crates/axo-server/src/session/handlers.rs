//! The JSON-RPC surface: local methods, the relay's host adapter, and mapping errors to RPC codes.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use super::SessionManager;
use super::events::SharedEvent;
use axo_ipc::TypedMethods;
use axo_pi::takeover::TakeoverPolicy;
use axo_protocol::rpc::{self, method};
use axo_protocol::{
    Event, Layout, LayoutNode, RelayStatus, RemoteSessionSnapshot, SessionId, SessionRecord,
    ShellId, Viewport,
};
use axo_pty::WindowSize;
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};

/// Exposes the session manager to the cloud relay.
pub(crate) struct RelayHostAdapter(pub(crate) Arc<SessionManager>);

impl RelayHostAdapter {
    fn remote(&self, session: &SessionRecord, updated_at: &str) -> RemoteSessionSnapshot {
        RemoteSessionSnapshot::from_record(session, &self.0.host_id, updated_at)
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

impl axo_relay::RelayHost for RelayHostAdapter {
    fn host_id(&self) -> &str {
        &self.0.host_id
    }

    fn host_generation(&self) -> &str {
        &self.0.host_generation
    }

    fn publish_relay_status(&self, status: &RelayStatus) {
        self.0.publish_event(Event::RelayStatus {
            status: status.clone(),
        });
    }

    fn remote_session_snapshots(&self, updated_at: &str) -> io::Result<Vec<RemoteSessionSnapshot>> {
        let sessions = self.0.list_sessions()?;
        if sessions.len() > 256 || sessions.iter().any(|session| session.shells.len() > 256) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "host session snapshot exceeds the protocol limit",
            ));
        }
        Ok(sessions
            .iter()
            .map(|session| self.remote(session, updated_at))
            .collect())
    }

    fn subscribe_remote_events(&self) -> io::Result<String> {
        self.0.subscribe(None, true)
    }

    fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Event>> {
        Ok(self
            .0
            .next_event(subscription_id, timeout)?
            .map(Arc::unwrap_or_clone))
    }

    fn remote_resync_events(&self) -> io::Result<Vec<Event>> {
        Ok(self
            .0
            .list_sessions()?
            .into_iter()
            .map(Event::snapshot)
            .collect())
    }

    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()> {
        self.0.unsubscribe(subscription_id)
    }

    fn remote_create_session(&self, updated_at: &str) -> io::Result<RemoteSessionSnapshot> {
        let session = self.0.create_session_and_publish()?;
        Ok(self.remote(&session, updated_at))
    }

    fn remote_create_workspace_session(
        &self,
        workspace_id: &str,
        updated_at: &str,
    ) -> io::Result<RemoteSessionSnapshot> {
        let session = self.0.create_session_in_workspace(workspace_id)?;
        Ok(self.remote(&session, updated_at))
    }

    fn remote_close_session(
        &self,
        session_id: SessionId,
        updated_at: &str,
    ) -> io::Result<Option<RemoteSessionSnapshot>> {
        let replacement = self.0.close_session_and_publish(session_id)?;
        Ok(replacement.map(|session| self.remote(&session, updated_at)))
    }

    fn remote_workspaces(&self) -> io::Result<Vec<axo_protocol::RemoteWorkspace>> {
        Ok(self
            .0
            .list_workspaces()?
            .iter()
            .map(axo_protocol::RemoteWorkspace::from)
            .collect())
    }

    fn remote_rename_session(&self, session_id: SessionId, name: &str) -> io::Result<()> {
        self.0.rename_session(session_id, name).map(drop)
    }

    fn remote_create_shell(&self, session_id: SessionId) -> io::Result<ShellId> {
        Ok(self.0.create_shell_and_publish(session_id)?.id)
    }

    fn remote_close_shell(&self, session_id: SessionId, shell_id: ShellId) -> io::Result<()> {
        self.0
            .close_shell_and_publish(session_id, shell_id)
            .map(drop)
    }

    fn remote_set_layout(&self, session_id: SessionId, layout: LayoutNode) -> io::Result<()> {
        let layout = Layout::try_from(layout)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        self.0.set_layout_and_publish(session_id, layout)
    }

    fn remote_terminal_input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        data: &str,
    ) -> io::Result<()> {
        self.0
            .write_terminal_input(session_id, shell_id, sequence, data)
    }

    fn remote_prompt_pi(&self, session_id: SessionId, text: &str) -> io::Result<()> {
        self.0.prompt_pi(session_id, text)
    }

    fn remote_press_pi_key(&self, session_id: SessionId, key: axo_relay::PiKey) -> io::Result<()> {
        self.0.press_pi_key(session_id, key)
    }

    fn remote_terminal_resize(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        rows: u32,
        columns: u32,
    ) -> io::Result<()> {
        let size = WindowSize::new(rows, columns).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal dimensions are outside the supported range",
            )
        })?;
        self.0.resize_terminal(session_id, shell_id, size)
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
        session_id.get(),
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
        session_id.get(),
        shell_id.get(),
        error.kind()
    );
    let message = match error.kind() {
        io::ErrorKind::ConnectionRefused => {
            "The previous Pi process is not accepting control connections. Its transcript was left untouched."
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
            method::SESSION_SUBSCRIBE,
            "expected {sessionId?, includeTerminalOutput?}",
            move |request: rpc::Subscribe| {
                manager
                    .subscribe(request.session_id, request.include_terminal_output)
                    .map(|subscription_id| rpc::Subscribed { subscription_id })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        // Long-polls wait as futures, never on a thread (see `axo_ipc`).
        handler.add_typed_async(
            method::SESSION_EVENTS_NEXT,
            "expected {subscriptionId, timeoutMs, maxEvents?}",
            move |request: rpc::NextEvents| {
                let manager = Arc::clone(&manager);
                async move { manager.next_events_for_rpc(request).await }
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_UNSUBSCRIBE,
            "expected {subscriptionId}",
            move |request: rpc::Unsubscribe| {
                manager
                    .unsubscribe(&request.subscription_id)
                    .map(|()| rpc::Unsubscribed { unsubscribed: true })
                    .map_err(internal_rpc_error)
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

    async fn next_events_for_rpc(
        &self,
        request: rpc::NextEvents,
    ) -> Result<rpc::EventsNext<SharedEvent>, RpcError> {
        if !(1..=rpc::MAX_EVENTS_TIMEOUT_MS).contains(&request.timeout_ms) {
            return Err(invalid_params("timeoutMs must be between 1 and 20000"));
        }
        let max_events = match request.max_events {
            None => 1,
            Some(max_events) if (1..=rpc::MAX_EVENTS_PER_POLL).contains(&max_events) => max_events,
            Some(_) => return Err(invalid_params("maxEvents must be between 1 and 256")),
        };
        let timeout = Duration::from_millis(request.timeout_ms);
        let events = self
            .next_events_async(&request.subscription_id, timeout, max_events)
            .await
            .map_err(internal_rpc_error)?
            .into_iter()
            .map(SharedEvent);
        Ok(match request.max_events {
            None => rpc::EventsNext::Single {
                event: events.into_iter().next(),
            },
            Some(_) => rpc::EventsNext::Batch {
                events: events.collect(),
            },
        })
    }
}
