# axo-store

Axod's SQLite catalog: the schema and its migrations, and every read and write that touches only the database. It knows no processes, files or settings syntax; `axo-server` owns the connection and holds its catalog lock around these calls.

`open` is the only way to get a connection: WAL with `synchronous=FULL` (a write is durable once it returns), foreign keys on, the file readable only by its owner, migrated to `SCHEMA_VERSION`. A catalog about to be rekeyed by UUID is copied to `axo.db.pre-uuid` first.

## Layout

| Module | Owns |
| --- | --- |
| `schema` | `open`, `initialize_database`, the current tables and indexes, `SCHEMA_VERSION` |
| `migrations` | Upgrading older catalogs: added columns, the Workspace cutover (v4), rekeying Sessions by UUID (v9, RFD0017) |
| `sessions` | Session rows: creating a Session with its panes, reading open and archived Sessions, names, layouts, archiving and reopening |
| `shells` | Shell (pane) rows: inserting terminals, archiving one pane and pruning it from the layout |
| `pi` | Each Session's Pi history file, bridge socket path and bridge credential |
| `metadata` | `daemon_metadata`: settings, the host ID, the last client viewport |
| `host_link` | The host's link to an Axo account (one row) |
| `sync` | `relay_sync`: what the cloud acknowledged of each transcript (RFD0018, RFD0027) |
| `rows` | Parsed IDs and lifecycle states, timestamps, the "exactly one row changed" check |

Every module is re-exported from the crate root, so callers write `axo_store::archive_session`.

## Rules

- Reads parse what they return: a malformed Session ID, shell ID or lifecycle state fails the query instead of reaching callers.
- Writes to open rows check that exactly one row changed and return `NotFound` otherwise, so a write to a closed Session is an error, not a no-op.
- Changes that span tables (creating a Session with its panes, reopening a Session) run in one transaction.
- Every query has a test against an in-memory database, next to it; shared fixtures are in `test_support`.

## Build and test

```sh
bazel build //crates/axo-store
bazel test //crates/axo-store:axo_store_tests
```
