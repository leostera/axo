use super::*;
use crate::test_support::TestDirectory;

#[test]
fn fresh_authority_has_no_durable_draft_table() {
    let root = TestDirectory::new();
    let database = Database::open(root.path(), MachineId::new()).unwrap();
    let tables: u32 = database
        .connection
        .query_row(
            "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='drafts'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(tables, 0);
}

#[test]
fn retired_central_draft_data_is_not_restored_or_deleted() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let generation = database.generation().unwrap();
    // Synthetic retired data. Deliberately opaque: reopening must not attempt
    // to decode it or treat it as a command, but must preserve existing bytes.
    database.mutate(|tx| {
        tx.execute_batch("CREATE TABLE drafts (address BLOB PRIMARY KEY, scope BLOB NOT NULL, revision TEXT NOT NULL, text BLOB NOT NULL) STRICT;")?;
        tx.execute("INSERT INTO drafts VALUES(?1,?2,?3,?4)", params![vec![7_u8;32],vec![255_u8;8],"retired",vec![254_u8;8]])?;
        Ok(())
    }).unwrap();
    drop(database);
    let before = std::fs::read(root.path().join("session-state.sqlite3")).unwrap();
    let mut database = Database::open(root.path(), machine).unwrap();
    assert_eq!(database.generation().unwrap(), generation);
    assert_eq!(database.revision().unwrap(), 0);
    assert!(database.workspaces().unwrap().is_empty());
    assert_eq!(
        before,
        std::fs::read(root.path().join("session-state.sqlite3")).unwrap()
    );
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    database
        .create_workspace(CommandId::new(), 0, "Workspace", &directory)
        .unwrap();
    drop(database);
    let database = Database::open(root.path(), machine).unwrap();
    let (scope, text): (Vec<u8>, Vec<u8>) = database
        .connection
        .query_row("SELECT scope,text FROM drafts", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();
    assert_eq!(scope, vec![255_u8; 8]);
    assert_eq!(text, vec![254_u8; 8]);
    assert_eq!(database.generation().unwrap(), generation);
    assert_eq!(database.revision().unwrap(), 1);
}
