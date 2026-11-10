//! The one SQLite connection (RFD0041): `tokio-rusqlite` runs it on a thread of its own, and every
//! read and write is a call to it. `axo-store` keeps the SQL; this only carries calls to it.

use std::io;

use axo_store::Connection;

/// A handle to the store's thread. Cheap to clone; every clone reaches the same connection.
#[derive(Clone)]
pub(crate) struct Store {
    connection: tokio_rusqlite::Connection,
    runtime: tokio::runtime::Handle,
}

impl Store {
    /// Takes over a connection already opened and migrated. `runtime` is where synchronous
    /// callers' calls are carried.
    pub(crate) fn new(connection: Connection, runtime: tokio::runtime::Handle) -> Self {
        Self {
            connection: tokio_rusqlite::Connection::from(connection),
            runtime,
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

    /// [`Self::call`] for a caller outside the runtime's tasks: the relay's synchronous calls,
    /// which run on its blocking pool. Never call it from a task.
    pub(crate) fn call_blocking<R, F>(&self, call: F) -> io::Result<R>
    where
        F: FnOnce(&mut Connection) -> io::Result<R> + Send + 'static,
        R: Send + 'static,
    {
        self.runtime.block_on(self.call(call))
    }
}
