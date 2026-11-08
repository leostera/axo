//! Cancellation of the request being handled (RFD0034).
//!
//! Each request gets a [`Cancellation`]. The transport cancels it when the request's connection
//! closes before the answer is sent: per AXP §5, the caller has given up on it. A handler that
//! waits (for the person, for the account, for Pi) reads [`current`] and either checks
//! [`Cancellation::is_cancelled`] or registers [`Cancellation::on_cancel`] to wake itself. A
//! handler that does not wait ignores it, and runs to the end as before.
//!
//! Outside a request, [`current`] is a cancellation that never fires.

use std::cell::RefCell;
#[cfg(any(unix, test))]
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// One request's cancellation. Cloning shares it.
#[derive(Clone, Default)]
pub struct Cancellation(Arc<Inner>);

#[derive(Default)]
struct Inner {
    cancelled: AtomicBool,
    /// What to run when it fires; taken (and so run once) by `cancel`.
    callbacks: Mutex<Vec<Box<dyn FnOnce() + Send>>>,
}

impl Cancellation {
    /// Fires it: runs every callback registered so far, once, and every one registered later
    /// at once.
    pub fn cancel(&self) {
        if self.0.cancelled.swap(true, Ordering::SeqCst) {
            return;
        }
        let callbacks = std::mem::take(&mut *self.callbacks());
        for callback in callbacks {
            callback();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::SeqCst)
    }

    /// Runs `callback` when this fires, or now if it already has. Callbacks run on the thread
    /// that cancels, so they must be quick: wake a waiter, don't do its work.
    pub fn on_cancel(&self, callback: impl FnOnce() + Send + 'static) {
        let mut callbacks = self.callbacks();
        // Checked under the lock `cancel` takes after setting the flag: a callback is either
        // taken by `cancel` or run here, never neither.
        if self.is_cancelled() {
            drop(callbacks);
            callback();
            return;
        }
        callbacks.push(Box::new(callback));
    }

    fn callbacks(&self) -> std::sync::MutexGuard<'_, Vec<Box<dyn FnOnce() + Send>>> {
        self.0
            .callbacks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

tokio::task_local! {
    static TASK_CANCELLATION: Cancellation;
}

thread_local! {
    static THREAD_CANCELLATION: RefCell<Option<Cancellation>> = const { RefCell::new(None) };
}

/// The cancellation of the request being handled; one that never fires outside a request.
pub fn current() -> Cancellation {
    THREAD_CANCELLATION
        .with(|cell| cell.borrow().clone())
        .or_else(|| TASK_CANCELLATION.try_with(Clone::clone).ok())
        .unwrap_or_default()
}

/// Runs `request` with `cancellation` as [`current`], for an async handler.
#[cfg(any(unix, test))]
pub(crate) async fn scope<F: Future>(cancellation: Cancellation, request: F) -> F::Output {
    TASK_CANCELLATION.scope(cancellation, request).await
}

/// Runs `method` with `cancellation` as [`current`], for a handler on the blocking pool.
#[cfg(any(unix, test))]
pub(crate) fn on_this_thread<R>(cancellation: Cancellation, method: impl FnOnce() -> R) -> R {
    let previous = THREAD_CANCELLATION.with(|cell| cell.replace(Some(cancellation)));
    let result = method();
    THREAD_CANCELLATION.with(|cell| *cell.borrow_mut() = previous);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn callbacks_run_once_whether_registered_before_or_after_it_fires() {
        let cancellation = Cancellation::default();
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = || {
            let runs = Arc::clone(&runs);
            move || {
                runs.fetch_add(1, Ordering::SeqCst);
            }
        };
        cancellation.on_cancel(counted());
        assert_eq!(runs.load(Ordering::SeqCst), 0);
        cancellation.cancel();
        cancellation.cancel();
        assert_eq!(
            runs.load(Ordering::SeqCst),
            1,
            "fired once, however often it is cancelled"
        );
        cancellation.on_cancel(counted());
        assert_eq!(
            runs.load(Ordering::SeqCst),
            2,
            "a late callback runs at once"
        );
        assert!(cancellation.is_cancelled());
    }

    #[test]
    fn outside_a_request_nothing_is_cancelled() {
        assert!(!current().is_cancelled());
    }

    #[test]
    fn the_current_cancellation_is_the_requests_on_the_blocking_pool_and_only_there() {
        let cancellation = Cancellation::default();
        cancellation.cancel();
        assert!(on_this_thread(cancellation, || current().is_cancelled()));
        assert!(!current().is_cancelled());
    }

    #[test]
    fn an_async_handler_sees_its_requests_cancellation() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let cancellation = Cancellation::default();
        let seen = runtime.block_on(scope(cancellation.clone(), async { current() }));
        cancellation.cancel();
        assert!(seen.is_cancelled());
    }
}
