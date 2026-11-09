//! Axod's SQLite catalog: the schema and its migrations, and every read and write that touches
//! only the database. Processes, files and settings parsing stay in `axo-server`, which owns the
//! connection and holds its catalog lock around these calls.
//!
//! Every function takes the connection (or a transaction) explicitly and maps SQLite errors to
//! `io::Error`. Modules follow the tables:
//!
//! | Module | Owns |
//! | --- | --- |
//! | `schema` | `open`, the current schema, `SCHEMA_VERSION` |
//! | `migrations` | Upgrading older catalogs, including the UUID rekey (RFD0017) |
//! | `sessions` | Session rows: create, read, rename, layout, archive, reopen |
//! | `shells` | Shell (pane) rows |
//! | `pi` | Each Session's Pi history file, bridge socket and credential |
//! | `metadata` | `daemon_metadata`: settings, host identity, viewport |
//! | `host_link` | The host's link to an Axo account |
//! | `sync` | `relay_sync`: cloud transcript cursors (RFD0018, RFD0027) |
//! | `rows` | Parsed IDs, lifecycle states, timestamps, row-count checks |

mod host_link;
mod metadata;
mod migrations;
mod pi;
mod rows;
mod schema;
mod sessions;
mod shells;
mod sync;

#[cfg(test)]
mod test_support;

pub use host_link::*;
pub use metadata::*;
pub use migrations::*;
pub use pi::*;
pub use rows::*;
pub use schema::*;
pub use sessions::*;
pub use shells::*;
pub use sync::*;

pub use rusqlite::Connection;

/// The catalog's file name inside Axod's server directory.
pub const DATABASE_FILE: &str = "axo.db";
