//! Catalog observation must stay independent of the durable mutation queue.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use axo_ipc::Extension;
use axo_relay::SyncStore;
use jsonrpc_core::IoHandler;
use tokio::time::timeout;

use crate::test_support::Fixture;

fn read_probe(database: &axo_store::Connection) -> io::Result<i64> {
    database
        .query_row("SELECT value FROM catalog_probe", [], |row| row.get(0))
        .map_err(io::Error::other)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn local_and_relay_catalogs_read_committed_state_while_writer_is_blocked() {
    let fixture = Fixture::new().await;
    fixture.core.store.call(|database| {
        database.execute_batch("CREATE TABLE catalog_probe (value INTEGER); INSERT INTO catalog_probe VALUES (1)")
            .map_err(io::Error::other)
    }).await.unwrap();

    let (started, waiting) = tokio::sync::oneshot::channel();
    let (release, held) = std::sync::mpsc::channel();
    let writer = fixture.core.store.clone();
    let committing = tokio::spawn(async move {
        writer
            .call(move |database| {
                let transaction = database.transaction().map_err(io::Error::other)?;
                transaction
                    .execute("UPDATE catalog_probe SET value = 2", [])
                    .map_err(io::Error::other)?;
                started
                    .send(())
                    .map_err(|_| io::Error::other("test ended before writer started"))?;
                held.recv_timeout(Duration::from_secs(10))
                    .map_err(io::Error::other)?;
                transaction.commit().map_err(io::Error::other)
            })
            .await
    });
    timeout(Duration::from_secs(2), waiting)
        .await
        .unwrap()
        .unwrap();

    // These exercise the real consumers, not just the worker's read accessor.
    // If either accidentally uses .call(), it sits behind the held transaction.
    let mut methods = IoHandler::new();
    crate::handlers::Sessions(Arc::clone(&fixture.core)).register(&mut methods);
    let response = timeout(
        Duration::from_secs(2),
        methods.handle_request(
            r#"{"jsonrpc":"2.0","id":1,"method":"axo.session.catalog","params":{}}"#,
        ),
    )
    .await
    .expect("local catalog waited behind writer")
    .unwrap();
    let response: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert!(response.get("error").is_none(), "{response}");
    assert_eq!(response["result"]["sessions"], serde_json::json!([]));
    assert_eq!(response["result"]["archived"], serde_json::json!([]));
    let relay = crate::relay_host::RelayHostAdapter::new(Arc::clone(&fixture.core));
    assert!(
        timeout(Duration::from_secs(2), relay.catalog())
            .await
            .expect("relay catalog waited behind writer")
            .unwrap()
            .is_empty()
    );

    let committed = fixture.core.store.read(read_probe);
    assert_eq!(
        timeout(Duration::from_secs(2), committed)
            .await
            .unwrap()
            .unwrap(),
        1
    );
    assert!(
        !committing.is_finished(),
        "write barrier must still be held"
    );
    release.send(()).unwrap();
    committing.await.unwrap().unwrap();

    // A completed closure must not leave a stale read transaction behind.
    assert_eq!(fixture.core.store.read(read_probe).await.unwrap(), 2);
    let refused = fixture
        .core
        .store
        .read(|database| {
            assert_eq!(read_probe(database)?, 2);
            database
                .execute("UPDATE catalog_probe SET value = 3", [])
                .map(|_| ())
                .map_err(io::Error::other)
        })
        .await;
    assert!(refused.is_err(), "the read lane must not accept SQL writes");
    let (mode, sync) = fixture
        .core
        .store
        .call(|database| {
            database
                .execute("UPDATE catalog_probe SET value = 4", [])
                .map_err(io::Error::other)?;
            Ok((
                database
                    .query_row("PRAGMA journal_mode", [], |row| row.get::<_, String>(0))
                    .map_err(io::Error::other)?,
                database
                    .query_row("PRAGMA synchronous", [], |row| row.get::<_, i64>(0))
                    .map_err(io::Error::other)?,
            ))
        })
        .await
        .unwrap();
    assert_eq!((mode.as_str(), sync), ("wal", 2), "writer remains FULL/WAL");
    assert_eq!(
        fixture.core.store.read(read_probe).await.unwrap(),
        4,
        "failed reads must also end their snapshot"
    );
}
