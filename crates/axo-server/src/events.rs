//! Events (RFD0041): one `broadcast` channel every change is published on, and the subscriptions
//! clients and the relay read it through.
//!
//! A subscription is a receiver with its scope and Session filter, and the snapshots of the
//! Sessions open when it began, which it reads first. One that falls more than the channel's
//! capacity behind reads `subscription.lagged` and relists, as a client does after any lag.
//! Terminal output is published only while a subscription that streams it exists.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axo_protocol::{Event, EventScope, SessionId, SessionRecord};
use serde::Serialize;
use tokio::sync::broadcast;

/// Events held for the slowest subscriber before it lags.
const CAPACITY: usize = 4096;
const MAX_SUBSCRIPTIONS: usize = 64;
/// A subscription nobody waits on and nobody read for this long is reclaimed; one being waited on
/// never is, however long the wait.
pub(crate) const SUBSCRIPTION_IDLE_EXPIRY: Duration = Duration::from_secs(60);

pub(crate) struct Events {
    sender: broadcast::Sender<Arc<Event>>,
    subscriptions: Mutex<HashMap<String, Arc<Subscription>>>,
    /// Subscriptions that stream terminal output.
    streaming: AtomicUsize,
    next_id: AtomicU64,
}

struct Subscription {
    receiver: tokio::sync::Mutex<broadcast::Receiver<Arc<Event>>>,
    /// Read before the channel: the snapshots of the Sessions open when it began.
    initial: Mutex<VecDeque<Arc<Event>>>,
    session_id: Option<SessionId>,
    scope: EventScope,
    last_read: Mutex<Instant>,
    waiters: AtomicUsize,
}

impl Subscription {
    fn wants(&self, event: &Event) -> bool {
        self.session_id
            .is_none_or(|expected| event.session_id() == Some(expected))
            && self.scope.accepts(event.scope())
    }

    fn abandoned(&self, now: Instant) -> bool {
        self.waiters.load(Ordering::Acquire) == 0
            && now.duration_since(*lock(&self.last_read)) >= SUBSCRIPTION_IDLE_EXPIRY
    }
}

/// Counts a wait for as long as it lasts, however it ends.
struct Waiting<'a>(&'a Subscription);

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        *lock(&self.0.last_read) = Instant::now();
        self.0.waiters.fetch_sub(1, Ordering::AcqRel);
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn not_open() -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, "subscription is not open")
}

impl Default for Events {
    fn default() -> Self {
        Self {
            sender: broadcast::channel(CAPACITY).0,
            subscriptions: Mutex::default(),
            streaming: AtomicUsize::new(0),
            next_id: AtomicU64::new(1),
        }
    }
}

impl Events {
    pub(crate) fn publish(&self, event: Event) {
        let _ = self.sender.send(Arc::new(event));
    }

    /// Whether anyone streams terminal output; without anyone, it is not encoded at all.
    pub(crate) fn wants_terminal_output(&self) -> bool {
        self.streaming.load(Ordering::Relaxed) > 0
    }

    /// Begins a subscription. `open` gives the Sessions open now; it is read after the
    /// subscription listens, so nothing that changes in between is missed.
    pub(crate) fn subscribe(
        &self,
        session_id: Option<SessionId>,
        include_streams: bool,
        open: impl FnOnce() -> Vec<SessionRecord>,
    ) -> io::Result<String> {
        let mut subscriptions = lock(&self.subscriptions);
        let now = Instant::now();
        let expired: Vec<String> = subscriptions
            .iter()
            .filter(|(_, subscription)| subscription.abandoned(now))
            .map(|(id, _)| id.clone())
            .collect();
        for id in &expired {
            if let Some(subscription) = subscriptions.remove(id) {
                self.forget(&subscription);
            }
        }
        if !expired.is_empty() {
            log::info!(
                "event=session.subscriptions_expired count={}",
                expired.len()
            );
        }
        if subscriptions.len() >= MAX_SUBSCRIPTIONS {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "session subscription capacity reached",
            ));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let subscription_id = format!(
            "00000000-0000-4000-8000-{:012x}",
            ((std::process::id() as u64) << 32 | id) & 0x0000_ffff_ffff_ffff
        );
        let receiver = self.sender.subscribe();
        let initial = open()
            .into_iter()
            .filter(|session| session_id.is_none_or(|expected| expected == session.id))
            .map(|session| Arc::new(Event::snapshot(session)))
            .collect();
        let scope = if include_streams {
            self.streaming.fetch_add(1, Ordering::Relaxed);
            EventScope::Streams
        } else {
            EventScope::Catalog
        };
        subscriptions.insert(
            subscription_id.clone(),
            Arc::new(Subscription {
                receiver: tokio::sync::Mutex::new(receiver),
                initial: Mutex::new(initial),
                session_id,
                scope,
                last_read: Mutex::new(now),
                waiters: AtomicUsize::new(0),
            }),
        );
        Ok(subscription_id)
    }

    fn forget(&self, subscription: &Subscription) {
        if subscription.scope == EventScope::Streams {
            self.streaming.fetch_sub(1, Ordering::Relaxed);
        }
    }

    pub(crate) fn unsubscribe(&self, id: &str) -> io::Result<()> {
        let subscription = lock(&self.subscriptions).remove(id).ok_or_else(not_open)?;
        self.forget(&subscription);
        Ok(())
    }

    /// Waits up to `timeout` for the first event the subscription wants, then takes up to
    /// `max_events` already there. Empty at the timeout.
    pub(crate) async fn next(
        &self,
        id: &str,
        timeout: Duration,
        max_events: usize,
    ) -> io::Result<Vec<Arc<Event>>> {
        let subscription = lock(&self.subscriptions)
            .get(id)
            .cloned()
            .ok_or_else(not_open)?;
        subscription.waiters.fetch_add(1, Ordering::AcqRel);
        let _waiting = Waiting(&subscription);
        let mut events: Vec<Arc<Event>> = {
            let mut initial = lock(&subscription.initial);
            let count = initial.len().min(max_events);
            initial.drain(..count).collect()
        };
        let mut receiver = subscription.receiver.lock().await;
        if events.is_empty() {
            let deadline = tokio::time::Instant::now() + timeout;
            loop {
                match tokio::time::timeout_at(deadline, receiver.recv()).await {
                    Err(_) => return Ok(events),
                    Ok(Ok(event)) if subscription.wants(&event) => {
                        events.push(event);
                        break;
                    }
                    Ok(Ok(_)) => {}
                    Ok(Err(broadcast::error::RecvError::Lagged(_))) => {
                        return Ok(vec![Arc::new(Event::SubscriptionLagged)]);
                    }
                    Ok(Err(broadcast::error::RecvError::Closed)) => return Ok(events),
                }
            }
        }
        while events.len() < max_events {
            match receiver.try_recv() {
                Ok(event) if subscription.wants(&event) => events.push(event),
                Ok(_) => {}
                Err(broadcast::error::TryRecvError::Lagged(_)) => {
                    events.push(Arc::new(Event::SubscriptionLagged));
                    break;
                }
                Err(_) => break,
            }
        }
        Ok(events)
    }
}

/// An event shared by every subscriber that received it; serializes as the event.
pub(crate) struct SharedEvent(pub(crate) Arc<Event>);

impl Serialize for SharedEvent {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(serializer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn removed(n: u128) -> Event {
        Event::SessionRemoved {
            session_id: SessionId::from_u128(n),
        }
    }

    #[tokio::test]
    async fn a_subscription_reads_what_was_published_after_it_began_in_order() {
        let events = Events::default();
        events.publish(removed(1));
        let id = events.subscribe(None, false, Vec::new).unwrap();
        events.publish(removed(2));
        events.publish(removed(3));
        let read = events.next(&id, Duration::from_secs(1), 10).await.unwrap();
        assert_eq!(read.len(), 2);
        assert_eq!(read[0].session_id(), Some(SessionId::from_u128(2)));
        assert!(
            events
                .next(&id, Duration::from_millis(10), 10)
                .await
                .unwrap()
                .is_empty(),
            "nothing more until something happens"
        );
    }

    #[tokio::test]
    async fn a_subscription_to_one_session_sees_only_it_and_streams_only_if_asked() {
        let events = Events::default();
        let one = events
            .subscribe(Some(SessionId::from_u128(2)), false, Vec::new)
            .unwrap();
        assert!(!events.wants_terminal_output());
        let streaming = events.subscribe(None, true, Vec::new).unwrap();
        assert!(events.wants_terminal_output());
        events.publish(removed(1));
        events.publish(removed(2));
        let read = events.next(&one, Duration::from_secs(1), 10).await.unwrap();
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].session_id(), Some(SessionId::from_u128(2)));
        events.unsubscribe(&streaming).unwrap();
        assert!(!events.wants_terminal_output());
        assert!(events.unsubscribe(&streaming).is_err());
    }

    #[tokio::test]
    async fn a_subscription_that_falls_behind_is_told_so() {
        let events = Events::default();
        let id = events.subscribe(None, false, Vec::new).unwrap();
        for n in 0..(CAPACITY as u128 + 10) {
            events.publish(removed(n));
        }
        let read = events.next(&id, Duration::from_secs(1), 10).await.unwrap();
        assert!(matches!(*read[0], Event::SubscriptionLagged));
    }
}
