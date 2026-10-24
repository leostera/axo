//! A bounded per-subscription event queue with both blocking and async waiters.
//!
//! Publishers never block: a full queue marks the subscription lagged and the next take returns
//! the queue's lag marker alone (discarding the gapped backlog) instead of presenting a silent
//! gap.
//! Async waiters are plain futures, so many concurrent long-polls cost no threads.

use std::collections::VecDeque;
use std::io;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use tokio::sync::Notify;

pub struct EventQueue<T> {
    state: Mutex<QueueState<T>>,
    capacity: usize,
    /// Delivered alone, in place of the discarded backlog, after the queue overflowed.
    lag_marker: fn() -> T,
    /// Wakes blocking waiters.
    ready: Condvar,
    /// Wakes async waiters.
    notify: Notify,
}

struct QueueState<T> {
    events: VecDeque<T>,
    lagged: bool,
    closed: bool,
}

/// Why `push` did not enqueue.
#[derive(Debug, Eq, PartialEq)]
pub enum PushOutcome {
    Queued,
    /// The queue was full; the subscriber will be told it lagged.
    Lagged,
    Closed,
}

impl<T> EventQueue<T> {
    pub fn new(capacity: usize, lag_marker: fn() -> T) -> Self {
        Self {
            state: Mutex::new(QueueState {
                events: VecDeque::new(),
                lagged: false,
                closed: false,
            }),
            capacity,
            lag_marker,
            ready: Condvar::new(),
            notify: Notify::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, QueueState<T>> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn push(&self, event: T) -> PushOutcome {
        let outcome = {
            let mut state = self.lock();
            if state.closed {
                return PushOutcome::Closed;
            }
            if state.lagged {
                // Already gapped: everything until the lag report is discarded anyway.
                PushOutcome::Lagged
            } else if state.events.len() >= self.capacity {
                state.lagged = true;
                PushOutcome::Lagged
            } else {
                state.events.push_back(event);
                PushOutcome::Queued
            }
        };
        self.wake();
        outcome
    }

    /// Ends the subscription; current and future waiters fail with `NotFound`.
    pub fn close(&self) {
        self.lock().closed = true;
        self.wake();
    }

    fn wake(&self) {
        self.ready.notify_all();
        self.notify.notify_waiters();
    }

    /// Takes up to `max_events` without waiting. `None` means nothing is ready.
    fn take(&self, state: &mut QueueState<T>, max_events: usize) -> Option<io::Result<Vec<T>>> {
        if state.closed {
            return Some(Err(io::Error::new(
                io::ErrorKind::NotFound,
                "subscription is closed",
            )));
        }
        if state.lagged {
            state.lagged = false;
            state.events.clear();
            return Some(Ok(vec![(self.lag_marker)()]));
        }
        if state.events.is_empty() {
            return None;
        }
        let count = state.events.len().min(max_events.max(1));
        Some(Ok(state.events.drain(..count).collect()))
    }

    /// Blocks the calling thread for up to `timeout`. An empty result means it timed out.
    pub fn wait_blocking(&self, timeout: Duration, max_events: usize) -> io::Result<Vec<T>> {
        let deadline = Instant::now() + timeout;
        let mut state = self.lock();
        loop {
            if let Some(result) = self.take(&mut state, max_events) {
                return result;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Ok(Vec::new());
            }
            state = self
                .ready
                .wait_timeout(state, remaining)
                .map(|(state, _)| state)
                .unwrap_or_else(|poisoned| poisoned.into_inner().0);
        }
    }

    /// Waits up to `timeout` without blocking a thread. An empty result means it timed out.
    pub async fn wait(&self, timeout: Duration, max_events: usize) -> io::Result<Vec<T>> {
        let waiting = async {
            loop {
                // Register before checking so a push between the check and the await still wakes us.
                let mut notified = std::pin::pin!(self.notify.notified());
                notified.as_mut().enable();
                if let Some(result) = self.take(&mut self.lock(), max_events) {
                    return result;
                }
                notified.await;
            }
        };
        tokio::time::timeout(timeout, waiting)
            .await
            .unwrap_or_else(|_| Ok(Vec::new()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LAGGED: i64 = -1;

    fn queue_of(capacity: usize) -> EventQueue<i64> {
        EventQueue::new(capacity, || LAGGED)
    }
    use std::sync::Arc;

    #[test]
    fn full_queue_reports_lag_once_and_discards_the_gapped_backlog() {
        let queue = queue_of(2);
        assert_eq!(queue.push(1), PushOutcome::Queued);
        assert_eq!(queue.push(2), PushOutcome::Queued);
        assert_eq!(queue.push(3), PushOutcome::Lagged);
        let lagged = queue.wait_blocking(Duration::ZERO, 10).unwrap();
        assert_eq!(lagged, vec![LAGGED]);
        assert!(queue.wait_blocking(Duration::ZERO, 10).unwrap().is_empty());
        assert_eq!(queue.push(4), PushOutcome::Queued);
        assert_eq!(queue.wait_blocking(Duration::ZERO, 10).unwrap(), vec![4]);
    }

    #[test]
    fn batches_are_bounded_and_ordered() {
        let queue = queue_of(10);
        for value in 0..5 {
            queue.push(value);
        }
        assert_eq!(
            queue.wait_blocking(Duration::ZERO, 3).unwrap(),
            vec![0, 1, 2]
        );
        assert_eq!(queue.wait_blocking(Duration::ZERO, 3).unwrap(), vec![3, 4]);
    }

    #[test]
    fn closing_wakes_blocking_waiters_with_not_found() {
        let queue = Arc::new(queue_of(4));
        let waiter = {
            let queue = Arc::clone(&queue);
            std::thread::spawn(move || queue.wait_blocking(Duration::from_secs(5), 1))
        };
        std::thread::sleep(Duration::from_millis(20));
        queue.close();
        assert_eq!(
            waiter.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(queue.push(1), PushOutcome::Closed);
    }

    #[test]
    fn thousands_of_async_waiters_share_two_threads_and_all_wake() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let queues: Vec<_> = (0..2_000).map(|_| Arc::new(queue_of(4))).collect();
            let waiters: Vec<_> = queues
                .iter()
                .map(|queue| {
                    let queue = Arc::clone(queue);
                    tokio::spawn(async move { queue.wait(Duration::from_secs(5), 4).await })
                })
                .collect();
            tokio::time::sleep(Duration::from_millis(50)).await;
            let started = Instant::now();
            for (index, queue) in queues.iter().enumerate() {
                queue.push(index as i64);
            }
            for (index, waiter) in waiters.into_iter().enumerate() {
                assert_eq!(waiter.await.unwrap().unwrap(), vec![index as i64]);
            }
            assert!(started.elapsed() < Duration::from_secs(1));
        });
    }

    #[test]
    fn async_wait_times_out_empty() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let queue = queue_of(4);
        let events = runtime
            .block_on(queue.wait(Duration::from_millis(10), 4))
            .unwrap();
        assert!(events.is_empty());
    }
}
