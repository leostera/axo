//! Transcripts the cloud keeps for archived Sessions (RFD0027): deleted here only as the cloud
//! acknowledged them, and back in place before a Session reopens.

use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;

use axo_protocol::SessionId;

use crate::core::Core;
use crate::relay_host::{
    evict_transcript, lock_file, reopened_with_transcript, restore_transcript,
};
use crate::test_support::Fixture;

const LINES: &str = "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"cwd\":\"/tmp\"}\n\
    {\"id\":\"a\",\"parentId\":null}\n{\"id\":\"b\",\"parentId\":\"a\"}\n";

/// An archived Session whose transcript the cloud acknowledged whole.
async fn archived(fixture: &Fixture) -> (SessionId, PathBuf, String) {
    let session_id = SessionId::new_v4().unwrap();
    let file = fixture.directory.join(format!("{session_id}.jsonl"));
    fs::write(&file, LINES).unwrap();
    fs::write(lock_file(&file), b"").unwrap();
    let (count, chain) = axo_agent::pi::transcript_chain(&file).unwrap().unwrap();
    assert_eq!(count, 2);
    let (stored_file, stored_chain) = (file.clone(), chain.clone());
    fixture
        .core
        .store
        .call(move |database| {
            database
                .execute(
                    "INSERT INTO sessions (id, initial_pwd, state, created_at, pi_session_file) \
                     VALUES (?1, '/tmp', 'archived', 1, ?2)",
                    rusqlite::params![session_id.to_string(), stored_file.to_string_lossy()],
                )
                .map_err(io::Error::other)?;
            axo_store::store_sync_cursor(database, &session_id.to_string(), 2, &stored_chain)
        })
        .await
        .unwrap();
    (session_id, file, chain)
}

async fn in_cloud(fixture: &Fixture, session_id: SessionId) -> bool {
    fixture
        .core
        .store
        .call(move |database| {
            axo_store::load_transcript(database, Some(&session_id.to_string()), None)
        })
        .await
        .unwrap()
        .unwrap()
        .in_cloud
}

async fn evict(core: &Arc<Core>, id: SessionId, position: u64, chain: &str, length: u64) -> bool {
    let (core, chain) = (Arc::clone(core), chain.to_owned());
    tokio::task::spawn_blocking(move || evict_transcript(&core, id, position, &chain, length))
        .await
        .unwrap()
        .unwrap()
}

async fn reopen(fixture: &Fixture, id: SessionId) -> io::Result<()> {
    fixture
        .core
        .store
        .call(move |database| reopened_with_transcript(database, id))
        .await
}

#[tokio::test(flavor = "multi_thread")]
async fn a_transcript_is_deleted_only_as_the_cloud_acknowledged_it_and_recorded_first() {
    let fixture = Fixture::new().await;
    let core = &fixture.core;
    let (id, file, chain) = archived(&fixture).await;
    let length = fs::metadata(&file).unwrap().len();

    assert!(
        !evict(core, id, 2, &chain, length + 1).await,
        "changed since"
    );
    assert!(
        !evict(core, id, 3, &chain, length).await,
        "not acknowledged"
    );
    assert!(!evict(core, id, 2, "other", length).await, "another chain");
    assert!(file.exists() && !in_cloud(&fixture, id).await);

    assert!(evict(core, id, 2, &chain, length).await);
    assert!(!file.exists() && !lock_file(&file).exists());
    assert!(in_cloud(&fixture, id).await);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_open_session_keeps_its_transcript() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let file = PathBuf::from(record.pi_session_file.clone().unwrap());
    fs::write(&file, LINES).unwrap();
    let (_, chain) = axo_agent::pi::transcript_chain(&file).unwrap().unwrap();
    let length = fs::metadata(&file).unwrap().len();
    assert!(!evict(&fixture.core, record.id, 2, &chain, length).await);
    assert!(file.exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_reopens_only_with_the_transcript_the_cloud_acknowledged_back_in_place() {
    let fixture = Fixture::new().await;
    let (id, file, chain) = archived(&fixture).await;
    let length = fs::metadata(&file).unwrap().len();
    assert!(evict(&fixture.core, id, 2, &chain, length).await);

    let refused = reopen(&fixture, id).await.unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::NotFound, "not back");
    fs::write(&file, &LINES[..LINES.len() - 10]).unwrap();
    let refused = reopen(&fixture, id).await.unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::NotFound, "only part of it");
    assert!(in_cloud(&fixture, id).await);

    // A crash between recording and deleting leaves the file: nothing needs fetching.
    fs::write(&file, LINES).unwrap();
    restore_transcript(&fixture.core, Some(id), None)
        .await
        .unwrap();
    reopen(&fixture, id).await.unwrap();
    assert!(!in_cloud(&fixture, id).await);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_transcript_that_cannot_be_fetched_fails_the_reopen_and_changes_nothing() {
    let fixture = Fixture::new().await;
    let (id, file, chain) = archived(&fixture).await;
    let length = fs::metadata(&file).unwrap().len();
    assert!(evict(&fixture.core, id, 2, &chain, length).await);
    // This Mac does not follow the account here: there is nothing to fetch it through.
    assert!(
        restore_transcript(&fixture.core, Some(id), None)
            .await
            .is_err()
    );
    assert!(!file.exists() && in_cloud(&fixture, id).await);
}
