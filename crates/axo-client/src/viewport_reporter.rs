//! Serial latest-value viewport publication. Unlike CatalogWatcher this is an explicitly
//! mutating UI owner; uncertain acknowledgements fence further automatic sends in that epoch.
use crate::{Client, Error, transport};
use axo_protocol::{Viewport, rpc};
use std::{
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use tokio::sync::watch;

const DEBOUNCE: Duration = Duration::from_millis(100);
const DEADLINE: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ViewportPhase {
    Idle,
    Sending,
    Published,
    Unsupported,
    Uncertain { reason: String },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewportStatus {
    pub epoch: u64,
    pub phase: ViewportPhase,
}
#[derive(Clone, Copy, Debug, PartialEq)]
struct Intent {
    epoch: u64,
    retry: u64,
    viewport: Viewport,
}
impl Intent {
    fn attempt(&self) -> (u64, u64) {
        (self.epoch, self.retry)
    }
}

pub struct ViewportReporter {
    desired: watch::Sender<Option<Intent>>,
    status: watch::Receiver<ViewportStatus>,
    retry: AtomicU64,
}
pub struct ViewportWorker {
    desired: watch::Receiver<Option<Intent>>,
    status: watch::Sender<ViewportStatus>,
}
impl ViewportReporter {
    pub fn channel() -> (Self, ViewportWorker) {
        let (desired, receiver) = watch::channel(None);
        let (status, updates) = watch::channel(ViewportStatus {
            epoch: 0,
            phase: ViewportPhase::Idle,
        });
        (
            Self {
                desired,
                status: updates,
                retry: AtomicU64::new(0),
            },
            ViewportWorker {
                desired: receiver,
                status,
            },
        )
    }
    pub fn report(&self, epoch: u64, viewport: Viewport) -> Result<(), Error> {
        if epoch == 0 || !viewport.is_native() {
            return Err(Error::Input(
                "native metrics and a live epoch are required".into(),
            ));
        }
        if self.desired.is_closed() {
            return Err(transport("viewport reporter stopped"));
        }
        let intent = Some(Intent {
            epoch,
            retry: self.retry.load(Ordering::Relaxed),
            viewport,
        });
        self.desired.send_if_modified(|desired| {
            if *desired == intent {
                false
            } else {
                *desired = intent;
                true
            }
        });
        Ok(())
    }
    pub fn suspend(&self) {
        self.desired.send_replace(None);
    }
    /// Only an explicit person-directed refresh or a new epoch permits another uncertain send.
    /// Geometry changes alone never clear that fence. This is an idempotent geometry setter,
    /// not a general retry facility for Session actions or settings saves.
    pub fn retry(&self) -> Result<(), Error> {
        let previous = self
            .retry
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
            .map_err(|_| transport("viewport retry generation exhausted"))?;
        if self.desired.is_closed() {
            return Err(transport("viewport reporter stopped"));
        }
        self.desired.send_modify(|desired| {
            if let Some(intent) = desired {
                intent.retry = previous + 1;
            }
        });
        Ok(())
    }
    pub fn take_status(&mut self) -> Result<Option<ViewportStatus>, Error> {
        if !self
            .status
            .has_changed()
            .map_err(|_| transport("viewport reporter stopped"))?
        {
            return Ok(None);
        }
        Ok(Some(self.status.borrow_and_update().clone()))
    }
    pub async fn changed(&mut self) -> Result<ViewportStatus, Error> {
        self.status
            .changed()
            .await
            .map_err(|_| transport("viewport reporter stopped"))?;
        Ok(self.status.borrow_and_update().clone())
    }
}
impl ViewportWorker {
    pub async fn run(mut self, path: &Path) {
        let mut sent = None;
        let mut uncertain = None;
        loop {
            let intent = *self.desired.borrow_and_update();
            let eligible = intent
                .filter(|intent| Some(*intent) != sent && Some(intent.attempt()) != uncertain);
            let Some(_) = eligible else {
                tokio::select! {
                    _ = self.status.closed() => return,
                    changed = self.desired.changed() => if changed.is_err() { return },
                }
                continue;
            };
            tokio::select! {
                _ = self.status.closed() => return,
                changed = self.desired.changed() => { if changed.is_err() { return } continue },
                _ = tokio::time::sleep(DEBOUNCE) => {},
            }
            let Some(intent) = *self.desired.borrow_and_update() else {
                continue;
            };
            if Some(intent) == sent || Some(intent.attempt()) == uncertain {
                continue;
            }
            if self
                .status
                .send(ViewportStatus {
                    epoch: intent.epoch,
                    phase: ViewportPhase::Sending,
                })
                .is_err()
            {
                return;
            }
            // Never cancel an admitted write because a newer size arrived. Finish this one,
            // then publish only the latest pending size, or fence the epoch on uncertainty.
            let result = tokio::select! {
                _ = self.status.closed() => return,
                result = tokio::time::timeout(DEADLINE, publish(path, intent.viewport)) =>
                    result.unwrap_or_else(|_| Err(transport("viewport update timed out; outcome unconfirmed"))),
            };
            let phase = match result {
                Ok(true) => {
                    sent = Some(intent);
                    ViewportPhase::Published
                }
                Ok(false) => {
                    uncertain = Some(intent.attempt());
                    ViewportPhase::Unsupported
                }
                Err(error) => {
                    uncertain = Some(intent.attempt());
                    ViewportPhase::Uncertain {
                        reason: error.to_string(),
                    }
                }
            };
            if self
                .status
                .send(ViewportStatus {
                    epoch: intent.epoch,
                    phase,
                })
                .is_err()
            {
                return;
            }
        }
    }
}
async fn publish(path: &Path, viewport: Viewport) -> Result<bool, Error> {
    let mut client = Client::connect(path).await?;
    client.negotiate().await?;
    if !client.supports(rpc::method::CLIENT_VIEWPORT_SET_V2) {
        return Ok(false);
    }
    let accepted: rpc::ViewportAccepted = client
        .call_typed(
            rpc::method::CLIENT_VIEWPORT_SET_V2,
            serde_json::to_value(viewport).expect("validated viewport serializes"),
        )
        .await?;
    if !accepted.accepted {
        return Err(transport("viewport update was not acknowledged"));
    }
    Ok(true)
}

#[cfg(test)]
mod tests;
