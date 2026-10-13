//! Completion-proven central batch deletion. Intents are immutable reservations;
//! a catalog tombstone is published only after every captured runtime has exact
//! durable completion evidence.
use super::{
    Attempt, AttemptPhase, Capture, Database, Error, MAX_OPERATIONS, MAX_REVISION,
    advance_revision, parse_id, parse_revision, sql_revision,
};
use crate::model::*;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const MAX_DELETE_SESSIONS: usize = 32;
const MAX_DELETE_RUNTIMES: usize = crate::terminal::MAX_TERMINALS;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeletionSource {
    pub machine_id: MachineId,
    pub host_generation: HostGeneration,
    pub store_generation: StoreGeneration,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionAddress {
    #[serde(deserialize_with = "required_nullable")]
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
}

fn required_nullable<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDeletionIntent {
    pub target: DeletionSource,
    pub sessions: Vec<SessionAddress>,
    pub expected_revision: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDeletionReceipt {
    pub command_id: CommandId,
    pub intent: SessionDeletionIntent,
    pub runtimes: Vec<RuntimeRef>,
    /// Null means reserved/pending, never permission to repeat a stop effect.
    pub revision: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeletionPreparation {
    Reserved(SessionDeletionReceipt),
    Original(SessionDeletionReceipt),
}

impl Database {
    /// Returns every unresolved latest attempt in the addressed sessions. Old
    /// completed attempts are evidence, not resources that a delete may signal.
    pub(crate) fn deletion_attempts(
        &self,
        addresses: &[SessionAddress],
    ) -> Result<Vec<Attempt>, Error> {
        self.available()?;
        let mut attempts = Vec::new();
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT p.pane_id FROM panes p JOIN sessions s USING(session_id) ORDER BY p.rowid",
        )?;
        let pane_ids = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        for pane_id in pane_ids {
            let pane = parse_id(&pane_id)?;
            let Some(attempt) = self.attempt(pane)? else {
                continue;
            };
            if attempt.phase == AttemptPhase::CompletionProven {
                continue;
            }
            let belongs = addresses
                .iter()
                .any(|address| address.session_id == attempt.runtime.target.session_id);
            if belongs {
                attempts.push(attempt);
            }
        }
        attempts.sort_by_key(|attempt| {
            (
                attempt.runtime.target.session_id,
                attempt.runtime.target.pane_id,
            )
        });
        if attempts.len() > MAX_DELETE_RUNTIMES {
            return Err(Error::Capacity);
        }
        Ok(attempts)
    }

    pub(crate) fn reserve_deletion(
        &mut self,
        command_id: CommandId,
        intent: SessionDeletionIntent,
        runtimes: Vec<RuntimeRef>,
    ) -> Result<DeletionPreparation, Error> {
        self.available()?;
        validate_intent(&intent, &runtimes)?;
        let mut runtimes = runtimes;
        runtimes.sort_by_key(|runtime| (runtime.target.session_id, runtime.target.pane_id));
        let capture = deletion_capture(&intent)?;
        if let Some(original) = self.deletion(command_id)? {
            return if original.intent == intent {
                Ok(DeletionPreparation::Original(original))
            } else {
                Err(Error::Conflict)
            };
        }
        let (machine, generation, revision) = self.deletion_authority()?;
        if intent.target.machine_id != machine
            || intent.target.store_generation != generation
            || intent.expected_revision != revision
        {
            return Err(Error::Conflict);
        }
        let observed = self.deletion_attempts(&intent.sessions)?;
        let expected: Vec<_> = observed
            .into_iter()
            .map(|attempt| attempt.runtime)
            .collect();
        if expected != runtimes {
            return Err(Error::Conflict);
        }
        let intent_bytes = capture.bytes.clone();
        self.mutate(|tx| {
            let collision: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM operations WHERE command_id=?1) OR EXISTS(SELECT 1 FROM submitted_commands WHERE command_id=?1) OR EXISTS(SELECT 1 FROM runtime_attempts WHERE attempt_id=?1) OR EXISTS(SELECT 1 FROM deletion_intents WHERE command_id=?1)",
                [command_id.to_string()],
                |row| row.get(0),
            )?;
            if collision {
                return Err(Error::Conflict);
            }
            let pending: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM deletion_intents i LEFT JOIN deletion_results r USING(command_id) WHERE r.command_id IS NULL)",
                [],
                |row| row.get(0),
            )?;
            if pending {
                return Err(Error::Conflict);
            }
            let current: i64 = tx.query_row(
                "SELECT revision FROM metadata WHERE singleton=1",
                [],
                |row| row.get(0),
            )?;
            if parse_revision(current)? != intent.expected_revision {
                return Err(Error::Conflict);
            }
            let originals: u32 = tx.query_row(
                "SELECT (SELECT count(*) FROM operations) + (SELECT count(*) FROM submitted_commands) + (SELECT count(*) FROM deletion_intents)",
                [],
                |row| row.get(0),
            )?;
            if originals >= MAX_OPERATIONS {
                return Err(Error::Capacity);
            }
            for address in &intent.sessions {
                let found: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id=?1 AND workspace_id IS ?2 AND tombstoned=0)",
                    params![address.session_id.to_string(), address.workspace_id.map(|id| id.to_string())],
                    |row| row.get(0),
                )?;
                if !found {
                    return Err(Error::NotFound);
                }
            }
            tx.execute(
                "INSERT INTO deletion_intents(command_id,fingerprint,capture,runtimes) VALUES(?1,?2,?3,?4)",
                params![command_id.to_string(), capture.fingerprint.as_slice(), intent_bytes, serde_json::to_vec(&runtimes).map_err(|_| Error::Invalid)?],
            )?;
            for address in &intent.sessions {
                tx.execute(
                    "INSERT INTO deletion_targets(command_id,session_id,workspace_id) VALUES(?1,?2,?3)",
                    params![command_id.to_string(), address.session_id.to_string(), address.workspace_id.map(|id| id.to_string())],
                )?;
            }
            Ok(())
        })?;
        Ok(DeletionPreparation::Reserved(SessionDeletionReceipt {
            command_id,
            intent,
            runtimes,
            revision: None,
        }))
    }

    pub(crate) fn deletion(
        &self,
        command_id: CommandId,
    ) -> Result<Option<SessionDeletionReceipt>, Error> {
        self.available()?;
        let row = self.connection.query_row(
            "SELECT i.fingerprint,i.capture,i.runtimes,r.accepted_revision FROM deletion_intents i LEFT JOIN deletion_results r USING(command_id) WHERE i.command_id=?1",
            [command_id.to_string()],
            |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?, row.get::<_, Vec<u8>>(2)?, row.get::<_, Option<i64>>(3)?)),
        ).optional()?;
        row.map(
            |(stored_fingerprint, capture_bytes, runtime_bytes, accepted_revision)| {
                let intent: SessionDeletionIntent =
                    serde_json::from_slice(&capture_bytes).map_err(|_| Error::Corrupt)?;
                let capture = deletion_capture(&intent).map_err(|_| Error::Corrupt)?;
                let runtimes: Vec<RuntimeRef> =
                    serde_json::from_slice(&runtime_bytes).map_err(|_| Error::Corrupt)?;
                if capture.bytes != capture_bytes
                    || capture.fingerprint != stored_fingerprint.as_slice()
                {
                    return Err(Error::Corrupt);
                }
                validate_intent(&intent, &runtimes).map_err(|_| Error::Corrupt)?;
                self.validate_deletion_targets(command_id, &intent)?;
                let revision = accepted_revision.map(parse_revision).transpose()?;
                let receipt = SessionDeletionReceipt {
                    command_id,
                    intent,
                    runtimes,
                    revision,
                };
                self.validate_deletion_receipt(&receipt)?;
                Ok(receipt)
            },
        )
        .transpose()
    }

    pub(crate) fn session_deletion_pending(&self, session_id: SessionId) -> Result<bool, Error> {
        self.available()?;
        self.connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM deletion_targets t LEFT JOIN deletion_results r USING(command_id) WHERE t.session_id=?1 AND r.command_id IS NULL)",
                [session_id.to_string()],
                |row| row.get(0),
            )
            .map_err(Error::from)
    }

    pub(crate) fn deletions(&self) -> Result<Vec<SessionDeletionReceipt>, Error> {
        self.available()?;
        let mut statement = self
            .connection
            .prepare("SELECT command_id FROM deletion_intents ORDER BY rowid LIMIT 2001")?;
        let commands = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if commands.len() > MAX_OPERATIONS as usize {
            return Err(Error::Corrupt);
        }
        commands
            .into_iter()
            .map(|value| self.deletion(parse_id(&value)?)?.ok_or(Error::Corrupt))
            .collect()
    }

    pub(crate) fn commit_deletion(
        &mut self,
        command_id: CommandId,
    ) -> Result<Option<SessionDeletionReceipt>, Error> {
        self.available()?;
        let Some(mut receipt) = self.deletion(command_id)? else {
            return Ok(None);
        };
        if receipt.revision.is_some() {
            return Ok(Some(receipt));
        }
        for runtime in &receipt.runtimes {
            let attempt = self
                .attempt(runtime.target.pane_id)?
                .ok_or(Error::Conflict)?;
            if attempt.runtime != *runtime || attempt.phase != AttemptPhase::CompletionProven {
                return Ok(Some(receipt));
            }
        }
        let expected = receipt.intent.expected_revision;
        let accepted_revision = expected
            .checked_add(1)
            .filter(|revision| *revision <= MAX_REVISION)
            .ok_or(Error::Capacity)?;
        let sessions = receipt.intent.sessions.clone();
        let runtimes = receipt.runtimes.clone();
        self.mutate(|tx| {
            let stored_revision: i64 = tx.query_row(
                "SELECT revision FROM metadata WHERE singleton=1",
                [],
                |row| row.get(0),
            )?;
            if parse_revision(stored_revision)? != expected {
                return Err(Error::Conflict);
            }
            let stored_runtimes: Vec<u8> = tx.query_row(
                "SELECT runtimes FROM deletion_intents WHERE command_id=?1",
                [command_id.to_string()],
                |row| row.get(0),
            )?;
            if serde_json::from_slice::<Vec<RuntimeRef>>(&stored_runtimes).map_err(|_| Error::Corrupt)? != runtimes {
                return Err(Error::Conflict);
            }
            for address in &sessions {
                let changed = tx.execute(
                    "UPDATE sessions SET tombstoned=1 WHERE session_id=?1 AND workspace_id IS ?2 AND tombstoned=0",
                    params![address.session_id.to_string(), address.workspace_id.map(|id| id.to_string())],
                )?;
                if changed != 1 {
                    return Err(Error::Conflict);
                }
            }
            advance_revision(tx, expected)?;
            tx.execute(
                "INSERT INTO deletion_results(command_id,accepted_revision) VALUES(?1,?2)",
                params![command_id.to_string(), sql_revision(accepted_revision)?],
            )?;
            Ok(())
        })?;
        receipt.revision = Some(accepted_revision);
        Ok(Some(receipt))
    }

    pub(crate) fn validate_deletions(&self) -> Result<(), Error> {
        let receipts = self.deletions()?;
        let mut pending = 0usize;
        let mut deleted_sessions = Vec::new();
        for receipt in &receipts {
            for address in &receipt.intent.sessions {
                if deleted_sessions.contains(&address.session_id) {
                    return Err(Error::Corrupt);
                }
                deleted_sessions.push(address.session_id);
            }
            for runtime in &receipt.runtimes {
                let attempt = self
                    .attempt(runtime.target.pane_id)?
                    .ok_or(Error::Corrupt)?;
                if attempt.runtime != *runtime
                    || (receipt.revision.is_some()
                        && attempt.phase != AttemptPhase::CompletionProven)
                {
                    return Err(Error::Corrupt);
                }
            }
            let unresolved = self.deletion_attempts(&receipt.intent.sessions)?;
            if receipt.revision.is_none() {
                pending += 1;
                if unresolved
                    .iter()
                    .any(|attempt| !receipt.runtimes.contains(&attempt.runtime))
                {
                    return Err(Error::Corrupt);
                }
            } else if !unresolved.is_empty() {
                return Err(Error::Corrupt);
            }
        }
        if pending > 1 {
            return Err(Error::Corrupt);
        }
        let duplicate_commands: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM deletion_intents d JOIN operations o USING(command_id)) OR EXISTS(SELECT 1 FROM deletion_intents d JOIN submitted_commands c USING(command_id)) OR EXISTS(SELECT 1 FROM deletion_intents d JOIN runtime_attempts a ON a.attempt_id=d.command_id)",
            [],
            |row| row.get(0),
        )?;
        if duplicate_commands {
            return Err(Error::Corrupt);
        }
        Ok(())
    }

    fn validate_deletion_targets(
        &self,
        command_id: CommandId,
        intent: &SessionDeletionIntent,
    ) -> Result<(), Error> {
        let mut statement = self.connection.prepare(
            "SELECT session_id,workspace_id FROM deletion_targets WHERE command_id=?1 ORDER BY session_id",
        )?;
        let stored = statement
            .query_map([command_id.to_string()], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut expected = intent
            .sessions
            .iter()
            .map(|address| {
                (
                    address.session_id.to_string(),
                    address.workspace_id.map(|id| id.to_string()),
                )
            })
            .collect::<Vec<_>>();
        expected.sort();
        if stored != expected {
            return Err(Error::Corrupt);
        }
        Ok(())
    }

    fn deletion_authority(&self) -> Result<(MachineId, StoreGeneration, u64), Error> {
        let machine: String = self.connection.query_row(
            "SELECT machine_id FROM metadata WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        Ok((parse_id(&machine)?, self.generation()?, self.revision()?))
    }

    fn validate_deletion_receipt(&self, receipt: &SessionDeletionReceipt) -> Result<(), Error> {
        let (machine, generation, current_revision) = self.deletion_authority()?;
        if receipt.intent.target.machine_id != machine
            || receipt.intent.target.store_generation != generation
            || receipt.intent.expected_revision >= MAX_REVISION
        {
            return Err(Error::Corrupt);
        }
        for runtime in &receipt.runtimes {
            if !receipt
                .intent
                .sessions
                .iter()
                .any(|address| address.session_id == runtime.target.session_id)
            {
                return Err(Error::Corrupt);
            }
        }
        match receipt.revision {
            None => {
                if current_revision != receipt.intent.expected_revision {
                    return Err(Error::Corrupt);
                }
                for address in &receipt.intent.sessions {
                    let exists: bool = self.connection.query_row(
                        "SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id=?1 AND workspace_id IS ?2 AND tombstoned=0)",
                        params![address.session_id.to_string(), address.workspace_id.map(|id| id.to_string())],
                        |row| row.get(0),
                    )?;
                    if !exists {
                        return Err(Error::Corrupt);
                    }
                }
            }
            Some(revision) => {
                if revision != receipt.intent.expected_revision + 1 || revision > current_revision {
                    return Err(Error::Corrupt);
                }
                for address in &receipt.intent.sessions {
                    let tombstoned: bool = self.connection.query_row(
                        "SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id=?1 AND workspace_id IS ?2 AND tombstoned=1)",
                        params![address.session_id.to_string(), address.workspace_id.map(|id| id.to_string())],
                        |row| row.get(0),
                    )?;
                    if !tombstoned {
                        return Err(Error::Corrupt);
                    }
                }
            }
        }
        Ok(())
    }
}

pub(crate) fn validate_intent(
    intent: &SessionDeletionIntent,
    runtimes: &[RuntimeRef],
) -> Result<(), Error> {
    if !(1..=MAX_DELETE_SESSIONS).contains(&intent.sessions.len())
        || intent.expected_revision >= MAX_REVISION
        || runtimes.len() > MAX_DELETE_RUNTIMES
        || !unique(&intent.sessions)
        || !unique(runtimes)
    {
        return Err(Error::Invalid);
    }
    if runtimes.iter().any(|runtime| {
        !intent
            .sessions
            .iter()
            .any(|address| address.session_id == runtime.target.session_id)
    }) {
        return Err(Error::Invalid);
    }
    Ok(())
}

fn unique<T: PartialEq>(values: &[T]) -> bool {
    values
        .iter()
        .enumerate()
        .all(|(index, value)| !values[..index].contains(value))
}

fn deletion_capture(intent: &SessionDeletionIntent) -> Result<Capture, Error> {
    let bytes = serde_json::to_vec(intent).map_err(|_| Error::Invalid)?;
    if bytes.len() > 128 * 1024 {
        return Err(Error::Capacity);
    }
    let mut hash = Sha256::new();
    hash.update(b"axo.central-session-deletion.v1\0");
    hash.update(&bytes);
    Ok(Capture {
        fingerprint: hash.finalize().into(),
        bytes,
    })
}

#[cfg(test)]
mod tests;
