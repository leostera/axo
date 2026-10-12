-- The image is published atomically only after the entire SQLite transaction.
PRAGMA user_version = 1;
CREATE TABLE metadata (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    machine_id TEXT NOT NULL CHECK (length(machine_id) = 36),
    revision INTEGER NOT NULL CHECK (revision BETWEEN 0 AND 9007199254740991)
) STRICT;
CREATE TABLE workspaces (
    workspace_id TEXT PRIMARY KEY CHECK (length(workspace_id) = 36),
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
    directory TEXT NOT NULL,
    approval TEXT NOT NULL CHECK (approval IN ('localSelection', 'profile')),
    profile_id TEXT,
    desired_open INTEGER NOT NULL CHECK (desired_open IN (0, 1)),
    config_revision INTEGER NOT NULL CHECK (config_revision BETWEEN 0 AND 9007199254740991),
    CHECK ((approval = 'profile') = (profile_id IS NOT NULL))
) STRICT;
CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY CHECK (length(session_id) = 36),
    workspace_id TEXT REFERENCES workspaces(workspace_id),
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
    manual_name INTEGER NOT NULL CHECK (manual_name IN (0, 1)),
    standalone_directory TEXT,
    desired_open INTEGER NOT NULL CHECK (desired_open IN (0, 1)),
    tombstoned INTEGER NOT NULL DEFAULT 0 CHECK (tombstoned IN (0, 1)),
    config_revision INTEGER NOT NULL CHECK (config_revision BETWEEN 0 AND 9007199254740991),
    CHECK ((workspace_id IS NULL) = (standalone_directory IS NOT NULL))
) STRICT;
CREATE TABLE panes (
    pane_id TEXT PRIMARY KEY CHECK (length(pane_id) = 36),
    session_id TEXT NOT NULL REFERENCES sessions(session_id),
    role TEXT NOT NULL CHECK (role IN ('pi', 'accountShell', 'profileShell')),
    profile_id TEXT,
    desired_present INTEGER NOT NULL CHECK (desired_present IN (0, 1)),
    ordinal INTEGER NOT NULL CHECK (ordinal BETWEEN 0 AND 31),
    config_revision INTEGER NOT NULL CHECK (config_revision BETWEEN 0 AND 9007199254740991),
    CHECK ((role = 'profileShell') = (profile_id IS NOT NULL)),
    UNIQUE (session_id, pane_id)
) STRICT;
CREATE UNIQUE INDEX single_pi ON panes(session_id) WHERE role = 'pi';
CREATE INDEX desired_session_panes ON panes(session_id, desired_present);
CREATE UNIQUE INDEX live_pane_slots ON panes(session_id, ordinal) WHERE desired_present = 1;
CREATE TABLE operations (
    command_id TEXT PRIMARY KEY CHECK (length(command_id) = 36),
    fingerprint BLOB NOT NULL CHECK (length(fingerprint) = 32),
    capture BLOB NOT NULL CHECK (length(capture) <= 131072),
    kind TEXT NOT NULL,
    accepted_revision INTEGER NOT NULL CHECK (accepted_revision BETWEEN 1 AND 9007199254740991),
    result BLOB NOT NULL CHECK (length(result) <= 131072)
) STRICT;
CREATE TRIGGER immutable_operations_update BEFORE UPDATE ON operations
BEGIN SELECT RAISE(ABORT, 'Original operation is immutable'); END;
CREATE TRIGGER immutable_operations_delete BEFORE DELETE ON operations
BEGIN SELECT RAISE(ABORT, 'Original operation is immutable'); END;
-- Attempts are not processes. Old epochs and unknown completion cannot authorize
-- adoption, signaling, or creation of another writer.
CREATE TABLE runtime_attempts (
    attempt_id TEXT PRIMARY KEY CHECK (length(attempt_id) = 36),
    pane_id TEXT NOT NULL REFERENCES panes(pane_id),
    config_revision INTEGER NOT NULL,
    owner_epoch TEXT NOT NULL CHECK (length(owner_epoch) = 36),
    runtime_generation TEXT NOT NULL CHECK (length(runtime_generation) = 36),
    predecessor TEXT REFERENCES runtime_attempts(attempt_id),
    phase TEXT NOT NULL CHECK (phase IN ('reserved', 'launched', 'admitted', 'completionProven', 'blocked')),
    completion BLOB,
    CHECK ((phase = 'completionProven') = (completion IS NOT NULL))
) STRICT;
CREATE UNIQUE INDEX one_active_attempt ON runtime_attempts(pane_id) WHERE phase != 'completionProven';
CREATE TABLE pi_bindings (
    session_id TEXT PRIMARY KEY REFERENCES sessions(session_id),
    pane_id TEXT NOT NULL,
    chat_id TEXT NOT NULL CHECK (length(chat_id) = 36),
    canonical_file TEXT NOT NULL,
    canonical_directory TEXT NOT NULL,
    original_start TEXT NOT NULL CHECK (length(original_start) = 36),
    FOREIGN KEY (session_id, pane_id) REFERENCES panes(session_id, pane_id)
) STRICT;
-- Unsent input is a separate bounded domain, never canonical history or a
-- command replay queue. Editing does not advance the workspace catalog revision.
CREATE TABLE drafts (
    address BLOB PRIMARY KEY CHECK (length(address) = 32),
    scope BLOB NOT NULL CHECK (length(scope) <= 1024),
    session_id TEXT NOT NULL,
    pane_id TEXT NOT NULL,
    revision TEXT NOT NULL CHECK (length(revision) = 36),
    text TEXT NOT NULL CHECK (length(CAST(text AS BLOB)) <= 65536),
    FOREIGN KEY (session_id, pane_id) REFERENCES panes(session_id, pane_id)
) STRICT;
CREATE TABLE legacy_originals (
    source_name TEXT PRIMARY KEY,
    digest BLOB NOT NULL CHECK (length(digest) = 32),
    original BLOB NOT NULL CHECK (length(original) <= 4194304)
) STRICT;
