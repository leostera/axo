//! Typed Session mutations, invoked only by an explicit UI/action owner. No retries.
use crate::{Client, Error, catalog};
use axo_protocol::{Availability, PaneRole, SessionId, SessionRecord, ShellId, rpc};

impl Client {
    /// Create once. The caller owns the deadline and must reconcile an uncertain result
    /// before allowing another creation; reconnecting must never replay this request.
    pub async fn create_session(
        &mut self,
        request: rpc::CreateSession,
    ) -> Result<SessionRecord, Error> {
        let source = match &request {
            rpc::CreateSession::InFolder(path) if !path.is_absolute() => {
                return Err(Error::Input(
                    "a Session's folder must be an absolute path".into(),
                ));
            }
            rpc::CreateSession::Like(id) => Some(*id),
            _ => None,
        };
        let params = serde_json::to_value(request)
            .map_err(|_| Error::Input("Session creation parameters cannot be encoded".into()))?;
        let record = self.call_typed(rpc::method::SESSION_CREATE, params).await?;
        let record = self.check_session_response(record)?;
        if source == Some(record.id) {
            return Err(
                self.invalid_response("Session creation returned its existing source Session")
            );
        }
        Ok(record)
    }

    /// Wake through the advertised automatic, unavailable-only endpoint. There is no
    /// force/legacy fallback. Native UI additionally restricts automatic calls to its
    /// foreground selected Dormant Pi; this client never infers focus or retries.
    pub async fn wake_pi(
        &mut self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> Result<SessionRecord, Error> {
        let params = serde_json::to_value(rpc::ShellRef {
            session_id,
            shell_id,
        })
        .expect("typed IDs serialize");
        let record = self
            .call_typed(rpc::method::SESSION_PI_RESTART_AUTO, params)
            .await?;
        let record = self.check_session_response(record)?;
        if record.id != session_id
            || !record.shells.iter().any(|shell| {
                shell.id == shell_id
                    && shell.role == PaneRole::Pi
                    && shell.availability == Availability::Available
                    && shell.process_id > 0
            })
        {
            return Err(self.invalid_response("daemon did not restore the requested Pi pane"));
        }
        Ok(record)
    }

    fn check_session_response(&mut self, record: SessionRecord) -> Result<SessionRecord, Error> {
        let record = catalog::validated_record(record)
            .map_err(|error| self.invalid_response(error.to_string()))?;
        if !record.folder.is_absolute() {
            return Err(self.invalid_response("daemon returned a relative Session folder"));
        }
        Ok(record)
    }
}
