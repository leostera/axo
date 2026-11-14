//! A relay session owns cancellation, while each task owns its slot and termination cleanup.
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use tokio::sync::watch;

use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::BUSY;

#[derive(Clone)]
struct Entry {
    cancel: watch::Sender<bool>,
    done: watch::Receiver<bool>,
}
#[derive(Default)]
struct State {
    closed: bool,
    jobs: HashMap<String, Entry>,
}
#[derive(Default)]
pub(super) struct OwnedJobs {
    state: Arc<Mutex<State>>,
}
impl OwnedJobs {
    pub(super) fn start(&self, id: &str) -> Result<OwnedJob, MethodError> {
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        if state.closed || state.jobs.contains_key(id) {
            return Err(MethodError::new(
                BUSY,
                "job owner closed or call ID already active",
            ));
        }
        let (cancel, cancelled) = watch::channel(false);
        let (done, completed) = watch::channel(false);
        state.jobs.insert(
            id.to_owned(),
            Entry {
                cancel,
                done: completed,
            },
        );
        Ok(OwnedJob {
            id: id.to_owned(),
            state: Arc::downgrade(&self.state),
            cancelled,
            done,
        })
    }
    pub(super) async fn cancel(&self, id: &str) -> bool {
        let entry = self
            .state
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .jobs
            .get(id)
            .cloned();
        let Some(mut entry) = entry else {
            return false;
        };
        let _ = entry.cancel.send(true);
        while !*entry.done.borrow() {
            if entry.done.changed().await.is_err() {
                break;
            }
        }
        true
    }
    pub(super) fn close(&self) {
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        state.closed = true;
        for entry in state.jobs.values() {
            let _ = entry.cancel.send(true);
        }
    }
}
impl Drop for OwnedJobs {
    fn drop(&mut self) {
        self.close();
    }
}

pub(super) struct OwnedJob {
    id: String,
    state: Weak<Mutex<State>>,
    cancelled: watch::Receiver<bool>,
    done: watch::Sender<bool>,
}
impl OwnedJob {
    pub(super) async fn cancelled(&mut self) {
        loop {
            if *self.cancelled.borrow() {
                return;
            }
            if self.cancelled.changed().await.is_err() {
                return;
            }
        }
    }
}
impl Drop for OwnedJob {
    fn drop(&mut self) {
        if let Some(state) = self.state.upgrade() {
            state
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .jobs
                .remove(&self.id);
        }
        let _ = self.done.send(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn cancellation_is_scoped_and_waits_for_the_owner_to_finish() {
        let jobs = Arc::new(OwnedJobs::default());
        let mut first = jobs.start("first").unwrap();
        let second = jobs.start("second").unwrap();
        assert!(jobs.start("first").is_err());
        let caller = Arc::clone(&jobs);
        let cancel = tokio::spawn(async move { caller.cancel("first").await });
        first.cancelled().await;
        assert!(
            !cancel.is_finished(),
            "requesting cancellation is not cleanup completion"
        );
        assert!(!*second.cancelled.borrow());
        drop(first);
        assert!(cancel.await.unwrap());
        assert!(!jobs.cancel("first").await);
        drop(second);
        assert!(jobs.start("first").is_ok());
    }
    #[tokio::test]
    async fn closing_the_socket_cancels_jobs_and_permanently_closes_admission() {
        let jobs = OwnedJobs::default();
        let mut job = jobs.start("work").unwrap();
        jobs.close();
        job.cancelled().await;
        assert!(jobs.start("later").is_err());
        drop(job);
    }
}
