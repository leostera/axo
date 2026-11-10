//! The one SQLite connection (RFD0041): `tokio-rusqlite` runs it on a thread of its own, and every
//! read and write is a call to it. `axo-store` keeps the SQL; this only carries calls to it.

use std::io;

use axo_store::Connection;

/// A handle to the store's thread. Cheap to clone; every clone reaches the same connection.
#[derive(Clone)]
pub(crate) struct Store {
    connection: tokio_rusqlite::Connection,
}

impl Store {
    /// Takes over a connection already opened and migrated.
    pub(crate) fn new(connection: Connection) -> Self {
        Self {
            connection: tokio_rusqlite::Connection::from(connection),
        }
    }

    /// Runs `call` on the store's thread.
    pub(crate) async fn call<R, F>(&self, call: F) -> io::Result<R>
    where
        F: FnOnce(&mut Connection) -> io::Result<R> + Send + 'static,
        R: Send + 'static,
    {
        self.connection
            .call(call)
            .await
            .map_err(|error| match error {
                tokio_rusqlite::Error::Error(error) => error,
                other => io::Error::other(other.to_string()),
            })
    }
}
