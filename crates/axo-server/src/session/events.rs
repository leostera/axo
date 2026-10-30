//! Event subscriptions and publishing: catalog and stream subscribers, their bounded queues, and
//! terminal output fan-out to them.

use std::io;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::SessionManager;
use super::catalog::session_metadata;
use axo_ipc::{EventQueue, PushOutcome};
use axo_protocol::{Event, EventScope, SessionId, ShellActivity, ShellId};
use axo_pty::TerminalOutputSink;
use axo_store::session_initial_pwd;
use serde::Serialize;

const MAX_SUBSCRIPTIONS: usize = 64;

pub(super) const MAX_QUEUED_EVENTS_PER_SUBSCRIPTION: usize = 128;

pub(super) const SUBSCRIPTION_IDLE_EXPIRY: Duration = Duration::from_secs(60);

/// Local event subscribers, shared with every shell's output pump.
#[derive(Clone, Default)]
pub(super) struct EventBus(pub(super) Arc<Mutex<Vec<LocalSubscriber>>>);

impl EventBus {
    pub(super) fn lock(
        &self,
    ) -> std::sync::LockResult<std::sync::MutexGuard<'_, Vec<LocalSubscriber>>> {
        self.0.lock()
    }

    /// Returns how many subscribers accepted the event.
    fn publish(&self, event: Event) -> usize {
        let (scope, session_id) = (event.scope(), event.session_id());
        let event = Arc::new(event);
        let Ok(mut subscribers) = self.lock() else {
            return 0;
        };
        let mut delivered = 0;
        subscribers.retain(|subscriber| {
            if !subscriber.wants(scope, session_id) {
                return true;
            }
            match subscriber.queue.push(Arc::clone(&event)) {
                PushOutcome::Queued => {
                    delivered += 1;
                    true
                }
                PushOutcome::Lagged => true,
                PushOutcome::Closed => false,
            }
        });
        delivered
    }
}

/// Publishes one shell's PTY output as `terminal.output` events.
pub(super) struct ShellOutputSink {
    pub(super) events: EventBus,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
}

impl TerminalOutputSink for ShellOutputSink {
    fn publish_terminal_output(&self, sequence: u64, output: &[u8]) {
        let (session_id, shell_id) = (self.session_id, self.shell_id);
        // Most of the time nobody streams terminal bytes; skip the base64 work then.
        let wanted = self.events.lock().is_ok_and(|subscribers| {
            subscribers
                .iter()
                .any(|subscriber| subscriber.wants(EventScope::Streams, Some(session_id)))
        });
        if !wanted {
            return;
        }
        self.events.publish(Event::TerminalOutput {
            session_id,
            shell_id,
            sequence,
            data: axo_protocol::base64::encode(output),
        });
    }
}

pub(super) struct LocalSubscriber {
    pub(super) id: String,
    session_id: Option<SessionId>,
    scope: EventScope,
    queue: Arc<EventQueue<Arc<Event>>>,
}

impl LocalSubscriber {
    fn wants(&self, scope: EventScope, session_id: Option<SessionId>) -> bool {
        self.session_id
            .is_none_or(|expected| session_id == Some(expected))
            && self.scope.accepts(scope)
    }
}

/// Consumer side of a local event subscription; see `EventQueue` for lag semantics.
/// Subscriptions nobody polls for `SUBSCRIPTION_IDLE_EXPIRY` are reclaimed so crashed clients
/// cannot exhaust capacity.
///
/// The registry mutex only guards membership. A poll clones the `Arc` out and waits on the
/// subscription's own queue, so one long-poll never blocks other subscribers, the relay,
/// `subscribe` or `unsubscribe`.
pub(super) struct LocalSubscription {
    queue: Arc<EventQueue<Arc<Event>>>,
    pub(super) last_polled: Mutex<Instant>,
}

impl LocalSubscription {
    fn last_polled(&self) -> Instant {
        self.last_polled
            .lock()
            .map(|instant| *instant)
            .unwrap_or_else(|poisoned| *poisoned.into_inner())
    }

    fn mark_polled(&self) {
        let now = Instant::now();
        match self.last_polled.lock() {
            Ok(mut instant) => *instant = now,
            Err(poisoned) => *poisoned.into_inner() = now,
        }
    }
}

/// A queued event shared by every subscriber that received it; serializes as the event.
pub(super) struct SharedEvent(pub(super) Arc<Event>);

impl Serialize for SharedEvent {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(serializer)
    }
}

impl SessionManager {
    pub(super) fn subscribe(
        &self,
        session_id: Option<SessionId>,
        include_streams: bool,
    ) -> io::Result<String> {
        if let Some(session_id) = session_id {
            let state = self.lock_state()?;
            session_initial_pwd(&state.database, session_id)?;
        }
        let id = self.next_subscription_id.fetch_add(1, Ordering::Relaxed);
        let subscription_id = format!(
            "00000000-0000-4000-8000-{:012x}",
            ((std::process::id() as u64) << 32 | id) & 0x0000_ffff_ffff_ffff
        );
        let queue = Arc::new(EventQueue::new(MAX_QUEUED_EVENTS_PER_SUBSCRIPTION, || {
            Arc::new(Event::SubscriptionLagged)
        }));
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
        let now = Instant::now();
        let expired: Vec<String> = subscriptions
            .iter()
            .filter(|(_, subscription)| {
                now.duration_since(subscription.last_polled()) >= SUBSCRIPTION_IDLE_EXPIRY
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in &expired {
            if let Some(subscription) = subscriptions.remove(id) {
                subscription.queue.close();
            }
        }
        if subscriptions.len() >= MAX_SUBSCRIPTIONS {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "session subscription capacity reached",
            ));
        }
        let mut subscribers = self
            .subscribers
            .lock()
            .map_err(|_| io::Error::other("session subscriber lock was poisoned"))?;
        if !expired.is_empty() {
            subscribers.retain(|subscriber| !expired.contains(&subscriber.id));
            log::info!(
                "event=session.subscriptions_expired count={}",
                expired.len()
            );
        }
        subscriptions.insert(
            subscription_id.clone(),
            Arc::new(LocalSubscription {
                queue: Arc::clone(&queue),
                last_polled: Mutex::new(now),
            }),
        );
        subscribers.push(LocalSubscriber {
            id: subscription_id.clone(),
            session_id,
            scope: if include_streams {
                EventScope::Streams
            } else {
                EventScope::Catalog
            },
            queue: Arc::clone(&queue),
        });
        drop(subscribers);
        drop(subscriptions);
        let sessions = match self.list_sessions() {
            Ok(sessions) => sessions,
            Err(error) => {
                let _ = self.unsubscribe(&subscription_id);
                return Err(error);
            }
        };
        // Initial snapshots go to this subscriber only; other subscribers already have them.
        for session in sessions {
            if session_id.is_none_or(|expected| expected == session.id) {
                let snapshot = Arc::new(Event::snapshot(session.clone()));
                if queue.push(snapshot) != PushOutcome::Queued {
                    break;
                }
            }
        }
        Ok(subscription_id)
    }

    pub(super) fn next_event(&self, id: &str, timeout: Duration) -> io::Result<Option<Arc<Event>>> {
        Ok(self.next_events(id, timeout, 1)?.into_iter().next())
    }

    fn subscription(&self, id: &str) -> io::Result<Arc<LocalSubscription>> {
        let subscription = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?
            .get(id)
            .cloned()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "subscription is not open"))?;
        subscription.mark_polled();
        Ok(subscription)
    }

    /// Blocks up to `timeout` for the first event, then drains up to `max_events` already queued.
    /// For the relay thread and tests; RPC uses `next_events_async`.
    pub(super) fn next_events(
        &self,
        id: &str,
        timeout: Duration,
        max_events: usize,
    ) -> io::Result<Vec<Arc<Event>>> {
        let subscription = self.subscription(id)?;
        let events = subscription.queue.wait_blocking(timeout, max_events);
        subscription.mark_polled();
        events
    }

    /// Like `next_events`, but waits without occupying a thread.
    pub(crate) async fn next_events_async(
        &self,
        id: &str,
        timeout: Duration,
        max_events: usize,
    ) -> io::Result<Vec<Arc<Event>>> {
        let subscription = self.subscription(id)?;
        let events = subscription.queue.wait(timeout, max_events).await;
        subscription.mark_polled();
        events
    }

    pub(super) fn unsubscribe(&self, id: &str) -> io::Result<()> {
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
        let Some(subscription) = subscriptions.remove(id) else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "subscription is not open",
            ));
        };
        subscription.queue.close();
        let mut subscribers = self
            .subscribers
            .lock()
            .map_err(|_| io::Error::other("session subscriber lock was poisoned"))?;
        subscribers.retain(|subscriber| subscriber.id != id);
        Ok(())
    }

    /// Returns how many subscribers accepted the event.
    pub(super) fn publish_event(&self, event: Event) -> usize {
        self.subscribers.publish(event)
    }

    /// Remote-access state changed; a catalog event so Settings never polls for it.
    pub(super) fn publish_workspace_changed(&self, workspace_id: &str) {
        self.publish_event(Event::WorkspaceChanged {
            workspace_id: workspace_id.to_owned(),
        });
    }

    pub(super) fn publish_session_snapshot(&self, session_id: SessionId) -> io::Result<()> {
        let session = {
            let state = self.lock_state()?;
            session_metadata(&state, session_id, &self.attach_socket_path)?
        };
        self.publish_event(Event::snapshot(session.clone()));
        Ok(())
    }

    pub(super) fn publish_session_removed(&self, session_id: SessionId) {
        self.publish_event(Event::SessionRemoved { session_id });
    }

    pub(super) fn publish_shell_activity(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        activity: ShellActivity,
    ) {
        self.publish_event(Event::ShellActivity {
            session_id,
            shell_id,
            activity,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::session::{pi_bridge::*, test_support::*};

    use axo_protocol::{Event, new_uuid_v4};

    use serde_json::Value;
    use std::fs;

    use std::io::{self};

    use std::path::PathBuf;

    use std::time::{Duration, Instant};

    #[test]
    fn local_subscriptions_signal_lag_filter_output_and_expire() {
        let directory = PathBuf::from("/tmp").join(format!("axos-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let manager = open_with_silent_shell(&directory);
        let drain = |id: &str| {
            while manager
                .next_event(id, Duration::from_millis(1))
                .unwrap()
                .is_some()
            {}
        };
        let catalog = manager.subscribe(None, false).unwrap();
        let output = manager.subscribe(None, true).unwrap();
        drain(&catalog);
        drain(&output);

        let terminal_output = Event::TerminalOutput {
            session_id: sid(1),
            shell_id: shid(1),
            sequence: 1,
            data: String::new(),
        };
        manager.publish_event(terminal_output.clone());
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None,
            "catalog subscriptions must not carry terminal bytes"
        );
        assert_eq!(
            manager
                .next_event(&output, Duration::from_millis(1))
                .unwrap()
                .as_deref(),
            Some(&terminal_output)
        );

        let pi_event = Event::PiEvent {
            session_id: sid(1),
            pi_session_id: "pi-session".to_owned(),
            stream_id: "stream".to_owned(),
            sequence: 1,
            name: "message_update".to_owned(),
            data: Value::Null,
        };
        manager.publish_event(pi_event.clone());
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None,
            "catalog subscriptions must not carry Pi stream events"
        );
        assert_eq!(
            manager
                .next_event(&output, Duration::from_millis(1))
                .unwrap()
                .as_deref(),
            Some(&pi_event)
        );

        // A new subscription's initial snapshots must not be rebroadcast to existing subscribers.
        let late = manager.subscribe(None, false).unwrap();
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None,
            "initial snapshots belong to the new subscriber only"
        );
        drain(&late);

        // One subscriber's long-poll must not block another's poll or publishers.
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| manager.next_event(&late, Duration::from_secs(5)));
            std::thread::sleep(Duration::from_millis(50));
            let started = Instant::now();
            assert_eq!(
                manager
                    .next_event(&catalog, Duration::from_millis(1))
                    .unwrap(),
                None
            );
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "a concurrent long-poll blocked another subscriber"
            );
            manager.publish_workspace_changed("wake");
            let woken = waiter.join().unwrap().unwrap().unwrap();
            assert!(matches!(*woken, Event::WorkspaceChanged { .. }));
        });
        drain(&catalog);
        manager.unsubscribe(&late).unwrap();

        for name in ["a", "b", "c"] {
            manager.publish_workspace_changed(name);
        }
        let batch = manager
            .next_events(&catalog, Duration::from_millis(1), 2)
            .unwrap();
        assert_eq!(batch.len(), 2, "batches are bounded by maxEvents");
        assert_eq!(wire(&*batch[0])["workspaceId"], "a");
        assert_eq!(wire(&*batch[1])["workspaceId"], "b");
        drain(&catalog);
        drain(&output);

        manager.publish_workspace_changed("workspace");
        let changed = manager
            .next_event(&catalog, Duration::from_millis(1))
            .unwrap()
            .unwrap();
        assert_eq!(wire(changed)["workspaceId"], "workspace");
        drain(&output);

        for _ in 0..=MAX_QUEUED_EVENTS_PER_SUBSCRIPTION {
            manager.publish_workspace_changed("flood");
        }
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap()
                .as_deref(),
            Some(&Event::SubscriptionLagged),
            "a full queue must be reported, never silently gapped"
        );
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None
        );
        drain(&output);

        manager.request_session_focus(sid(5)).unwrap();
        let focus = manager
            .next_event(&catalog, Duration::from_millis(1))
            .unwrap()
            .unwrap();
        let focus = wire(focus);
        assert_eq!(focus["type"], "session.focus");
        assert_eq!(focus["sessionId"], sid(5).to_string());
        assert_eq!(manager.take_pending_resume_focus().unwrap(), Some(sid(5)));
        *manager.pending_resume_focus.lock().unwrap() = Some((
            sid(6),
            Instant::now().checked_sub(PENDING_FOCUS_LIFETIME).unwrap(),
        ));
        assert_eq!(
            manager.take_pending_resume_focus().unwrap(),
            None,
            "a stale focus request must not be replayed by a later listing"
        );

        *manager
            .subscriptions
            .lock()
            .unwrap()
            .get(&catalog)
            .unwrap()
            .last_polled
            .lock()
            .unwrap() = Instant::now()
            .checked_sub(SUBSCRIPTION_IDLE_EXPIRY)
            .unwrap();
        let replacement = manager.subscribe(None, false).unwrap();
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound,
            "unpolled subscriptions are reclaimed"
        );
        assert!(
            manager
                .subscribers
                .lock()
                .unwrap()
                .iter()
                .all(|s| s.id != catalog)
        );
        manager.unsubscribe(&replacement).unwrap();
        manager.unsubscribe(&output).unwrap();
        let _ = fs::remove_dir_all(directory);
    }
}
