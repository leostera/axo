//! Durable materialization attempts. A reservation is not a PTY; an old or
//! uncertain reservation can only be observed, never issued as another spawn.
use super::DirectoryApproval;
use super::{Database, DesiredPane, Error, PaneRole, parse_id, parse_revision};
use crate::{model::*, runtime::RuntimeCompletion};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttemptPhase {
    Reserved,
    Launched,
    Admitted,
    CompletionProven,
    Blocked,
}
impl AttemptPhase {
    fn parse(value: &str) -> Result<Self, Error> {
        match value {
            "reserved" => Ok(Self::Reserved),
            "launched" => Ok(Self::Launched),
            "admitted" => Ok(Self::Admitted),
            "completionProven" => Ok(Self::CompletionProven),
            "blocked" => Ok(Self::Blocked),
            _ => Err(Error::Corrupt),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Configuration {
    pub pane_revision: u64,
    pub session_revision: u64,
    pub workspace_revision: Option<u64>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Attempt {
    pub configuration: Option<Configuration>,
    pub command_id: CommandId,
    pub runtime: RuntimeRef,
    pub config_revision: u64,
    pub predecessor: Option<CommandId>,
    pub phase: AttemptPhase,
}
pub(crate) enum Reservation {
    New(Attempt),
    Existing(Attempt),
}
pub(crate) struct Specification {
    pub pane: DesiredPane,
    pub workspace_id: Option<WorkspaceId>,
    pub directory: PathBuf,
    pub approval: DirectoryApproval,
    pub configuration: Configuration,
}
impl Database {
    pub fn attempt(&self, pane: PaneId) -> Result<Option<Attempt>, Error> {
        self.available()?;
        let row = self.connection.query_row("SELECT a.attempt_id, p.session_id, a.config_revision, a.owner_epoch, a.runtime_generation, a.predecessor, a.phase, a.config_capture FROM runtime_attempts a JOIN panes p USING(pane_id) WHERE a.pane_id=?1 ORDER BY a.rowid DESC LIMIT 1", [pane.to_string()], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?, row.get::<_, String>(3)?, row.get::<_, String>(4)?, row.get::<_, Option<String>>(5)?, row.get::<_, String>(6)?, row.get::<_, Option<Vec<u8>>>(7)?))).optional()?;
        let Some((
            command,
            session,
            revision,
            owner,
            generation,
            predecessor,
            phase,
            configuration,
        )) = row
        else {
            return Ok(None);
        };
        Ok(Some(Attempt {
            configuration: configuration
                .map(|bytes| serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt))
                .transpose()?,
            command_id: parse_id(&command)?,
            runtime: RuntimeRef {
                host_generation: parse_id(&owner)?,
                runtime_generation: parse_id(&generation)?,
                target: TerminalTarget {
                    session_id: parse_id(&session)?,
                    pane_id: pane,
                },
            },
            config_revision: parse_revision(revision)?,
            predecessor: predecessor.as_deref().map(parse_id).transpose()?,
            phase: AttemptPhase::parse(&phase)?,
        }))
    }
    pub(crate) fn specification(&self, pane: PaneId) -> Result<Specification, Error> {
        self.available()?;
        let row = self.connection.query_row("SELECT s.session_id, s.workspace_id, coalesce(w.directory,s.standalone_directory), coalesce(w.approval,'userHome'), w.profile_id, p.config_revision,s.config_revision,w.config_revision FROM panes p JOIN sessions s USING(session_id) LEFT JOIN workspaces w USING(workspace_id) WHERE p.pane_id=?1 AND p.desired_present=1 AND s.desired_open=1 AND s.tombstoned=0 AND (w.workspace_id IS NULL OR w.desired_open=1)", [pane.to_string()], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?, row.get::<_, String>(2)?, row.get::<_, String>(3)?, row.get::<_, Option<String>>(4)?, row.get::<_, i64>(5)?, row.get::<_, i64>(6)?, row.get::<_, Option<i64>>(7)?))).optional()?.ok_or(Error::NotFound)?;
        let (
            session,
            workspace,
            directory,
            approval,
            profile,
            pane_revision,
            session_revision,
            workspace_revision,
        ) = row;
        let session = parse_id(&session)?;
        if self.session_deletion_pending(session)? {
            return Err(Error::Conflict);
        }
        let pane = self
            .panes(session)?
            .into_iter()
            .find(|record| record.pane_id == pane)
            .ok_or(Error::Corrupt)?;
        let approval = match (approval.as_str(), profile) {
            ("localSelection", None) => DirectoryApproval::LocalSelection,
            ("userHome", None) => DirectoryApproval::UserHome,
            ("profile", Some(profile)) => DirectoryApproval::Profile(profile),
            _ => return Err(Error::Corrupt),
        };
        Ok(Specification {
            pane,
            workspace_id: workspace.as_deref().map(parse_id).transpose()?,
            directory: directory.into(),
            approval,
            configuration: Configuration {
                pane_revision: parse_revision(pane_revision)?,
                session_revision: parse_revision(session_revision)?,
                workspace_revision: workspace_revision.map(parse_revision).transpose()?,
            },
        })
    }
    pub(crate) fn reserve_attempt(
        &mut self,
        pane: PaneId,
        owner: HostGeneration,
        configuration: Configuration,
    ) -> Result<Reservation, Error> {
        let spec = self.specification(pane)?;
        if spec.configuration != configuration {
            return Err(Error::Conflict);
        }
        let previous = self.attempt(pane)?;
        if let Some(previous) = &previous
            && (previous.phase != AttemptPhase::CompletionProven
                || previous.configuration.is_none())
        {
            return Ok(Reservation::Existing(previous.clone()));
        }
        let capture = serde_json::to_vec(&configuration).map_err(|_| Error::Invalid)?;
        let attempt = Attempt {
            configuration: Some(configuration.clone()),
            command_id: CommandId::new(),
            runtime: RuntimeRef {
                host_generation: owner,
                runtime_generation: RuntimeGeneration::new(),
                target: TerminalTarget {
                    session_id: spec.pane.session_id,
                    pane_id: pane,
                },
            },
            config_revision: configuration.pane_revision,
            predecessor: previous.map(|previous| previous.command_id),
            phase: AttemptPhase::Reserved,
        };
        self.mutate(|tx| {
            let metadata_original: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM operations WHERE command_id=?1) OR EXISTS(SELECT 1 FROM submitted_commands WHERE command_id=?1) OR EXISTS(SELECT 1 FROM deletion_intents WHERE command_id=?1)",
                [attempt.command_id.to_string()],
                |row| row.get(0),
            )?;
            if metadata_original {
                return Err(Error::Conflict);
            }
            let count: u32 = tx.query_row("SELECT count(*) FROM runtime_attempts", [], |row| {
                row.get(0)
            })?;
            if count >= 2000 {
                return Err(Error::Capacity);
            }
            tx.execute(
                "INSERT INTO runtime_attempts VALUES(?1,?2,?3,?4,?5,?6,'reserved',NULL,?7)",
                params![
                    attempt.command_id.to_string(),
                    pane.to_string(),
                    super::sql_revision(configuration.pane_revision)?,
                    owner.to_string(),
                    attempt.runtime.runtime_generation.to_string(),
                    attempt.predecessor.map(|command| command.to_string()),
                    capture
                ],
            )?;
            Ok(Reservation::New(attempt))
        })
    }
    fn exact_attempt(&self, attempt: &Attempt) -> Result<(), Error> {
        let stored = self
            .attempt(attempt.runtime.target.pane_id)?
            .ok_or(Error::NotFound)?;
        if stored.command_id != attempt.command_id
            || stored.runtime != attempt.runtime
            || stored.configuration != attempt.configuration
            || stored.predecessor != attempt.predecessor
        {
            return Err(Error::Conflict);
        }
        Ok(())
    }
    pub(crate) fn mark_launched(
        &mut self,
        attempt: &Attempt,
        runtime: RuntimeRef,
    ) -> Result<(), Error> {
        self.exact_attempt(attempt)?;
        if runtime != attempt.runtime {
            return Err(Error::Conflict);
        }
        self.mutate(|tx| {
            let changed = tx.execute("UPDATE runtime_attempts SET phase='launched' WHERE attempt_id=?1 AND phase='reserved'", [attempt.command_id.to_string()])?;
            if changed != 1 { return Err(Error::Conflict); }
            Ok(())
        })
    }
    pub(crate) fn complete_attempt(
        &mut self,
        attempt: &Attempt,
        proof: RuntimeCompletion,
    ) -> Result<(), Error> {
        self.exact_attempt(attempt)?;
        if proof.runtime() != attempt.runtime {
            return Err(Error::Conflict);
        }
        let completion = serde_json::to_vec(&proof.runtime()).map_err(|_| Error::Invalid)?;
        self.mutate(|tx| {
            let changed = tx.execute("UPDATE runtime_attempts SET phase='completionProven', completion=?1 WHERE attempt_id=?2 AND phase!='completionProven'", params![completion, attempt.command_id.to_string()])?;
            if changed != 1 { return Err(Error::Conflict); }
            Ok(())
        })
    }
    pub(crate) fn binding(
        &self,
        session: SessionId,
    ) -> Result<Option<crate::pi_session::Binding>, Error> {
        self.available()?;
        let bytes: Option<Option<Vec<u8>>> = self
            .connection
            .query_row(
                "SELECT runtime_binding FROM pi_bindings WHERE session_id=?1",
                [session.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        match bytes {
            None => Ok(None),
            Some(None) => Err(Error::Conflict),
            Some(Some(bytes)) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|_| Error::Corrupt),
        }
    }
    pub(crate) fn admit_binding(
        &mut self,
        attempt: &Attempt,
        binding: &crate::pi_session::Binding,
    ) -> Result<(), Error> {
        self.exact_attempt(attempt)?;
        if binding.runtime != attempt.runtime
            || binding.start_command_id != attempt.command_id
            || binding.session_id != attempt.runtime.target.session_id
            || binding.pane_id != attempt.runtime.target.pane_id
        {
            return Err(Error::Conflict);
        }
        let spec = self.specification(binding.pane_id)?;
        if spec.pane.role != PaneRole::Pi
            || Some(&spec.configuration) != attempt.configuration.as_ref()
            || spec.workspace_id != binding.workspace_id
            || spec.directory != binding.directory
        {
            return Err(Error::Conflict);
        }
        let chat = serde_json::to_value(binding.chat_id).map_err(|_| Error::Invalid)?;
        let bytes = serde_json::to_vec(binding).map_err(|_| Error::Invalid)?;
        self.mutate(|tx| {
            tx.execute("INSERT INTO pi_bindings VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(session_id) DO UPDATE SET chat_id=excluded.chat_id, canonical_file=excluded.canonical_file, canonical_directory=excluded.canonical_directory, original_start=excluded.original_start, runtime_binding=excluded.runtime_binding", params![binding.session_id.to_string(), binding.pane_id.to_string(), chat.as_str().ok_or(Error::Invalid)?, binding.file.to_str().ok_or(Error::Invalid)?, binding.file.parent().and_then(|path| path.to_str()).ok_or(Error::Invalid)?, binding.start_command_id.to_string(), bytes])?;
            let changed = tx.execute("UPDATE runtime_attempts SET phase='admitted' WHERE attempt_id=?1 AND phase='launched'", [attempt.command_id.to_string()])?;
            if changed != 1 { return Err(Error::Conflict); }
            Ok(())
        })
    }
}
