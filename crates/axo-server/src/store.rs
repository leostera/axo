//! One serialized durable writer and one read-only WAL snapshot worker (RFD0089).
//! Catalog reads must not queue behind slow commits; mutation-dependent operations
//! keep their existing ordering on the writer. `axo-store` owns the SQL.

use std::io;

use axo_store::{Connection, ReadOnlyConnection};

/// Clones share the same two workers, never a connection per request.
#[derive(Clone)]
pub(crate) struct Store {
    writer: tokio_rusqlite::Connection,
    reader: tokio_rusqlite::Connection,
}

impl Store {
    /// Both connections are opened at bootstrap, after migration, on the same WAL file.
    pub(crate) fn new(writer: Connection, reader: ReadOnlyConnection) -> Self {
        Self {
            writer: tokio_rusqlite::Connection::from(writer),
            reader: tokio_rusqlite::Connection::from(reader.into_connection()),
        }
    }

    /// Runs a mutation or mutation-dependent operation on the serialized writer.
    pub(crate) async fn call<R, F>(&self, call: F) -> io::Result<R>
    where
        F: FnOnce(&mut Connection) -> io::Result<R> + Send + 'static,
        R: Send + 'static,
    {
        self.writer.call(call).await.map_err(|error| match error {
            tokio_rusqlite::Error::Error(error) => error,
            other => io::Error::other(other.to_string()),
        })
    }

    /// Catalog SELECTs in a short read-only transaction, ended even on error.
    /// No snapshot survives into the next read.
    pub(crate) async fn read<R, F>(&self, read: F) -> io::Result<R>
    where
        F: FnOnce(&Connection) -> io::Result<R> + Send + 'static,
        R: Send + 'static,
    {
        self.reader
            .call(move |database| {
                let transaction = database.transaction().map_err(io::Error::other)?;
                let result = read(&transaction);
                transaction.rollback().map_err(io::Error::other)?;
                result
            })
            .await
            .map_err(|error| match error {
                tokio_rusqlite::Error::Error(error) => error,
                other => io::Error::other(other.to_string()),
            })
    }
}
