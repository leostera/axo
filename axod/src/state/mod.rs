//! Central desired-state authority. The graph persists user intent; it makes no
//! assertion that a database row owns a PTY or that a previous writer completed.
mod image;
mod input;
use crate::model::*;
pub use input::{Draft, DraftAddress, DraftRevision};
use rusqlite::{Connection, MAIN_DB, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const MAX_REVISION: u64 = 9_007_199_254_740_991;
const MAX_OPERATIONS: u32 = 2000;
const SCHEMA_VERSION: i64 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    NotFound,
    Conflict,
    Capacity,
    Storage,
    Fenced,
    UnsafeStorage,
    OwnerConflict,
    Corrupt,
    UnsupportedVersion,
    MigrationRequired,
}
impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::Storage
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DesiredLifecycle {
    Open,
    Archived,
}
impl DesiredLifecycle {
    fn is_open(self) -> bool {
        self == Self::Open
    }
    fn from_open(open: bool) -> Self {
        if open { Self::Open } else { Self::Archived }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum PaneRole {
    Pi,
    AccountShell,
    #[serde(rename_all = "camelCase")]
    ProfileShell {
        profile_id: String,
    },
}
impl PaneRole {
    fn stored(&self) -> (&str, Option<&str>) {
        match self {
            Self::Pi => ("pi", None),
            Self::AccountShell => ("accountShell", None),
            Self::ProfileShell { profile_id } => ("profileShell", Some(profile_id)),
        }
    }
    fn parse(role: String, profile: Option<String>) -> Result<Self, Error> {
        match (role.as_str(), profile) {
            ("pi", None) => Ok(Self::Pi),
            ("accountShell", None) => Ok(Self::AccountShell),
            ("profileShell", Some(profile_id)) if valid_profile(&profile_id) => {
                Ok(Self::ProfileShell { profile_id })
            }
            _ => Err(Error::Corrupt),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DesiredWorkspace {
    pub workspace_id: WorkspaceId,
    pub name: String,
    pub directory: PathBuf,
    pub lifecycle: DesiredLifecycle,
    pub config_revision: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DesiredSession {
    pub session_id: SessionId,
    pub workspace_id: Option<WorkspaceId>,
    pub name: String,
    pub manual_name: bool,
    pub lifecycle: DesiredLifecycle,
    pub config_revision: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DesiredPane {
    pub pane_id: PaneId,
    pub session_id: SessionId,
    pub role: PaneRole,
    pub present: bool,
    pub ordinal: u8,
    pub config_revision: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionGraph {
    pub session: DesiredSession,
    pub panes: Vec<DesiredPane>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceGraph {
    pub workspace: DesiredWorkspace,
    pub initial_session: SessionGraph,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Accepted<T> {
    pub command_id: CommandId,
    pub revision: u64,
    pub graph: T,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum LifecycleTarget {
    #[serde(rename_all = "camelCase")]
    Workspace { workspace_id: WorkspaceId },
    #[serde(rename_all = "camelCase")]
    Session {
        workspace_id: Option<WorkspaceId>,
        session_id: SessionId,
    },
}

/// Constructed only after the backend accepts directory selection/profile
/// authority. Filesystem identity is not recovered from a frontend preference.
#[derive(Clone, Debug, Serialize)]
pub struct ApprovedDirectory {
    path: PathBuf,
}
impl ApprovedDirectory {
    pub fn local_selection(path: &Path) -> Result<Self, Error> {
        if !path.is_absolute() || path.as_os_str().len() > 4096 {
            return Err(Error::Invalid);
        }
        let path = std::fs::canonicalize(path).map_err(|_| Error::Invalid)?;
        if !path.is_dir() || path.to_str().is_none() {
            return Err(Error::Invalid);
        }
        std::fs::read_dir(&path).map_err(|_| Error::Invalid)?;
        Ok(Self { path })
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ApprovedHome {
    path: PathBuf,
}
impl ApprovedHome {
    pub fn capture() -> Result<Self, Error> {
        use std::os::unix::fs::MetadataExt;
        let home = std::env::var_os("HOME").ok_or(Error::Invalid)?;
        let approved = ApprovedDirectory::local_selection(Path::new(&home))?;
        if std::fs::metadata(&approved.path)
            .map_err(|_| Error::Invalid)?
            .uid()
            != unsafe { libc::geteuid() }
        {
            return Err(Error::Invalid);
        }
        Ok(Self {
            path: approved.path,
        })
    }
}

#[derive(Serialize)]
#[serde(
    tag = "operation",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum Intent<'a> {
    CreateWorkspace {
        expected_revision: u64,
        name: &'a str,
        directory: &'a ApprovedDirectory,
    },
    CreateSession {
        expected_revision: u64,
        workspace_id: WorkspaceId,
        name: &'a str,
    },
    CreateStandalone {
        expected_revision: u64,
        name: &'a str,
        home: &'a ApprovedHome,
    },
    AddShell {
        expected_revision: u64,
        session_id: SessionId,
    },
    RemoveShell {
        expected_revision: u64,
        session_id: SessionId,
        pane_id: PaneId,
    },
    SetLifecycle {
        expected_revision: u64,
        target: &'a LifecycleTarget,
        lifecycle: DesiredLifecycle,
    },
}
struct Capture {
    fingerprint: [u8; 32],
    bytes: Vec<u8>,
}

pub struct Database {
    connection: Connection,
    root: image::Root,
    fenced: bool,
}
impl Database {
    pub fn open(root: &Path, machine: MachineId) -> Result<Self, Error> {
        let mut root = image::Root::acquire(root)?;
        let bytes = root.load()?;
        if bytes.is_none() {
            if root.has_authority()? {
                return Err(Error::Corrupt);
            }
            if root.has_legacy()? {
                return Err(Error::MigrationRequired);
            }
        }
        let mut connection = Connection::open_in_memory()?;
        if let Some(bytes) = bytes.as_ref() {
            if !bytes.starts_with(b"SQLite format 3\0")
                || bytes.len() < 4096
                || !bytes.len().is_multiple_of(4096)
                || bytes[16..18] != [0x10, 0x00]
            {
                return Err(Error::Corrupt);
            }
            connection
                .deserialize_read_exact(MAIN_DB, bytes.as_slice(), bytes.len(), false)
                .map_err(|_| Error::Corrupt)?;
        }
        connection.execute_batch("PRAGMA temp_store=MEMORY; PRAGMA journal_mode=MEMORY; PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA page_size=4096; PRAGMA max_page_count=16384;")
            .map_err(|error| if bytes.is_some() { Error::Corrupt } else { Error::from(error) })?;
        connection.set_limit(
            rusqlite::limits::Limit::SQLITE_LIMIT_LENGTH,
            8 * 1024 * 1024,
        )?;
        connection.set_limit(rusqlite::limits::Limit::SQLITE_LIMIT_SQL_LENGTH, 128 * 1024)?;
        if bytes.is_none() {
            let transaction = connection.transaction()?;
            transaction.execute_batch(include_str!("schema.sql"))?;
            transaction.execute(
                "INSERT INTO metadata VALUES(1, ?1, 0)",
                [machine.to_string()],
            )?;
            transaction.commit()?;
        }
        let mut database = Self {
            connection,
            root,
            fenced: false,
        };
        database.validate(machine)?;
        if bytes.is_none() {
            database.publish()?;
        }
        Ok(database)
    }
    fn validate(&self, machine: MachineId) -> Result<(), Error> {
        let version: i64 = self
            .connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|_| Error::Corrupt)?;
        if version != SCHEMA_VERSION {
            return Err(Error::UnsupportedVersion);
        }
        let integrity: String = self
            .connection
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .map_err(|_| Error::Corrupt)?;
        if integrity != "ok" {
            return Err(Error::Corrupt);
        }
        let violations: u32 = self
            .connection
            .query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
                row.get(0)
            })
            .map_err(|_| Error::Corrupt)?;
        if violations != 0 {
            return Err(Error::Corrupt);
        }
        let recorded: String = self
            .connection
            .query_row(
                "SELECT machine_id FROM metadata WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .map_err(|_| Error::Corrupt)?;
        if parse_id::<MachineId>(&recorded)? != machine {
            return Err(Error::Conflict);
        }
        self.revision()?;
        // Validate application invariants that cannot be expressed as a local
        // CHECK while inserting the whole graph in one transaction.
        let invalid: bool = self.connection.query_row("SELECT EXISTS(SELECT 1 FROM sessions s WHERE s.tombstoned=0 AND ((SELECT count(*) FROM panes p WHERE p.session_id=s.session_id AND p.role='pi' AND p.desired_present=1)!=1 OR (SELECT count(*) FROM panes p WHERE p.session_id=s.session_id AND p.role!='pi' AND p.desired_present=1)<1 OR (SELECT count(*) FROM panes p WHERE p.session_id=s.session_id AND p.desired_present=1)>32))", [], |row| row.get(0)).map_err(|_| Error::Corrupt)?;
        if invalid {
            return Err(Error::Corrupt);
        }
        for workspace in self.workspaces()? {
            if !valid_name(&workspace.name)
                || !workspace.directory.is_absolute()
                || workspace.directory.to_str().is_none()
            {
                return Err(Error::Corrupt);
            }
        }
        for session in self.sessions()? {
            if !valid_name(&session.name) {
                return Err(Error::Corrupt);
            }
            self.panes(session.session_id)?;
        }
        Ok(())
    }
    fn publish(&mut self) -> Result<(), Error> {
        let result = self
            .connection
            .serialize(MAIN_DB)
            .map_err(Error::from)
            .and_then(|image| self.root.publish(&image));
        if result.is_err() {
            self.fenced = true;
        }
        result
    }
    fn available(&self) -> Result<(), Error> {
        if self.fenced {
            Err(Error::Fenced)
        } else {
            Ok(())
        }
    }
    fn mutate<T>(
        &mut self,
        body: impl FnOnce(&Transaction<'_>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        self.available()?;
        let transaction = self.connection.transaction()?;
        let result = body(&transaction)?;
        transaction.commit()?;
        // No result, identity or spawn authority escapes before publication.
        self.publish()?;
        Ok(result)
    }
    pub fn revision(&self) -> Result<u64, Error> {
        self.available()?;
        let revision: i64 = self.connection.query_row(
            "SELECT revision FROM metadata WHERE singleton=1",
            [],
            |row| row.get(0),
        )?;
        parse_revision(revision)
    }
    pub fn workspaces(&self) -> Result<Vec<DesiredWorkspace>, Error> {
        self.available()?;
        let mut statement = self.connection.prepare("SELECT workspace_id, name, directory, desired_open, config_revision FROM workspaces ORDER BY rowid LIMIT 129")?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, bool>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })?;
        let mut workspaces = Vec::new();
        for row in rows {
            let (id, name, directory, open, revision) = row?;
            workspaces.push(DesiredWorkspace {
                workspace_id: parse_id(&id)?,
                name,
                directory: directory.into(),
                lifecycle: DesiredLifecycle::from_open(open),
                config_revision: parse_revision(revision)?,
            });
        }
        if workspaces.len() > 128 {
            return Err(Error::Corrupt);
        }
        Ok(workspaces)
    }
    pub fn sessions(&self) -> Result<Vec<DesiredSession>, Error> {
        self.available()?;
        let mut statement = self.connection.prepare("SELECT session_id, workspace_id, name, manual_name, desired_open, config_revision FROM sessions WHERE tombstoned=0 ORDER BY rowid LIMIT 1001")?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, bool>(3)?,
                row.get::<_, bool>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })?;
        let mut sessions = Vec::new();
        for row in rows {
            let (id, workspace, name, manual_name, open, revision) = row?;
            sessions.push(DesiredSession {
                session_id: parse_id(&id)?,
                workspace_id: workspace.as_deref().map(parse_id).transpose()?,
                name,
                manual_name,
                lifecycle: DesiredLifecycle::from_open(open),
                config_revision: parse_revision(revision)?,
            });
        }
        if sessions.len() > 1000 {
            return Err(Error::Corrupt);
        }
        Ok(sessions)
    }
    pub fn panes(&self, session: SessionId) -> Result<Vec<DesiredPane>, Error> {
        self.available()?;
        let mut statement = self.connection.prepare("SELECT pane_id, role, profile_id, desired_present, ordinal, config_revision FROM panes WHERE session_id=?1 AND desired_present=1 ORDER BY ordinal LIMIT 33")?;
        let rows = statement.query_map([session.to_string()], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, bool>(3)?,
                row.get::<_, u8>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })?;
        let mut panes = Vec::new();
        for row in rows {
            let (id, role, profile, present, ordinal, revision) = row?;
            panes.push(DesiredPane {
                pane_id: parse_id(&id)?,
                session_id: session,
                role: PaneRole::parse(role, profile)?,
                present,
                ordinal,
                config_revision: parse_revision(revision)?,
            });
        }
        if panes.len() > 32 {
            return Err(Error::Corrupt);
        }
        Ok(panes)
    }
    pub fn desired_panes(&self) -> Result<Vec<DesiredPane>, Error> {
        let workspaces = self.workspaces()?;
        let mut desired = Vec::new();
        for session in self.sessions()? {
            if !session.lifecycle.is_open()
                || session.workspace_id.is_some_and(|id| {
                    !workspaces.iter().any(|workspace| {
                        workspace.workspace_id == id && workspace.lifecycle.is_open()
                    })
                })
            {
                continue;
            }
            desired.extend(
                self.panes(session.session_id)?
                    .into_iter()
                    .filter(|pane| pane.present),
            );
        }
        // Imported intent can exceed today's execution budget. Preserve and
        // observe it; admission/reconciliation reports capacity, not corruption.
        Ok(desired)
    }
    pub fn create_workspace(
        &mut self,
        command: CommandId,
        expected: u64,
        name: &str,
        directory: &ApprovedDirectory,
    ) -> Result<Accepted<WorkspaceGraph>, Error> {
        let fingerprint = fingerprint(&Intent::CreateWorkspace {
            expected_revision: expected,
            name,
            directory,
        })?;
        self.available()?;
        if let Some(original) = original(&self.connection, command, &fingerprint)? {
            return Ok(original);
        }
        if !valid_name(name) {
            return Err(Error::Invalid);
        }
        let workspace_id = WorkspaceId::new();
        let name = name.to_owned();
        let directory = directory.path.clone();
        self.mutate(|tx| {
            let revision = reserve(tx, expected, 2)?;
            let count: u32 =
                tx.query_row("SELECT count(*) FROM workspaces", [], |row| row.get(0))?;
            if count >= 128 {
                return Err(Error::Capacity);
            }
            tx.execute(
                "INSERT INTO workspaces VALUES(?1, ?2, ?3, 'localSelection', NULL, 1, ?4)",
                params![
                    workspace_id.to_string(),
                    name,
                    directory.to_str().ok_or(Error::Invalid)?,
                    sql_revision(revision)?
                ],
            )?;
            let initial_session =
                insert_session(tx, Some(workspace_id), None, "Session", revision)?;
            let accepted = Accepted {
                command_id: command,
                revision,
                graph: WorkspaceGraph {
                    workspace: DesiredWorkspace {
                        workspace_id,
                        name,
                        directory,
                        lifecycle: DesiredLifecycle::Open,
                        config_revision: revision,
                    },
                    initial_session,
                },
            };
            record(
                tx,
                command,
                fingerprint,
                "createWorkspace",
                revision,
                &accepted,
            )?;
            Ok(accepted)
        })
    }
    pub fn create_session(
        &mut self,
        command: CommandId,
        expected: u64,
        workspace: WorkspaceId,
        name: &str,
    ) -> Result<Accepted<SessionGraph>, Error> {
        let fingerprint = fingerprint(&Intent::CreateSession {
            expected_revision: expected,
            workspace_id: workspace,
            name,
        })?;
        self.available()?;
        if let Some(original) = original(&self.connection, command, &fingerprint)? {
            return Ok(original);
        }
        if !valid_name(name) {
            return Err(Error::Invalid);
        }
        self.mutate(|tx| {
            let open: Option<bool> = tx
                .query_row(
                    "SELECT desired_open FROM workspaces WHERE workspace_id=?1",
                    [workspace.to_string()],
                    |row| row.get(0),
                )
                .optional()?;
            match open {
                None => return Err(Error::NotFound),
                Some(false) => return Err(Error::Conflict),
                Some(true) => (),
            }
            let revision = reserve(tx, expected, 2)?;
            let graph = insert_session(tx, Some(workspace), None, name, revision)?;
            let accepted = Accepted {
                command_id: command,
                revision,
                graph,
            };
            record(
                tx,
                command,
                fingerprint,
                "createSession",
                revision,
                &accepted,
            )?;
            Ok(accepted)
        })
    }
    pub fn create_standalone(
        &mut self,
        command: CommandId,
        expected: u64,
        name: &str,
        home: &ApprovedHome,
    ) -> Result<Accepted<SessionGraph>, Error> {
        let fingerprint = fingerprint(&Intent::CreateStandalone {
            expected_revision: expected,
            name,
            home,
        })?;
        self.available()?;
        if let Some(original) = original(&self.connection, command, &fingerprint)? {
            return Ok(original);
        }
        if !valid_name(name) {
            return Err(Error::Invalid);
        }
        self.mutate(|tx| {
            let revision = reserve(tx, expected, 2)?;
            let graph = insert_session(tx, None, Some(&home.path), name, revision)?;
            let accepted = Accepted {
                command_id: command,
                revision,
                graph,
            };
            record(
                tx,
                command,
                fingerprint,
                "createStandalone",
                revision,
                &accepted,
            )?;
            Ok(accepted)
        })
    }
    pub fn remove_shell(
        &mut self,
        command: CommandId,
        expected: u64,
        session: SessionId,
        pane: PaneId,
    ) -> Result<Accepted<PaneId>, Error> {
        let fingerprint = fingerprint(&Intent::RemoveShell {
            expected_revision: expected,
            session_id: session,
            pane_id: pane,
        })?;
        self.available()?;
        if let Some(original) = original(&self.connection, command, &fingerprint)? {
            return Ok(original);
        }
        self.mutate(|tx| {
            let role: Option<String> = tx.query_row("SELECT role FROM panes WHERE pane_id=?1 AND session_id=?2 AND desired_present=1", params![pane.to_string(), session.to_string()], |row| row.get(0)).optional()?;
            match role.as_deref() { None => return Err(Error::NotFound), Some("pi") => return Err(Error::Conflict), Some(_) => () }
            let remaining: u32 = tx.query_row("SELECT count(*) FROM panes WHERE session_id=?1 AND role!='pi' AND desired_present=1", [session.to_string()], |row| row.get(0))?;
            if remaining <= 1 { return Err(Error::Conflict); }
            let revision = reserve(tx, expected, 0)?;
            tx.execute("UPDATE panes SET desired_present=0, config_revision=?1 WHERE pane_id=?2", params![sql_revision(revision)?, pane.to_string()])?;
            let accepted = Accepted { command_id: command, revision, graph: pane };
            record(tx, command, fingerprint, "removeShell", revision, &accepted)?;
            // Withdrawal is intent, not process completion. Attempt ownership
            // remains retained until the runtime owner proves actual cleanup.
            Ok(accepted)
        })
    }
    pub fn add_shell(
        &mut self,
        command: CommandId,
        expected: u64,
        session: SessionId,
    ) -> Result<Accepted<DesiredPane>, Error> {
        let fingerprint = fingerprint(&Intent::AddShell {
            expected_revision: expected,
            session_id: session,
        })?;
        self.available()?;
        if let Some(original) = original(&self.connection, command, &fingerprint)? {
            return Ok(original);
        }
        self.mutate(|tx| {
            let live: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM sessions s LEFT JOIN workspaces w USING(workspace_id) WHERE s.session_id=?1 AND s.desired_open=1 AND s.tombstoned=0 AND (w.workspace_id IS NULL OR w.desired_open=1))", [session.to_string()], |row| row.get(0))?;
            if !live { return Err(Error::Conflict); }
            let ordinal: Option<u8> = tx.query_row("WITH RECURSIVE slots(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM slots WHERE x<31) SELECT min(x) FROM slots WHERE NOT EXISTS(SELECT 1 FROM panes WHERE session_id=?1 AND desired_present=1 AND ordinal=x)", [session.to_string()], |row| row.get(0))?;
            let ordinal = ordinal.ok_or(Error::Capacity)?;
            let revision = reserve(tx, expected, 1)?;
            let pane = insert_pane(tx, session, PaneRole::AccountShell, ordinal, revision)?;
            let accepted = Accepted { command_id: command, revision, graph: pane };
            record(tx, command, fingerprint, "addShell", revision, &accepted)?;
            Ok(accepted)
        })
    }
    pub fn set_lifecycle(
        &mut self,
        command: CommandId,
        expected: u64,
        target: LifecycleTarget,
        lifecycle: DesiredLifecycle,
    ) -> Result<Accepted<LifecycleTarget>, Error> {
        let fingerprint = fingerprint(&Intent::SetLifecycle {
            expected_revision: expected,
            target: &target,
            lifecycle,
        })?;
        self.available()?;
        if let Some(original) = original(&self.connection, command, &fingerprint)? {
            return Ok(original);
        }
        self.mutate(|tx| {
            let revision = reserve(tx, expected, 0)?;
            let changed = match &target {
                LifecycleTarget::Workspace { workspace_id } => tx.execute("UPDATE workspaces SET desired_open=?1, config_revision=?2 WHERE workspace_id=?3", params![lifecycle.is_open(), sql_revision(revision)?, workspace_id.to_string()])?,
                LifecycleTarget::Session { workspace_id, session_id } => tx.execute("UPDATE sessions SET desired_open=?1, config_revision=?2 WHERE session_id=?3 AND workspace_id IS ?4 AND tombstoned=0", params![lifecycle.is_open(), sql_revision(revision)?, session_id.to_string(), workspace_id.map(|id| id.to_string())])?,
            };
            if changed != 1 { return Err(Error::NotFound); }
            if lifecycle.is_open() { check_capacity(tx, 0)?; }
            let accepted = Accepted { command_id: command, revision, graph: target };
            record(tx, command, fingerprint, "setLifecycle", revision, &accepted)?;
            Ok(accepted)
        })
    }
}
fn parse_revision(value: i64) -> Result<u64, Error> {
    let revision = u64::try_from(value).map_err(|_| Error::Corrupt)?;
    if revision > MAX_REVISION {
        return Err(Error::Corrupt);
    }
    Ok(revision)
}
fn sql_revision(value: u64) -> Result<i64, Error> {
    if value > MAX_REVISION {
        return Err(Error::Invalid);
    }
    i64::try_from(value).map_err(|_| Error::Invalid)
}
fn parse_id<T: DeserializeOwned>(value: &str) -> Result<T, Error> {
    serde_json::from_value(serde_json::Value::String(value.to_owned())).map_err(|_| Error::Corrupt)
}
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.trim() == name
        && name.encode_utf16().count() <= 80
        && !name.chars().any(char::is_control)
}
fn valid_profile(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}
fn fingerprint(value: &Intent<'_>) -> Result<Capture, Error> {
    let bytes = serde_json::to_vec(value).map_err(|_| Error::Invalid)?;
    if bytes.len() > 128 * 1024 {
        return Err(Error::Capacity);
    }
    let mut hash = Sha256::new();
    hash.update(b"axo.central-session-management.operation.v1\0");
    hash.update(&bytes);
    Ok(Capture {
        fingerprint: hash.finalize().into(),
        bytes,
    })
}
fn original<T: DeserializeOwned>(
    connection: &Connection,
    command: CommandId,
    capture: &Capture,
) -> Result<Option<T>, Error> {
    let row = connection
        .query_row(
            "SELECT fingerprint, capture, result FROM operations WHERE command_id=?1",
            [command.to_string()],
            |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                ))
            },
        )
        .optional()?;
    match row {
        None => Ok(None),
        Some((fingerprint, bytes, _))
            if fingerprint != capture.fingerprint || bytes != capture.bytes =>
        {
            Err(Error::Conflict)
        }
        Some((_, _, result)) => serde_json::from_slice(&result)
            .map(Some)
            .map_err(|_| Error::Corrupt),
    }
}
fn record<T: Serialize>(
    tx: &Transaction<'_>,
    command: CommandId,
    capture: Capture,
    kind: &str,
    revision: u64,
    result: &T,
) -> Result<(), Error> {
    let bytes = serde_json::to_vec(result).map_err(|_| Error::Invalid)?;
    if bytes.len() > 128 * 1024 {
        return Err(Error::Capacity);
    }
    tx.execute(
        "INSERT INTO operations VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            command.to_string(),
            capture.fingerprint.as_slice(),
            capture.bytes,
            kind,
            sql_revision(revision)?,
            bytes
        ],
    )?;
    Ok(())
}
fn reserve(tx: &Transaction<'_>, expected: u64, additional_panes: u32) -> Result<u64, Error> {
    let stored: i64 = tx.query_row(
        "SELECT revision FROM metadata WHERE singleton=1",
        [],
        |row| row.get(0),
    )?;
    let current = parse_revision(stored)?;
    if current != expected {
        return Err(Error::Conflict);
    }
    if current >= MAX_REVISION {
        return Err(Error::Capacity);
    }
    let operations: u32 = tx.query_row("SELECT count(*) FROM operations", [], |row| row.get(0))?;
    if operations >= MAX_OPERATIONS {
        return Err(Error::Capacity);
    }
    if additional_panes != 0 {
        check_capacity(tx, additional_panes)?;
    }
    tx.execute(
        "UPDATE metadata SET revision=revision+1 WHERE singleton=1",
        [],
    )?;
    Ok(current + 1)
}
fn check_capacity(tx: &Transaction<'_>, additional: u32) -> Result<(), Error> {
    let desired: u32 = tx.query_row("SELECT count(*) FROM panes p JOIN sessions s USING(session_id) LEFT JOIN workspaces w USING(workspace_id) WHERE p.desired_present=1 AND s.desired_open=1 AND s.tombstoned=0 AND (w.workspace_id IS NULL OR w.desired_open=1)", [], |row| row.get(0))?;
    if u64::from(desired) + u64::from(additional) > crate::terminal::MAX_TERMINALS as u64 {
        return Err(Error::Capacity);
    }
    Ok(())
}
fn insert_session(
    tx: &Transaction<'_>,
    workspace: Option<WorkspaceId>,
    standalone: Option<&Path>,
    name: &str,
    revision: u64,
) -> Result<SessionGraph, Error> {
    let count: u32 = tx.query_row("SELECT count(*) FROM sessions", [], |row| row.get(0))?;
    if count >= 1000 {
        return Err(Error::Capacity);
    }
    let session_id = SessionId::new();
    tx.execute(
        "INSERT INTO sessions VALUES(?1, ?2, ?3, 0, ?4, 1, 0, ?5)",
        params![
            session_id.to_string(),
            workspace.map(|id| id.to_string()),
            name,
            standalone
                .map(|path| path.to_str().ok_or(Error::Invalid))
                .transpose()?,
            sql_revision(revision)?
        ],
    )?;
    let panes = vec![
        insert_pane(tx, session_id, PaneRole::Pi, 0, revision)?,
        insert_pane(tx, session_id, PaneRole::AccountShell, 1, revision)?,
    ];
    Ok(SessionGraph {
        session: DesiredSession {
            session_id,
            workspace_id: workspace,
            name: name.into(),
            manual_name: false,
            lifecycle: DesiredLifecycle::Open,
            config_revision: revision,
        },
        panes,
    })
}
fn insert_pane(
    tx: &Transaction<'_>,
    session: SessionId,
    role: PaneRole,
    ordinal: u8,
    revision: u64,
) -> Result<DesiredPane, Error> {
    let pane_id = PaneId::new();
    let (kind, profile) = role.stored();
    tx.execute(
        "INSERT INTO panes VALUES(?1, ?2, ?3, ?4, 1, ?5, ?6)",
        params![
            pane_id.to_string(),
            session.to_string(),
            kind,
            profile,
            ordinal,
            sql_revision(revision)?
        ],
    )?;
    Ok(DesiredPane {
        pane_id,
        session_id: session,
        role,
        present: true,
        ordinal,
        config_revision: revision,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;
    fn directory(root: &TestDirectory) -> ApprovedDirectory {
        ApprovedDirectory::local_selection(root.path()).unwrap()
    }
    #[test]
    fn workspace_creation_is_one_durable_complete_graph_and_original() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let command = CommandId::new();
        let approved = directory(&root);
        let mut database = Database::open(root.path(), machine).unwrap();
        let created = database
            .create_workspace(command, 0, "Workspace", &approved)
            .unwrap();
        assert_eq!(created.graph.initial_session.panes.len(), 2);
        assert_eq!(created.graph.initial_session.panes[0].role, PaneRole::Pi);
        assert_eq!(
            created.graph.initial_session.panes[1].role,
            PaneRole::AccountShell
        );
        assert_eq!(
            database
                .create_workspace(command, 0, "Workspace", &approved)
                .unwrap(),
            created
        );
        assert_eq!(
            database.create_workspace(command, 0, "Different", &approved),
            Err(Error::Conflict)
        );
        drop(database);
        let mut restored = Database::open(root.path(), machine).unwrap();
        assert_eq!(
            restored
                .create_workspace(command, 0, "Workspace", &approved)
                .unwrap(),
            created
        );
        assert_eq!(
            restored.desired_panes().unwrap(),
            created.graph.initial_session.panes
        );
        assert_eq!(restored.revision().unwrap(), 1);
    }
    #[test]
    fn reconstructs_three_workspaces_twelve_sessions_thirty_six_stable_panes() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let approved = directory(&root);
        let mut database = Database::open(root.path(), machine).unwrap();
        for index in 0..3 {
            let workspace = database
                .create_workspace(
                    CommandId::new(),
                    database.revision().unwrap(),
                    &format!("Workspace {index}"),
                    &approved,
                )
                .unwrap()
                .graph;
            let mut sessions = vec![workspace.initial_session.session.session_id];
            for index in 1..4 {
                sessions.push(
                    database
                        .create_session(
                            CommandId::new(),
                            database.revision().unwrap(),
                            workspace.workspace.workspace_id,
                            &format!("Session {index}"),
                        )
                        .unwrap()
                        .graph
                        .session
                        .session_id,
                );
            }
            for session in sessions {
                database
                    .add_shell(CommandId::new(), database.revision().unwrap(), session)
                    .unwrap();
            }
        }
        let desired = database.desired_panes().unwrap();
        assert_eq!(desired.len(), 36);
        assert_eq!(
            desired
                .iter()
                .filter(|pane| pane.role == PaneRole::Pi)
                .count(),
            12
        );
        drop(database);
        let restored = Database::open(root.path(), machine).unwrap();
        assert_eq!(restored.workspaces().unwrap().len(), 3);
        assert_eq!(restored.sessions().unwrap().len(), 12);
        assert_eq!(restored.desired_panes().unwrap(), desired);
        // This is storage reconstruction, not PTY materialization acceptance.
    }
    #[test]
    fn parent_archive_keeps_child_choices_and_originals() {
        let root = TestDirectory::new();
        let mut database = Database::open(root.path(), MachineId::new()).unwrap();
        let workspace = database
            .create_workspace(CommandId::new(), 0, "Workspace", &directory(&root))
            .unwrap()
            .graph;
        let first = workspace.initial_session.session;
        let second = database
            .create_session(
                CommandId::new(),
                1,
                workspace.workspace.workspace_id,
                "Second",
            )
            .unwrap()
            .graph
            .session;
        database
            .set_lifecycle(
                CommandId::new(),
                2,
                LifecycleTarget::Session {
                    workspace_id: first.workspace_id,
                    session_id: first.session_id,
                },
                DesiredLifecycle::Archived,
            )
            .unwrap();
        let parent = LifecycleTarget::Workspace {
            workspace_id: workspace.workspace.workspace_id,
        };
        database
            .set_lifecycle(
                CommandId::new(),
                3,
                parent.clone(),
                DesiredLifecycle::Archived,
            )
            .unwrap();
        assert!(database.desired_panes().unwrap().is_empty());
        database
            .set_lifecycle(CommandId::new(), 4, parent, DesiredLifecycle::Open)
            .unwrap();
        let desired = database.desired_panes().unwrap();
        assert_eq!(desired.len(), 2);
        assert!(
            desired
                .iter()
                .all(|pane| pane.session_id == second.session_id)
        );
        assert_eq!(
            database
                .sessions()
                .unwrap()
                .iter()
                .find(|session| session.session_id == first.session_id)
                .unwrap()
                .lifecycle,
            DesiredLifecycle::Archived
        );
    }
    #[test]
    fn stale_invalid_and_capacity_operations_leave_no_partial_graph() {
        let root = TestDirectory::new();
        let mut database = Database::open(root.path(), MachineId::new()).unwrap();
        let approved = directory(&root);
        assert_eq!(
            database.create_workspace(CommandId::new(), 1, "Workspace", &approved),
            Err(Error::Conflict)
        );
        assert_eq!(
            database.create_workspace(CommandId::new(), 0, " bad", &approved),
            Err(Error::Invalid)
        );
        assert!(database.workspaces().unwrap().is_empty());
        for index in 0..64 {
            database
                .create_workspace(
                    CommandId::new(),
                    database.revision().unwrap(),
                    &format!("Workspace {index}"),
                    &approved,
                )
                .unwrap();
        }
        assert_eq!(
            database.create_workspace(
                CommandId::new(),
                database.revision().unwrap(),
                "Over capacity",
                &approved
            ),
            Err(Error::Capacity)
        );
        assert_eq!(database.workspaces().unwrap().len(), 64);
        assert_eq!(database.sessions().unwrap().len(), 64);
        assert_eq!(database.revision().unwrap(), 64);
        assert_eq!(database.desired_panes().unwrap().len(), 128);
    }
    #[test]
    fn legacy_corrupt_missing_and_changed_storage_never_becomes_empty() {
        use std::os::unix::fs::PermissionsExt;
        let root = TestDirectory::new();
        std::fs::write(root.path().join("work-records.json"), b"opaque original").unwrap();
        assert!(matches!(
            Database::open(root.path(), MachineId::new()),
            Err(Error::MigrationRequired)
        ));
        assert_eq!(
            std::fs::read(root.path().join("work-records.json")).unwrap(),
            b"opaque original"
        );
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        std::fs::write(root.path().join(image::NAME), b"opaque original").unwrap();
        assert_eq!(
            database.create_workspace(CommandId::new(), 0, "Workspace", &directory(&root)),
            Err(Error::UnsafeStorage)
        );
        assert_eq!(database.revision(), Err(Error::Fenced));
        drop(database);
        assert!(matches!(
            Database::open(root.path(), machine),
            Err(Error::Corrupt)
        ));
        assert_eq!(
            std::fs::read(root.path().join(image::NAME)).unwrap(),
            b"opaque original"
        );
        std::fs::remove_file(root.path().join(image::NAME)).unwrap();
        assert!(matches!(
            Database::open(root.path(), machine),
            Err(Error::Corrupt)
        ));
        let root = TestDirectory::new();
        std::fs::write(root.path().join(image::NAME), b"invalid SQLite bytes").unwrap();
        std::fs::set_permissions(
            root.path().join(image::NAME),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        assert!(matches!(
            Database::open(root.path(), machine),
            Err(Error::Corrupt)
        ));
    }
    #[test]
    fn removed_shell_identity_is_retained_and_slots_can_be_reused() {
        let root = TestDirectory::new();
        let mut database = Database::open(root.path(), MachineId::new()).unwrap();
        let session = database
            .create_workspace(CommandId::new(), 0, "Workspace", &directory(&root))
            .unwrap()
            .graph
            .initial_session;
        let id = session.session.session_id;
        assert_eq!(
            database.remove_shell(CommandId::new(), 1, id, session.panes[0].pane_id),
            Err(Error::Conflict)
        );
        assert_eq!(
            database.remove_shell(CommandId::new(), 1, id, session.panes[1].pane_id),
            Err(Error::Conflict)
        );
        let added = database.add_shell(CommandId::new(), 1, id).unwrap();
        let command = CommandId::new();
        let removed = database
            .remove_shell(command, 2, id, added.graph.pane_id)
            .unwrap();
        assert_eq!(
            database
                .remove_shell(command, 2, id, added.graph.pane_id)
                .unwrap(),
            removed
        );
        let next = database.add_shell(CommandId::new(), 3, id).unwrap();
        assert_ne!(next.graph.pane_id, added.graph.pane_id);
        assert_eq!(next.graph.ordinal, added.graph.ordinal);
        let retained: String = database
            .connection
            .query_row(
                "SELECT pane_id FROM panes WHERE pane_id=?1 AND desired_present=0",
                [added.graph.pane_id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(retained, added.graph.pane_id.to_string());
        assert_eq!(database.panes(id).unwrap().len(), 3);
    }
    #[test]
    fn standalone_uses_captured_home_and_initializes_both_pane_specs() {
        let root = TestDirectory::new();
        let mut database = Database::open(root.path(), MachineId::new()).unwrap();
        let home = ApprovedHome {
            path: root.path().canonicalize().unwrap(),
        };
        let session = database
            .create_standalone(CommandId::new(), 0, "Standalone", &home)
            .unwrap()
            .graph;
        assert_eq!(session.session.workspace_id, None);
        assert_eq!(session.panes.len(), 2);
        assert_eq!(database.desired_panes().unwrap(), session.panes);
        assert!(database.workspaces().unwrap().is_empty());
    }
    #[test]
    fn originals_cannot_be_changed_and_marker_removal_fences() {
        let root = TestDirectory::new();
        let mut database = Database::open(root.path(), MachineId::new()).unwrap();
        database
            .create_workspace(CommandId::new(), 0, "Workspace", &directory(&root))
            .unwrap();
        assert!(
            database
                .connection
                .execute("DELETE FROM operations", [])
                .is_err()
        );
        assert!(
            database
                .connection
                .execute("UPDATE operations SET kind='changed'", [])
                .is_err()
        );
        std::fs::remove_file(root.path().join("session-state.authority")).unwrap();
        let session = database.sessions().unwrap()[0].session_id;
        assert_eq!(
            database.add_shell(CommandId::new(), 1, session),
            Err(Error::UnsafeStorage)
        );
        assert_eq!(database.revision(), Err(Error::Fenced));
        assert!(!root.path().join("session-state.authority").exists());
    }
    #[test]
    fn truncated_images_and_unsupported_schema_preserve_original_bytes() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        database
            .create_workspace(CommandId::new(), 0, "Workspace", &directory(&root))
            .unwrap();
        drop(database);
        let original = std::fs::read(root.path().join(image::NAME)).unwrap();
        for length in [0, 1, 15, 16, 1024, original.len() / 2, original.len() - 1] {
            let truncated = &original[..length];
            std::fs::write(root.path().join(image::NAME), truncated).unwrap();
            assert!(
                matches!(Database::open(root.path(), machine), Err(Error::Corrupt)),
                "length {length}"
            );
            assert_eq!(
                std::fs::read(root.path().join(image::NAME)).unwrap(),
                truncated
            );
        }
        std::fs::write(root.path().join(image::NAME), original).unwrap();
        let mut database = Database::open(root.path(), machine).unwrap();
        database
            .mutate(|tx| {
                tx.execute_batch("PRAGMA user_version=2")?;
                Ok(())
            })
            .unwrap();
        drop(database);
        let unsupported = std::fs::read(root.path().join(image::NAME)).unwrap();
        assert!(matches!(
            Database::open(root.path(), machine),
            Err(Error::UnsupportedVersion)
        ));
        assert_eq!(
            std::fs::read(root.path().join(image::NAME)).unwrap(),
            unsupported
        );
    }
    #[test]
    fn wrong_machine_does_not_change_persisted_identity() {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        drop(Database::open(root.path(), machine).unwrap());
        let original = std::fs::read(root.path().join(image::NAME)).unwrap();
        assert!(matches!(
            Database::open(root.path(), MachineId::new()),
            Err(Error::Conflict)
        ));
        assert_eq!(
            std::fs::read(root.path().join(image::NAME)).unwrap(),
            original
        );
        Database::open(root.path(), machine).unwrap();
    }
}
