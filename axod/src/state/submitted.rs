//! Immutable submitted originals and single-use local dispatch permission.
//! Restoring a capture yields observation, never permission to replay an effect.
use super::*;
use crate::{
    pi_control::{Action, Dispatched},
    pi_session::Binding,
};

/// Weak constructor/storage representation. Source and action are refined by
/// PiCapture::parse, then checked against current durable authority at reserve.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PiCaptureInput {
    pub command_id: CommandId,
    pub machine_id: MachineId,
    pub host_generation: HostGeneration,
    pub store_generation: StoreGeneration,
    pub expected_revision: u64,
    pub binding: Binding,
    pub configuration: Configuration,
    pub action: Action,
}
#[derive(Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct PiCapture(PiCaptureInput);
impl PiCapture {
    pub fn parse(input: PiCaptureInput) -> Result<Self, Error> {
        if input.expected_revision > MAX_REVISION
            || input.configuration.pane_revision > MAX_REVISION
            || input.configuration.session_revision > MAX_REVISION
            || input
                .configuration
                .workspace_revision
                .is_some_and(|revision| revision > MAX_REVISION)
            || input.configuration.workspace_revision.is_some()
                != input.binding.workspace_id.is_some()
            || input.binding.runtime.host_generation != input.host_generation
            || input.binding.runtime.target.session_id != input.binding.session_id
            || input.binding.runtime.target.pane_id != input.binding.pane_id
            || !input.binding.file.is_absolute()
            || !input.binding.directory.is_absolute()
            || input
                .binding
                .file
                .to_str()
                .is_none_or(|path| path.contains('\0'))
            || input
                .binding
                .directory
                .to_str()
                .is_none_or(|path| path.contains('\0'))
        {
            return Err(Error::Invalid);
        }
        if let Action::Send { text } | Action::Steer { text, .. } = &input.action {
            if text.len() > 64 * 1024 {
                return Err(Error::Capacity);
            }
            if text.chars().all(char::is_whitespace)
                || text
                    .trim_start_matches(char::is_whitespace)
                    .starts_with('/')
            {
                return Err(Error::Invalid);
            }
        }
        let capture = Self(input);
        capture.encoded()?;
        Ok(capture)
    }
    pub fn input(&self) -> &PiCaptureInput {
        &self.0
    }
    fn encoded(&self) -> Result<Capture, Error> {
        let bytes = serde_json::to_vec(self).map_err(|_| Error::Invalid)?;
        if bytes.len() > 128 * 1024
            || serde_json::to_vec(&self.0.action)
                .map_err(|_| Error::Invalid)?
                .len()
                > 65_536
        {
            return Err(Error::Capacity);
        }
        let mut hash = Sha256::new();
        hash.update(b"axo.central-submitted-command.v1\0");
        hash.update(&bytes);
        Ok(Capture {
            fingerprint: hash.finalize().into(),
            bytes,
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PiRejection {
    NotReady,
    Capacity,
    Stale,
    Busy,
    Blocked,
    Invalid,
    RecoveryRequired,
    SourceChanged,
    Stopping,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum PiDisposition {
    /// Capture exists without a durable terminal result. This cannot prove that
    /// no effect happened, even if the original process died before dispatch.
    Unconfirmed,
    Dispatched,
    Rejected {
        reason: PiRejection,
    },
    OutcomeUnknown,
}
#[derive(Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiOriginal {
    pub capture: PiCapture,
    pub accepted_revision: u64,
    pub disposition: PiDisposition,
}
/// Not Clone, Copy, serializable or publicly constructible. Minted only after
/// the original's private image has been durably published by this owner.
/// This reserves storage, not a process: exact current native/control/lease
/// authority must separately be retained and rechecked before dispatch.
pub struct PiPermit {
    owner: std::sync::Arc<()>,
    original: PiOriginal,
}
impl PiPermit {
    pub fn original(&self) -> &PiOriginal {
        &self.original
    }
}
pub enum PiPreparation {
    New(PiPermit),
    Original(PiOriginal),
}
pub enum PiTerminal {
    Dispatched(Dispatched),
    Rejected(PiRejection),
    OutcomeUnknown,
}

struct StoredOriginal {
    bytes: Vec<u8>,
    fingerprint: Vec<u8>,
    revision: i64,
    result: Option<Vec<u8>>,
}
impl Database {
    pub(super) fn validate_pi_originals(&self) -> Result<(), Error> {
        let count: u32 = self.connection.query_row("SELECT (SELECT count(*) FROM operations) + (SELECT count(*) FROM submitted_commands)", [], |row| row.get(0)).map_err(|_| Error::Corrupt)?;
        if count > MAX_OPERATIONS {
            return Err(Error::Corrupt);
        }
        let mut query = self
            .connection
            .prepare("SELECT command_id FROM submitted_commands ORDER BY rowid LIMIT 2001")
            .map_err(|_| Error::Corrupt)?;
        let rows = query
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|_| Error::Corrupt)?;
        for row in rows {
            self.pi_original(parse_id(&row.map_err(|_| Error::Corrupt)?)?)?
                .ok_or(Error::Corrupt)?;
        }
        Ok(())
    }
    pub fn pi_original(&self, command: CommandId) -> Result<Option<PiOriginal>, Error> {
        self.available()?;
        let row = self.connection.query_row("SELECT c.capture,c.fingerprint,c.accepted_revision,r.result FROM submitted_commands c LEFT JOIN submitted_results r USING(command_id) WHERE c.command_id=?1", [command.to_string()], |row| Ok(StoredOriginal { bytes: row.get(0)?, fingerprint: row.get(1)?, revision: row.get(2)?, result: row.get(3)? })).optional()?;
        row.map(|row| self.decode_pi_original(command, row))
            .transpose()
    }
    fn decode_pi_original(
        &self,
        command: CommandId,
        row: StoredOriginal,
    ) -> Result<PiOriginal, Error> {
        let StoredOriginal {
            bytes,
            fingerprint,
            revision,
            result,
        } = row;
        let input: PiCaptureInput = serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt)?;
        let capture = PiCapture::parse(input).map_err(|_| Error::Corrupt)?;
        let encoded = capture.encoded().map_err(|_| Error::Corrupt)?;
        if capture.0.command_id != command
            || fingerprint != encoded.fingerprint
            || bytes != encoded.bytes
        {
            return Err(Error::Corrupt);
        }
        let accepted_revision = parse_revision(revision)?;
        let machine: String = self.connection.query_row(
            "SELECT machine_id FROM metadata WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        if accepted_revision != capture.0.expected_revision + 1
            || accepted_revision > self.revision()?
            || capture.0.store_generation != self.generation()?
            || capture.0.machine_id != parse_id::<MachineId>(&machine)?
        {
            return Err(Error::Corrupt);
        }
        let disposition = match result {
            None => PiDisposition::Unconfirmed,
            Some(bytes) => {
                let disposition = serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt)?;
                if disposition == PiDisposition::Unconfirmed {
                    return Err(Error::Corrupt);
                }
                disposition
            }
        };
        Ok(PiOriginal {
            capture,
            accepted_revision,
            disposition,
        })
    }
    pub fn prepare_pi(&mut self, capture: PiCapture) -> Result<PiPreparation, Error> {
        self.available()?;
        // Repeated capture is observation, even when desired state, runtime or
        // owner epoch has since changed. It does not check out another permit.
        if let Some(original) = self.pi_original(capture.0.command_id)? {
            return if original.capture == capture {
                Ok(PiPreparation::Original(original))
            } else {
                Err(Error::Conflict)
            };
        }
        self.check_pi_capture(&capture)?;
        let encoded = capture.encoded()?;
        let input = &capture.0;
        let accepted_revision = self.mutate(|tx| {
            let collision: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM operations WHERE command_id=?1) OR EXISTS(SELECT 1 FROM runtime_attempts WHERE attempt_id=?1)", [input.command_id.to_string()], |row| row.get(0))?;
            if collision { return Err(Error::Conflict); }
            let revision = reserve(tx, input.expected_revision, 0)?;
            tx.execute("INSERT INTO submitted_commands VALUES(?1,?2,?3,?4)", params![input.command_id.to_string(), encoded.fingerprint.as_slice(), encoded.bytes, sql_revision(revision)?])?;
            Ok(revision)
        })?;
        Ok(PiPreparation::New(PiPermit {
            owner: self.submission_owner.clone(),
            original: PiOriginal {
                capture,
                accepted_revision,
                disposition: PiDisposition::Unconfirmed,
            },
        }))
    }
    fn check_pi_capture(&self, capture: &PiCapture) -> Result<(), Error> {
        let input = &capture.0;
        let machine: String = self.connection.query_row(
            "SELECT machine_id FROM metadata WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        if parse_id::<MachineId>(&machine)? != input.machine_id
            || self.generation()? != input.store_generation
            || self.revision()? != input.expected_revision
        {
            return Err(Error::Conflict);
        }
        let binding = &input.binding;
        if self.binding(binding.session_id)?.as_ref() != Some(binding) {
            return Err(Error::Conflict);
        }
        let spec = self.specification(binding.pane_id)?;
        let attempt = self.attempt(binding.pane_id)?.ok_or(Error::Conflict)?;
        if spec.configuration != input.configuration
            || spec.pane.role != PaneRole::Pi
            || spec.workspace_id != binding.workspace_id
            || spec.directory != binding.directory
            || attempt.phase != AttemptPhase::Admitted
            || attempt.runtime != binding.runtime
            || attempt.command_id != binding.start_command_id
            || attempt.configuration.as_ref() != Some(&input.configuration)
        {
            return Err(Error::Conflict);
        }
        Ok(())
    }
    pub fn finish_pi(
        &mut self,
        permit: PiPermit,
        outcome: PiTerminal,
    ) -> Result<PiOriginal, Error> {
        self.available()?;
        if !std::sync::Arc::ptr_eq(&self.submission_owner, &permit.owner) {
            return Err(Error::Conflict);
        }
        let original = permit.original;
        let input = &original.capture.0;
        let disposition = match outcome {
            PiTerminal::Dispatched(proof) => {
                if !proof.matches(
                    input.command_id,
                    input.binding.runtime,
                    input.binding.chat_id,
                    &input.action,
                ) {
                    return Err(Error::Conflict);
                }
                PiDisposition::Dispatched
            }
            PiTerminal::Rejected(reason) => PiDisposition::Rejected { reason },
            PiTerminal::OutcomeUnknown => PiDisposition::OutcomeUnknown,
        };
        if self.generation()? != input.store_generation
            || self.pi_original(input.command_id)?.as_ref() != Some(&original)
        {
            return Err(Error::Conflict);
        }
        let bytes = serde_json::to_vec(&disposition).map_err(|_| Error::Invalid)?;
        if bytes.len() > 4096 {
            return Err(Error::Capacity);
        }
        let revision = self.revision()?;
        self.mutate(|tx| {
            // Terminal observation must still fit at original-admission capacity.
            // It creates no new original or dispatch permission.
            advance_revision(tx, revision)?;
            tx.execute(
                "INSERT INTO submitted_results VALUES(?1,?2)",
                params![input.command_id.to_string(), bytes],
            )?;
            Ok(())
        })?;
        Ok(PiOriginal {
            disposition,
            ..original
        })
    }
}
#[cfg(test)]
mod tests;
