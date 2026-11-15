//! A local catalog safe to bind to native pane widgets, not a second catalog/store.
use crate::{Client, Error};
use axo_protocol::{SessionId, SessionRecord, ShellId, rpc};
use std::collections::HashSet;

pub struct LocalCatalog(rpc::SessionCatalog);
impl LocalCatalog {
    pub async fn load(client: &mut Client) -> Result<Self, Error> {
        let wire: rpc::SessionCatalog = client
            .call_typed(rpc::method::SESSION_CATALOG, serde_json::json!({}))
            .await?;
        Self::try_from(wire)
    }
    pub fn sessions(&self) -> &[SessionRecord] {
        &self.0.sessions
    }
    pub fn session(&self, id: SessionId) -> Option<&SessionRecord> {
        self.0.sessions.iter().find(|session| session.id == id)
    }
    pub fn archived(&self) -> &[rpc::ArchivedSessionRecord] {
        &self.0.archived
    }
}
impl TryFrom<rpc::SessionCatalog> for LocalCatalog {
    type Error = Error;
    fn try_from(wire: rpc::SessionCatalog) -> Result<Self, Error> {
        let mut sessions = HashSet::new();
        let mut shells = HashSet::<ShellId>::new();
        for session in &wire.sessions {
            if !sessions.insert(session.id) {
                return Err(invalid("duplicate Session identity"));
            }
            let mut owned = HashSet::new();
            for shell in &session.shells {
                if !shells.insert(shell.id) {
                    return Err(invalid("duplicate pane identity"));
                }
                owned.insert(shell.id);
                // Relative daemon paths depend on its CWD, not the frontend's. Never
                // resolve them against an unrelated directory and attach elsewhere.
                if !shell.attach_socket_path.is_absolute() {
                    return Err(invalid("pane attach socket must be absolute"));
                }
            }
            if session
                .layout
                .as_ref()
                .is_some_and(|layout| !layout.shell_ids().is_subset(&owned))
            {
                return Err(invalid("layout references a pane outside its Session"));
            }
        }
        for session in &wire.archived {
            if !sessions.insert(session.id) {
                return Err(invalid("duplicate Session identity"));
            }
        }
        Ok(Self(wire))
    }
}
fn invalid(reason: &str) -> Error {
    Error::Transport(format!("invalid local daemon catalog: {reason}"))
}
