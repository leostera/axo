//! One read-only catalog subscription owner. Events invalidate authoritative snapshots; they
//! never replay terminal input, wake Pi, or project an older subscription snapshot over a list.
use crate::{Client, Error, EventStream, LocalCatalog, transport};
use axo_protocol::{Event, ShellActivity, rpc};
use std::{path::Path, sync::Arc, time::Duration};
use tokio::{sync::watch, time::Instant};

const DEADLINE: Duration = Duration::from_secs(5);
const COALESCE: Duration = Duration::from_millis(100);
const MIN_BACKOFF: Duration = Duration::from_millis(250);
const MAX_BACKOFF: Duration = Duration::from_secs(5);

pub enum CatalogState {
    Connecting,
    Reconnecting { reason: String },
    Live(CatalogSnapshot),
}

pub struct CatalogSnapshot {
    /// Changes whenever the subscription is replaced, even if all Session/pane IDs match.
    pub epoch: u64,
    pub catalog: Arc<LocalCatalog>,
    pub health: rpc::DaemonHealth,
}

/// Bounded latest-state mailbox. Dropping it cancels the watcher, including an idle event read,
/// an in-flight bootstrap/catalog read, or reconnect backoff. Refresh is read-only and coalesced.
pub struct CatalogWatch {
    updates: watch::Receiver<Arc<CatalogState>>,
    refresh: watch::Sender<()>,
}
pub struct CatalogWatcher {
    updates: watch::Sender<Arc<CatalogState>>,
    refresh: watch::Receiver<()>,
}
impl CatalogWatch {
    pub fn channel() -> (Self, CatalogWatcher) {
        let (updates, receiver) = watch::channel(Arc::new(CatalogState::Connecting));
        let (refresh, requests) = watch::channel(());
        (
            Self {
                updates: receiver,
                refresh,
            },
            CatalogWatcher {
                updates,
                refresh: requests,
            },
        )
    }

    pub fn refresh(&self) -> Result<(), Error> {
        self.refresh
            .send(())
            .map_err(|_| transport("catalog watcher stopped"))
    }

    /// For native main-loop adapters. No socket I/O or unbounded queued snapshots.
    pub fn take_update(&mut self) -> Result<Option<Arc<CatalogState>>, Error> {
        if !self
            .updates
            .has_changed()
            .map_err(|_| transport("catalog watcher stopped"))?
        {
            return Ok(None);
        }
        Ok(Some(self.updates.borrow_and_update().clone()))
    }

    pub async fn changed(&mut self) -> Result<Arc<CatalogState>, Error> {
        self.updates
            .changed()
            .await
            .map_err(|_| transport("catalog watcher stopped"))?;
        Ok(self.updates.borrow_and_update().clone())
    }
}

struct Connection {
    client: Client,
    events: EventStream,
}
impl CatalogWatcher {
    /// The caller owns the runtime/thread. There is exactly one event stream per watcher and
    /// only negotiate, catalog, health and catalog-subscription requests on its connections.
    pub async fn run(mut self, path: &Path) {
        let mut epoch = 0_u64;
        let mut backoff = MIN_BACKOFF;
        loop {
            let Some(next) = epoch.checked_add(1) else {
                return;
            };
            epoch = next;
            let connected = tokio::select! {
                _ = self.updates.closed() => return,
                result = bounded(async {
                    // Establish this RPC connection first: a daemon restart between opening
                    // the subscription and listing must fail the old RPC, not mix instances.
                    let mut client = Client::connect(path).await?;
                    client.negotiate().await?;
                    let events = EventStream::open(path, serde_json::json!({
                        "includeTerminalOutput": false
                    })).await?;
                    let snapshot = snapshot(&mut client, epoch).await?;
                    Ok((Connection { client, events }, snapshot))
                }) => result,
            };
            let failure = match connected {
                Ok((mut connection, snapshot)) => {
                    if self
                        .updates
                        .send(Arc::new(CatalogState::Live(snapshot)))
                        .is_err()
                    {
                        return;
                    }
                    let began = Instant::now();
                    let result = self.follow(&mut connection, epoch).await;
                    if began.elapsed() >= Duration::from_secs(10) {
                        backoff = MIN_BACKOFF;
                    }
                    match result {
                        Ok(()) => return, // The receiver was dropped.
                        Err(error) => error,
                    }
                }
                Err(error) => error,
            };
            if self
                .updates
                .send(Arc::new(CatalogState::Reconnecting {
                    reason: failure.to_string(),
                }))
                .is_err()
            {
                return;
            }
            tokio::select! {
                _ = self.updates.closed() => return,
                _ = tokio::time::sleep(backoff) => {},
                changed = self.refresh.changed() => if changed.is_err() { return },
            }
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
    }

    async fn follow(&mut self, connection: &mut Connection, epoch: u64) -> Result<(), Error> {
        let mut due = None;
        loop {
            // EventStream::next is deliberately NOT cancel-safe: cancellation poisons it.
            // Keep this same future alive through refresh requests, debounce and RPC reads.
            let next = connection.events.next();
            tokio::pin!(next);
            loop {
                tokio::select! {
                    _ = self.updates.closed() => return Ok(()),
                    batch = &mut next => {
                        let batch = batch?;
                        if batch.lagged() {
                            return Err(transport("catalog subscription lagged; resynchronizing"));
                        }
                        if batch.events().iter().any(invalidates_catalog) {
                            due.get_or_insert(Instant::now() + COALESCE);
                        }
                        break;
                    }
                    changed = self.refresh.changed() => {
                        if changed.is_err() { return Ok(()) }
                        due = Some(Instant::now());
                    }
                    _ = tokio::time::sleep_until(due.unwrap_or_else(|| Instant::now() + Duration::from_secs(3600))), if due.is_some() => {
                        let snapshot = tokio::select! {
                            _ = self.updates.closed() => return Ok(()),
                            result = bounded(snapshot(&mut connection.client, epoch)) => result?,
                        };
                        due = None;
                        if self.updates.send(Arc::new(CatalogState::Live(snapshot))).is_err() {
                            return Ok(());
                        }
                    }
                }
            }
        }
    }
}

async fn bounded<T>(
    operation: impl std::future::Future<Output = Result<T, Error>>,
) -> Result<T, Error> {
    tokio::time::timeout(DEADLINE, operation)
        .await
        .map_err(|_| transport("catalog read timed out; reconnecting read-only"))?
}
async fn snapshot(client: &mut Client, epoch: u64) -> Result<CatalogSnapshot, Error> {
    let catalog = Arc::new(LocalCatalog::load(client).await?);
    let health = client
        .call_typed(rpc::method::DAEMON_HEALTH, serde_json::json!({}))
        .await?;
    Ok(CatalogSnapshot {
        epoch,
        catalog,
        health,
    })
}
fn invalidates_catalog(event: &Event) -> bool {
    matches!(
        event,
        Event::SessionSnapshot { .. }
            | Event::SessionRemoved { .. }
            | Event::DaemonReady
            | Event::ShellActivity {
                activity: ShellActivity::Started | ShellActivity::Exited,
                ..
            }
    )
}

#[cfg(test)]
mod tests;
