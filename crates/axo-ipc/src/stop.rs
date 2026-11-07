//! Stopping axod (RFD0034): one flag that tasks wait on and threads check.
//!
//! Waiting costs nothing: [`Stop::stopped`] is woken by [`Stop::stop`], so nothing polls a flag
//! on a timer to notice it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::Notify;

/// Whether axod is stopping. Cloning shares it.
#[derive(Clone, Default)]
pub struct Stop(Arc<Inner>);

#[derive(Default)]
struct Inner {
    stopped: AtomicBool,
    woken: Notify,
    /// For threads that wait on it.
    changed: std::sync::Condvar,
    lock: std::sync::Mutex<()>,
}

impl Stop {
    /// Stops: wakes every task and thread waiting on it, now and later.
    pub fn stop(&self) {
        self.0.stopped.store(true, Ordering::SeqCst);
        self.0.woken.notify_waiters();
        let _guard = self
            .0
            .lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.0.changed.notify_all();
    }

    pub fn is_stopped(&self) -> bool {
        self.0.stopped.load(Ordering::SeqCst)
    }

    /// Until it is stopped; at once if it already is.
    pub async fn stopped(&self) {
        loop {
            let woken = self.0.woken.notified();
            let mut woken = std::pin::pin!(woken);
            // Registered before the flag is read, so a stop between the two still wakes it.
            woken.as_mut().enable();
            if self.is_stopped() {
                return;
            }
            woken.await;
        }
    }

    /// For a thread: waits up to `timeout`; true if it stopped.
    pub fn wait(&self, timeout: Duration) -> bool {
        let guard = self
            .0
            .lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let _ = self
            .0
            .changed
            .wait_timeout_while(guard, timeout, |_| !self.is_stopped());
        self.is_stopped()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn a_task_and_a_thread_both_wake_when_it_stops() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let stop = Stop::default();
        let thread = {
            let stop = stop.clone();
            std::thread::spawn(move || stop.wait(Duration::from_secs(10)))
        };
        let stopping = {
            let stop = stop.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(50));
                stop.stop();
            })
        };
        let started = Instant::now();
        runtime.block_on(stop.stopped());
        assert!(thread.join().unwrap(), "the thread saw it stop");
        assert!(started.elapsed() < Duration::from_secs(2));
        stopping.join().unwrap();
        // Once stopped, waiting returns at once.
        runtime.block_on(stop.stopped());
        assert!(stop.wait(Duration::from_secs(10)));
    }

    #[test]
    fn a_thread_that_waits_out_its_time_says_it_did_not_stop() {
        let stop = Stop::default();
        assert!(!stop.wait(Duration::from_millis(20)));
        assert!(!stop.is_stopped());
    }
}
