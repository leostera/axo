-- Submitted originals are not drafts. No editing buffer, attachment registry,
-- replay queue or recoverable dispatch permission is persisted here.
CREATE TABLE submitted_commands (
    command_id TEXT PRIMARY KEY CHECK (length(command_id) = 36),
    fingerprint BLOB NOT NULL CHECK (length(fingerprint) = 32),
    capture BLOB NOT NULL CHECK (length(capture) <= 131072),
    accepted_revision INTEGER NOT NULL CHECK (accepted_revision BETWEEN 1 AND 9007199254740991)
) STRICT;
CREATE TABLE submitted_results (
    command_id TEXT PRIMARY KEY REFERENCES submitted_commands(command_id),
    result BLOB NOT NULL CHECK (length(result) <= 4096)
) STRICT;
CREATE TRIGGER immutable_submitted_commands_update BEFORE UPDATE ON submitted_commands
BEGIN SELECT RAISE(ABORT, 'Submitted original is immutable'); END;
CREATE TRIGGER immutable_submitted_commands_delete BEFORE DELETE ON submitted_commands
BEGIN SELECT RAISE(ABORT, 'Submitted original is immutable'); END;
CREATE TRIGGER immutable_submitted_results_update BEFORE UPDATE ON submitted_results
BEGIN SELECT RAISE(ABORT, 'Submitted result is immutable'); END;
CREATE TRIGGER immutable_submitted_results_delete BEFORE DELETE ON submitted_results
BEGIN SELECT RAISE(ABORT, 'Submitted result is immutable'); END;
