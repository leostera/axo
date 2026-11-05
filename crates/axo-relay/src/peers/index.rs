//! The other Macs and their Sessions, as the cloud last listed them.

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::mirror::write_atomically;

/// The other Macs and their Sessions, as the cloud last listed them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PeerIndex {
    pub hosts: Vec<Value>,
    pub sessions: Vec<Value>,
}

impl PeerIndex {
    /// Takes Sessions in, replacing those with the same host and id.
    pub(super) fn merge(&mut self, sessions: &[Value]) {
        for session in sessions {
            let key = session_key(session);
            match self
                .sessions
                .iter_mut()
                .find(|known| session_key(known) == key)
            {
                Some(known) => *known = session.clone(),
                None => self.sessions.push(session.clone()),
            }
        }
    }

    /// What the account lists, for this Mac's catalog. It is this Mac's server state, so it is
    /// kept in `server/`, not with the copies.
    pub(super) fn write(&self, path: &Path) -> io::Result<()> {
        if let Some(folder) = path.parent() {
            fs::create_dir_all(folder)?;
        }
        write_atomically(
            path,
            &serde_json::to_vec_pretty(self).map_err(io::Error::other)?,
        )
    }
}

fn session_key(session: &Value) -> (Option<&str>, Option<&str>) {
    (session["hostId"].as_str(), session["sessionId"].as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    use crate::peers::test_support::{HOST, SESSION};

    #[test]
    fn the_index_keeps_the_latest_listing_of_each_session() {
        let mut index = PeerIndex::default();
        index.merge(&[json!({ "hostId": HOST, "sessionId": SESSION, "head": 1 })]);
        index.merge(&[
            json!({ "hostId": HOST, "sessionId": SESSION, "head": 4 }),
            json!({ "hostId": HOST, "sessionId": "other", "head": 1 }),
        ]);
        assert_eq!(index.sessions.len(), 2);
        assert_eq!(index.sessions[0]["head"], 4);
    }
}
