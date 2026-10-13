CREATE TABLE deletion_intents (
    command_id TEXT PRIMARY KEY CHECK (length(command_id) = 36),
    fingerprint BLOB NOT NULL CHECK (length(fingerprint) = 32),
    capture BLOB NOT NULL CHECK (length(capture) BETWEEN 1 AND 131072),
    runtimes BLOB NOT NULL CHECK (length(runtimes) <= 131072)
) STRICT;
CREATE TRIGGER immutable_deletion_intents_update BEFORE UPDATE ON deletion_intents
BEGIN SELECT RAISE(ABORT, 'Session deletion intent is immutable'); END;
CREATE TRIGGER immutable_deletion_intents_delete BEFORE DELETE ON deletion_intents
BEGIN SELECT RAISE(ABORT, 'Session deletion intent is immutable'); END;
CREATE TABLE deletion_targets (
    command_id TEXT NOT NULL REFERENCES deletion_intents(command_id),
    session_id TEXT NOT NULL REFERENCES sessions(session_id),
    workspace_id TEXT,
    PRIMARY KEY (command_id, session_id)
) STRICT;
CREATE INDEX pending_session_deletion ON deletion_targets(session_id, command_id);
CREATE TRIGGER immutable_deletion_targets_update BEFORE UPDATE ON deletion_targets
BEGIN SELECT RAISE(ABORT, 'Session deletion targets are immutable'); END;
CREATE TRIGGER immutable_deletion_targets_delete BEFORE DELETE ON deletion_targets
BEGIN SELECT RAISE(ABORT, 'Session deletion targets are immutable'); END;
CREATE TABLE deletion_results (
    command_id TEXT PRIMARY KEY REFERENCES deletion_intents(command_id),
    accepted_revision INTEGER NOT NULL CHECK (accepted_revision BETWEEN 1 AND 9007199254740991)
) STRICT;
CREATE TRIGGER immutable_deletion_results_update BEFORE UPDATE ON deletion_results
BEGIN SELECT RAISE(ABORT, 'Session deletion receipt is immutable'); END;
CREATE TRIGGER immutable_deletion_results_delete BEFORE DELETE ON deletion_results
BEGIN SELECT RAISE(ABORT, 'Session deletion receipt is immutable'); END;
