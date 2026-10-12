//! Durable unsent input, not Pi history or execution authority. The frontend
//! edits a buffer; this owner provides revision-fenced saves without merging.
use super::{Database, Error, parse_id};
use crate::{model::*, pi_control::ChatId};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const MAX_CONVERSATIONS: u32 = 32;
const MAX_TEXT: usize = 64 * 1024;
const MAX_TOTAL_TEXT: u64 = 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DraftAddress {
    pub machine_id: MachineId,
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
    pub pane_id: PaneId,
    pub chat_id: ChatId,
}
impl DraftAddress {
    fn encoded(self) -> Result<Vec<u8>, Error> {
        serde_json::to_vec(&self).map_err(|_| Error::Invalid)
    }
    fn key(self) -> Result<[u8; 32], Error> {
        Ok(Sha256::digest(self.encoded()?).into())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DraftRevision(#[serde(deserialize_with = "revision")] uuid::Uuid);
fn revision<'de, D: serde::Deserializer<'de>>(d: D) -> Result<uuid::Uuid, D::Error> {
    let id = crate::model::deserialize_uuid(d)?;
    if id.is_nil() {
        return Err(serde::de::Error::custom("Invalid draft revision"));
    }
    Ok(id)
}
impl DraftRevision {
    pub fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}
impl Default for DraftRevision {
    fn default() -> Self {
        Self::new()
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Draft {
    pub address: DraftAddress,
    pub revision: DraftRevision,
    pub text: String,
}
impl Database {
    pub fn draft(&self, address: DraftAddress) -> Result<Option<Draft>, Error> {
        self.available()?;
        self.draft_destination(address)?;
        self.read_draft(address)
    }
    fn read_draft(&self, address: DraftAddress) -> Result<Option<Draft>, Error> {
        let stored = self
            .connection
            .query_row(
                "SELECT scope, revision, text FROM drafts WHERE address=?1",
                [address.key()?.as_slice()],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((scope, revision, text)) = stored else {
            return Ok(None);
        };
        let recorded: DraftAddress = serde_json::from_slice(&scope).map_err(|_| Error::Corrupt)?;
        if recorded != address || text.len() > MAX_TEXT {
            return Err(Error::Corrupt);
        }
        let revision = serde_json::from_value(serde_json::Value::String(revision))
            .map_err(|_| Error::Corrupt)?;
        Ok(Some(Draft {
            address,
            revision,
            text,
        }))
    }
    fn draft_destination(&self, address: DraftAddress) -> Result<(), Error> {
        let machine: String = self.connection.query_row(
            "SELECT machine_id FROM metadata WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        if parse_id::<MachineId>(&machine)? != address.machine_id {
            return Err(Error::Conflict);
        }
        let known: bool = self.connection.query_row("SELECT EXISTS(SELECT 1 FROM sessions s JOIN panes p USING(session_id) WHERE s.session_id=?1 AND s.workspace_id IS ?2 AND p.pane_id=?3 AND p.role='pi')", params![address.session_id.to_string(), address.workspace_id.map(|id| id.to_string()), address.pane_id.to_string()], |row| row.get(0))?;
        if !known {
            return Err(Error::NotFound);
        }
        let chat: Option<String> = self
            .connection
            .query_row(
                "SELECT chat_id FROM pi_bindings WHERE session_id=?1 AND pane_id=?2",
                params![address.session_id.to_string(), address.pane_id.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        if chat.as_deref().map(parse_id::<ChatId>).transpose()? == Some(address.chat_id) {
            return Ok(());
        }
        // A previously acknowledged draft remains saveable under its original
        // logical scope after execution stops/switches. It is not send authority.
        if self.read_draft(address)?.is_some() {
            return Ok(());
        }
        Err(Error::Conflict)
    }
    pub fn save_draft(
        &mut self,
        draft: Draft,
        expected: Option<DraftRevision>,
    ) -> Result<Draft, Error> {
        self.available()?;
        self.draft_destination(draft.address)?;
        if draft.text.len() > MAX_TEXT {
            return Err(Error::Capacity);
        }
        let old = self.read_draft(draft.address)?;
        // Only an exact repeat can observe an already-published save. Neither
        // a reused revision with different text nor an older CAS can overwrite.
        if old.as_ref() == Some(&draft) {
            return Ok(draft);
        }
        if old.as_ref().map(|draft| draft.revision) != expected
            || old
                .as_ref()
                .is_some_and(|old| old.revision == draft.revision)
        {
            return Err(Error::Conflict);
        }
        let key = draft.address.key()?;
        self.mutate(|tx| {
            let count: u32 = tx.query_row("SELECT count(*) FROM drafts", [], |row| row.get(0))?;
            if old.is_none() && count >= MAX_CONVERSATIONS { return Err(Error::Capacity); }
            let total: i64 = tx.query_row("SELECT coalesce(sum(length(CAST(text AS BLOB))),0) FROM drafts", [], |row| row.get(0))?;
            let total = u64::try_from(total).map_err(|_| Error::Corrupt)?;
            let previous = old.as_ref().map_or(0, |draft| draft.text.len() as u64);
            let remaining = total.checked_sub(previous).ok_or(Error::Corrupt)?;
            if remaining + draft.text.len() as u64 > MAX_TOTAL_TEXT { return Err(Error::Capacity); }
            tx.execute("INSERT INTO drafts VALUES(?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(address) DO UPDATE SET revision=excluded.revision, text=excluded.text", params![key.as_slice(), draft.address.encoded()?, draft.address.session_id.to_string(), draft.address.pane_id.to_string(), draft.revision.0.to_string(), draft.text])?;
            Ok(draft)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{state::ApprovedDirectory, test_support::TestDirectory};
    fn address(database: &mut Database, root: &TestDirectory, machine: MachineId) -> DraftAddress {
        let session = database
            .create_workspace(
                CommandId::new(),
                database.revision().unwrap(),
                "Workspace",
                &ApprovedDirectory::local_selection(root.path()).unwrap(),
            )
            .unwrap()
            .graph
            .initial_session;
        let chat: ChatId = serde_json::from_value(serde_json::json!(uuid::Uuid::new_v4())).unwrap();
        let address = DraftAddress {
            machine_id: machine,
            workspace_id: session.session.workspace_id,
            session_id: session.session.session_id,
            pane_id: session.panes[0].pane_id,
            chat_id: chat,
        };
        let text = serde_json::to_value(chat)
            .unwrap()
            .as_str()
            .unwrap()
            .to_owned();
        // Fixture binding metadata only: this test makes no admission/writer claim.
        database.mutate(|tx| { tx.execute("INSERT INTO pi_bindings VALUES(?1, ?2, ?3, '/fixture/session.jsonl', '/fixture', ?4)", params![address.session_id.to_string(), address.pane_id.to_string(), text, CommandId::new().to_string()])?; Ok(()) }).unwrap();
        address
    }
    #[test]
    fn draft_survives_backend_restart_and_never_advances_catalog() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        let address = address(&mut database, &root, machine);
        let draft = Draft {
            address,
            revision: DraftRevision::new(),
            text: "Unsent voice transcript".into(),
        };
        assert_eq!(database.save_draft(draft.clone(), None).unwrap(), draft);
        assert_eq!(database.save_draft(draft.clone(), None).unwrap(), draft);
        assert_eq!(database.revision().unwrap(), 1);
        drop(database);
        let restored = Database::open(root.path(), machine).unwrap();
        assert_eq!(restored.draft(address).unwrap(), Some(draft));
    }
    #[test]
    fn stale_edit_and_late_clear_cannot_overwrite_newer_input() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        let address = address(&mut database, &root, machine);
        let first = Draft {
            address,
            revision: DraftRevision::new(),
            text: "First".into(),
        };
        database.save_draft(first.clone(), None).unwrap();
        let newer = Draft {
            address,
            revision: DraftRevision::new(),
            text: "Newer edit".into(),
        };
        database
            .save_draft(newer.clone(), Some(first.revision))
            .unwrap();
        let clear = Draft {
            address,
            revision: DraftRevision::new(),
            text: String::new(),
        };
        assert_eq!(
            database.save_draft(clear, Some(first.revision)),
            Err(Error::Conflict)
        );
        let reused = Draft {
            text: "Changed revision reuse".into(),
            ..newer.clone()
        };
        assert_eq!(
            database.save_draft(reused, Some(newer.revision)),
            Err(Error::Conflict)
        );
        assert_eq!(database.draft(address).unwrap(), Some(newer));
    }
    #[test]
    fn aggregate_text_and_slot_capacity_preserve_existing_drafts() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        let mut saved = Vec::new();
        for _ in 0..16 {
            let address = address(&mut database, &root, machine);
            let draft = Draft {
                address,
                revision: DraftRevision::new(),
                text: "x".repeat(MAX_TEXT),
            };
            database.save_draft(draft.clone(), None).unwrap();
            saved.push(draft);
        }
        let next = address(&mut database, &root, machine);
        let excess = Draft {
            address: next,
            revision: DraftRevision::new(),
            text: "not truncated".into(),
        };
        assert_eq!(database.save_draft(excess, None), Err(Error::Capacity));
        for draft in &saved {
            assert_eq!(database.draft(draft.address).unwrap(), Some(draft.clone()));
        }
        for draft in &saved {
            database
                .save_draft(
                    Draft {
                        address: draft.address,
                        revision: DraftRevision::new(),
                        text: String::new(),
                    },
                    Some(draft.revision),
                )
                .unwrap();
        }
        for _ in 16..32 {
            let address = address(&mut database, &root, machine);
            database
                .save_draft(
                    Draft {
                        address,
                        revision: DraftRevision::new(),
                        text: "kept".into(),
                    },
                    None,
                )
                .unwrap();
        }
        assert_eq!(
            database.save_draft(
                Draft {
                    address: next,
                    revision: DraftRevision::new(),
                    text: "over slots".into()
                },
                None
            ),
            Err(Error::Capacity)
        );
        assert_eq!(database.draft(next).unwrap(), None);
    }
    #[test]
    fn input_bounds_reject_without_truncation_or_eviction() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        let address = address(&mut database, &root, machine);
        let oversized = Draft {
            address,
            revision: DraftRevision::new(),
            text: "x".repeat(MAX_TEXT + 1),
        };
        assert_eq!(database.save_draft(oversized, None), Err(Error::Capacity));
        assert_eq!(database.draft(address).unwrap(), None);
        let wrong = DraftAddress {
            machine_id: MachineId::new(),
            ..address
        };
        assert_eq!(database.draft(wrong), Err(Error::Conflict));
        let wrong = DraftAddress {
            session_id: SessionId::new(),
            ..address
        };
        assert_eq!(database.draft(wrong), Err(Error::NotFound));
        let wrong = DraftAddress {
            chat_id: serde_json::from_value(serde_json::json!(uuid::Uuid::new_v4())).unwrap(),
            ..address
        };
        assert_eq!(database.draft(wrong), Err(Error::Conflict));
    }
}
