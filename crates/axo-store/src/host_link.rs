//! `host_link`: this host's link to an Axo account, a single row.

use std::io;

use rusqlite::{Connection, OptionalExtension, params};

/// This host's link to an Axo account, as stored. Each group of columns is set together (the
/// table enforces it); parsing the identifiers is the relay's job.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct StoredHostLink {
    pub account: Option<StoredAccountLink>,
    pub pending_redemption: Option<StoredPendingRedemption>,
}

/// The account this host is linked to, and the credential it connects with.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredAccountLink {
    pub account_id: String,
    pub credential_id: String,
}

/// A redemption that was started but not confirmed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredPendingRedemption {
    pub credential_id: String,
    pub host_generation: String,
}

pub fn load_host_link(database: &Connection) -> io::Result<StoredHostLink> {
    let row = database
        .query_row(
            "SELECT account_id, credential_id, pending_credential_id, pending_host_generation \
             FROM host_link WHERE singleton = 1",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .optional()
        .map_err(io::Error::other)?;
    let Some((account_id, credential_id, pending_credential_id, pending_host_generation)) = row
    else {
        return Ok(StoredHostLink::default());
    };
    Ok(StoredHostLink {
        account: account_id
            .zip(credential_id)
            .map(|(account_id, credential_id)| StoredAccountLink {
                account_id,
                credential_id,
            }),
        pending_redemption: pending_credential_id.zip(pending_host_generation).map(
            |(credential_id, host_generation)| StoredPendingRedemption {
                credential_id,
                host_generation,
            },
        ),
    })
}

pub fn store_host_link(database: &Connection, link: &StoredHostLink) -> io::Result<()> {
    let account = link.account.as_ref();
    let pending = link.pending_redemption.as_ref();
    let account_id = account.map(|account| &account.account_id);
    let credential_id = account.map(|account| &account.credential_id);
    let pending_credential_id = pending.map(|pending| &pending.credential_id);
    let pending_host_generation = pending.map(|pending| &pending.host_generation);
    database
        .execute(
            "INSERT INTO host_link \
             (singleton, account_id, credential_id, pending_credential_id, pending_host_generation) \
             VALUES (1, ?1, ?2, ?3, ?4) \
             ON CONFLICT(singleton) DO UPDATE SET account_id = excluded.account_id, \
             credential_id = excluded.credential_id, \
             pending_credential_id = excluded.pending_credential_id, \
             pending_host_generation = excluded.pending_host_generation",
            params![
                account_id,
                credential_id,
                pending_credential_id,
                pending_host_generation
            ],
        )
        .map(drop)
        .map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::database;

    #[test]
    fn host_link_round_trips_and_its_column_pairs_stay_together() {
        let database = database();
        assert_eq!(
            load_host_link(&database).unwrap(),
            StoredHostLink::default()
        );
        let pending = StoredHostLink {
            account: None,
            pending_redemption: Some(StoredPendingRedemption {
                credential_id: "credential-1".into(),
                host_generation: "generation-1".into(),
            }),
        };
        store_host_link(&database, &pending).unwrap();
        assert_eq!(load_host_link(&database).unwrap(), pending);
        let linked = StoredHostLink {
            account: Some(StoredAccountLink {
                account_id: "account-1".into(),
                credential_id: "credential-1".into(),
            }),
            pending_redemption: None,
        };
        store_host_link(&database, &linked).unwrap();
        assert_eq!(load_host_link(&database).unwrap(), linked);
        store_host_link(&database, &StoredHostLink::default()).unwrap();
        assert_eq!(
            load_host_link(&database).unwrap(),
            StoredHostLink::default()
        );

        for half in [
            "INSERT OR REPLACE INTO host_link (singleton, account_id) VALUES (1, 'a')",
            "INSERT OR REPLACE INTO host_link (singleton, pending_credential_id) VALUES (1, 'c')",
        ] {
            assert!(database.execute(half, []).is_err(), "{half}");
        }
    }
}
