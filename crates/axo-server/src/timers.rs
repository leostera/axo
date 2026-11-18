//! Daemon-owned, volatile message timers. Waiting tasks never keep Core alive.
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use axo_ipc::TypedMethods;
use axo_protocol::rpc::{self, method};
use axo_protocol::timers::*;
use axo_protocol::{SessionId, new_uuid_v4};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::core::{Core, lock};
use crate::session::prompts::{self, PromptError};

const MAX_TIMERS: usize = 128;
const MAX_OWNER_TIMERS: usize = 32;
const SEND_WAIT: Duration = Duration::from_secs(10);

#[derive(Default)]
pub(crate) struct Timers(Mutex<HashMap<TimerId, Entry>>);
struct Entry {
    request: CreateTimer,
    info: TimerInfo,
    cancel: watch::Sender<bool>,
    _task: Option<JoinHandle<()>>,
    first_deadline: Instant,
    in_flight: bool,
}
fn invalid(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        data: None,
    }
}

impl Timers {
    fn create(core: &Arc<Core>, request: CreateTimer) -> Result<TimerInfo, RpcError> {
        if core.is_stopping() {
            return Err(invalid("axod is stopping"));
        }
        prompts::check_prompt(&request.text, &[])
            .map_err(|_| invalid("a timer prompt must not be blank"))?;
        for id in [request.from_session_id, request.session_id] {
            if !core.registry.contains(id) {
                return Err(invalid(
                    "timer sender and target must be open local Sessions",
                ));
            }
        }
        let id =
            TimerId::try_from(new_uuid_v4().map_err(|_| invalid("could not allocate timer ID"))?)
                .map_err(|_| invalid("could not allocate timer ID"))?;
        let mut entries = lock(&core.timers.0);
        // Recheck under the same lock used by close_session/stop: a closing Session cannot
        // admit an old timer that later resurrects when that UUID is reopened.
        if core.is_stopping()
            || [request.from_session_id, request.session_id]
                .iter()
                .any(|id| !core.registry.contains(*id))
        {
            return Err(invalid("timer sender or target is closing"));
        }
        if entries.len() >= MAX_TIMERS
            || entries
                .values()
                .filter(|e| e.info.from_session_id == request.from_session_id)
                .count()
                >= MAX_OWNER_TIMERS
        {
            return Err(invalid(
                "timer capacity reached (32 per sender, 128 per daemon); cancel an existing timer",
            ));
        }
        let info = TimerInfo {
            timer_id: id.clone(),
            session_id: request.session_id,
            from_session_id: request.from_session_id,
            timing: request.timing,
            state: TimerState::Waiting,
            fired: 0,
            last_outcome: None,
        };
        let (cancel, receiver) = watch::channel(false);
        entries.insert(
            id.clone(),
            Entry {
                request,
                info: info.clone(),
                cancel,
                _task: None,
                first_deadline: Instant::now() + Duration::from_millis(info.timing.milliseconds()),
                in_flight: false,
            },
        );
        let weak = Arc::downgrade(core);
        let task_id = id.clone();
        let task = tokio::spawn(async move { run(weak, task_id, receiver).await });
        entries.get_mut(&id).expect("entry is locked")._task = Some(task);
        log::info!("event=session.timer_created timer_id={id}");
        Ok(info)
    }

    fn list(&self, owner: SessionId) -> Vec<TimerInfo> {
        let mut result: Vec<_> = lock(&self.0)
            .values()
            .filter(|e| e.info.from_session_id == owner)
            .map(|e| e.info.clone())
            .collect();
        result.sort_by_key(|e| e.timer_id.to_string());
        result
    }

    fn cancel(&self, owner: SessionId, id: &TimerId) -> TimerCancelled {
        let mut entries = lock(&self.0);
        let Some(entry) = entries
            .get_mut(id)
            .filter(|e| e.info.from_session_id == owner)
        else {
            return TimerCancelled {
                cancelled: false,
                in_flight: false,
            };
        };
        let in_flight = entry.in_flight;
        entry.info.state = TimerState::Cancelling;
        let _ = entry.cancel.send(true);
        TimerCancelled {
            cancelled: true,
            in_flight,
        }
    }

    pub(crate) fn close_session(&self, id: SessionId) {
        let mut entries = lock(&self.0);
        for entry in entries
            .values_mut()
            .filter(|e| e.info.from_session_id == id || e.info.session_id == id)
        {
            entry.info.state = TimerState::Cancelling;
            let _ = entry.cancel.send(true);
        }
    }
    pub(crate) fn stop(&self) {
        for entry in lock(&self.0).values_mut() {
            entry.info.state = TimerState::Cancelling;
            let _ = entry.cancel.send(true);
        }
    }

    fn claim(&self, id: &TimerId) -> Option<CreateTimer> {
        let mut entries = lock(&self.0);
        let entry = entries.get_mut(id)?;
        if !matches!(entry.info.state, TimerState::Waiting) {
            return None;
        }
        entry.info.state = TimerState::Sending;
        entry.in_flight = true;
        entry.info.fired = entry.info.fired.saturating_add(1);
        Some(entry.request.clone())
    }
    fn uncertain(&self, id: &TimerId) {
        if let Some(entry) = lock(&self.0).get_mut(id) {
            entry.info.last_outcome = Some(TimerOutcome::Uncertain);
            entry.info.state = TimerState::Cancelling;
        }
    }

    fn completed(&self, id: &TimerId, outcome: TimerOutcome) -> bool {
        let mut entries = lock(&self.0);
        let Some(entry) = entries.get_mut(id) else {
            return false;
        };
        entry.info.last_outcome = Some(outcome);
        entry.in_flight = false;
        if matches!(entry.info.state, TimerState::Cancelling) {
            return false;
        }
        entry.info.state = TimerState::Waiting;
        true
    }
}

/// Skip elapsed ticks, including ticks missed while a send was pending. Never catch up in a burst.
fn next_deadline(previous: Instant, period: Duration, now: Instant) -> Instant {
    let next = previous + period;
    if next <= now { now + period } else { next }
}

#[derive(Debug, PartialEq)]
enum NextTick {
    Cadence,
    AfterRateWindow,
    Stop,
}

/// Only definite nonadmission can continue. A limiter refusal waits its whole window instead
/// of creating one rejected prompt/log per second for every short-period timer.
fn tick_result(result: Result<rpc::PromptAccepted, PromptError>) -> (TimerOutcome, NextTick) {
    match result {
        Ok(rpc::PromptAccepted { queued: false, .. }) => {
            (TimerOutcome::Accepted, NextTick::Cadence)
        }
        // Still waiting for its Pi to start: delivered when it does, or dropped if it never does.
        Ok(rpc::PromptAccepted { queued: true, .. }) => (TimerOutcome::Queued, NextTick::Cadence),
        Err(PromptError::RateLimited) => (TimerOutcome::Refused, NextTick::AfterRateWindow),
        Err(PromptError::Busy | PromptError::QueueFull | PromptError::Dropped) => {
            (TimerOutcome::Refused, NextTick::Cadence)
        }
        Err(PromptError::Unavailable(_)) => (TimerOutcome::Uncertain, NextTick::Stop),
        Err(_) => (TimerOutcome::Refused, NextTick::Stop),
    }
}

/// A deadline closes recurrence but does not abandon an admitted Session operation. Retain
/// its future and slot until it returns; cancellation cannot retract that send.
async fn owned_send(
    send: impl std::future::Future<Output = Result<rpc::PromptAccepted, PromptError>>,
    deadline: Duration,
    on_uncertain: impl FnOnce(),
) -> (TimerOutcome, NextTick) {
    tokio::pin!(send);
    match tokio::time::timeout(deadline, &mut send).await {
        Ok(result) => tick_result(result),
        Err(_) => {
            on_uncertain();
            let (outcome, _) = tick_result(send.await);
            (outcome, NextTick::Stop)
        }
    }
}

async fn run(core: Weak<Core>, id: TimerId, mut cancel: watch::Receiver<bool>) {
    let Some((timing, owner, target, mut next)) = core.upgrade().and_then(|core| {
        lock(&core.timers.0).get(&id).map(|e| {
            (
                e.request.timing,
                e.info.from_session_id,
                e.info.session_id,
                e.first_deadline,
            )
        })
    }) else {
        return;
    };
    let period = Duration::from_millis(timing.milliseconds());
    loop {
        tokio::select! { biased;
            _ = cancel.changed() => break,
            _ = tokio::time::sleep_until(next) => {}
        }
        if *cancel.borrow() {
            break;
        }
        let Some(core) = core.upgrade() else { break };
        if core.is_stopping() || !core.registry.contains(owner) || !core.registry.contains(target) {
            break;
        }
        let Some(request) = core.timers.claim(&id) else {
            break;
        };
        let (outcome, next_tick) = owned_send(
            crate::sessions::prompt(
                &core,
                rpc::PromptSession {
                    session_id: request.session_id,
                    from_session_id: Some(request.from_session_id),
                    text: request.text,
                    delivery: request.delivery.into(),
                },
                None,
                Vec::new(),
                prompts::QUEUED_PROMPT_WAIT,
            ),
            SEND_WAIT,
            || {
                core.timers.uncertain(&id);
                log::warn!("event=session.timer_send_uncertain timer_id={id} slot_retained=true");
            },
        )
        .await;
        log::debug!("event=session.timer_fired timer_id={id} outcome={outcome:?}");
        let active = core.timers.completed(&id, outcome);
        drop(core);
        if !active || !timing.recurring() || *cancel.borrow() {
            break;
        }
        next = match next_tick {
            NextTick::Stop => break,
            NextTick::Cadence => next_deadline(next, period, Instant::now()),
            NextTick::AfterRateWindow => Instant::now() + period.max(prompts::RATE_WINDOW),
        };
    }
    if let Some(core) = core.upgrade() {
        lock(&core.timers.0).remove(&id);
        log::info!("event=session.timer_retired timer_id={id}");
    }
}

pub(crate) fn register(handler: &mut IoHandler, core: Arc<Core>) {
    let create = Arc::clone(&core);
    handler.add_typed(
        method::SESSION_TIMER_CREATE,
        "expected a bounded runtime timer",
        move |request: CreateTimer| {
            let core = Arc::clone(&create);
            async move { Timers::create(&core, request) }
        },
    );
    let list = Arc::clone(&core);
    handler.add_typed(method::SESSION_TIMER_LIST, "expected {fromSessionId}", move |request: TimerOwner| {
        let core = Arc::clone(&list);
        async move { Ok(serde_json::json!({"timers":core.timers.list(request.from_session_id)})) }
    });
    handler.add_typed(
        method::SESSION_TIMER_CANCEL,
        "expected {fromSessionId,timerId}",
        move |request: CancelTimer| {
            let core = Arc::clone(&core);
            async move {
                Ok(core
                    .timers
                    .cancel(request.from_session_id, &request.timer_id))
            }
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{Fixture, Pi};

    fn isolated_entry(owner: SessionId) -> (Timers, TimerId, watch::Receiver<bool>) {
        let request = request(owner, 1000);
        let id = TimerId::try_from(new_uuid_v4().unwrap()).unwrap();
        let (cancel, receiver) = watch::channel(false);
        let entry = Entry {
            request: request.clone(),
            info: TimerInfo {
                timer_id: id.clone(),
                session_id: owner,
                from_session_id: owner,
                timing: request.timing,
                state: TimerState::Waiting,
                fired: 0,
                last_outcome: None,
            },
            cancel,
            _task: None,
            first_deadline: Instant::now(),
            in_flight: false,
        };
        let timers = Timers::default();
        lock(&timers.0).insert(id.clone(), entry);
        (timers, id, receiver)
    }

    #[test]
    fn cancellation_closes_admission_without_releasing_a_claimed_send() {
        let owner = SessionId::from_u128(1);
        let (timers, id, receiver) = isolated_entry(owner);
        assert!(timers.claim(&id).is_some());
        assert!(timers.claim(&id).is_none(), "Occurrences never overlap");
        assert_eq!(timers.list(owner)[0].fired, 1);
        assert!(timers.cancel(owner, &id).in_flight);
        assert!(*receiver.borrow());
        assert!(timers.claim(&id).is_none());
        assert!(timers.cancel(owner, &id).in_flight);
        assert_eq!(
            timers.list(owner).len(),
            1,
            "Claimed send still owns its slot"
        );
        assert!(!timers.completed(&id, TimerOutcome::Accepted));
        assert!(!timers.cancel(owner, &id).in_flight);
    }

    #[test]
    fn cancellation_before_claim_is_idempotent_and_never_claims() {
        let owner = SessionId::from_u128(1);
        let (timers, id, receiver) = isolated_entry(owner);
        assert!(!timers.cancel(owner, &id).in_flight);
        assert!(!timers.cancel(owner, &id).in_flight);
        assert!(timers.claim(&id).is_none());
        assert!(*receiver.borrow());
        assert_eq!(timers.list(owner)[0].fired, 0);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn recurring_timer_fires_then_cancel_prevents_future_ticks() {
        let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
        let record = fixture.new_session().await;
        fixture.wait_for_pi(record.id).await;
        let mut scheduled = request(record.id, 1);
        scheduled.timing = Timing::Interval(IntervalMillis::try_from(1000).unwrap());
        let info = Timers::create(&fixture.core, scheduled).unwrap();
        fixture
            .until("first interval send", || {
                fixture.pi_log().contains("timer fixture")
            })
            .await;
        assert!(
            fixture
                .core
                .timers
                .cancel(record.id, &info.timer_id)
                .cancelled
        );
        fixture
            .until("interval retirement", || {
                fixture.core.timers.list(record.id).is_empty()
            })
            .await;
        let sent = fixture.pi_log().matches("SENT:[From Axo Session").count();
        tokio::time::sleep(Duration::from_millis(1100)).await;
        assert_eq!(
            fixture.pi_log().matches("SENT:[From Axo Session").count(),
            sent
        );
        crate::sessions::stop(&fixture.core).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn global_capacity_is_shared_across_senders_and_stop_retires_every_timer() {
        let fixture = Fixture::new().await;
        let mut owners = Vec::new();
        for _ in 0..4 {
            let record = fixture.new_session().await;
            owners.push(record.id);
            for _ in 0..MAX_OWNER_TIMERS {
                Timers::create(&fixture.core, request(record.id, 3600000)).unwrap();
            }
        }
        let extra = fixture.new_session().await;
        assert!(Timers::create(&fixture.core, request(extra.id, 3600000)).is_err());
        assert_eq!(lock(&fixture.core.timers.0).len(), MAX_TIMERS);
        fixture.core.timers.stop();
        fixture
            .until("all timer tasks retire", || {
                lock(&fixture.core.timers.0).is_empty()
            })
            .await;
        for owner in owners {
            assert!(fixture.core.timers.list(owner).is_empty());
        }
        crate::sessions::stop(&fixture.core).await;
    }

    fn request(owner: SessionId, delay: u64) -> CreateTimer {
        CreateTimer {
            session_id: owner,
            from_session_id: owner,
            text: rpc::PromptText::parse("timer fixture".into()).unwrap(),
            delivery: Delivery::FollowUp,
            timing: Timing::After(AfterMillis::try_from(delay).unwrap()),
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn one_shot_reaches_private_pi_once_with_agent_provenance() {
        let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
        let record = fixture.new_session().await;
        fixture.wait_for_pi(record.id).await;
        Timers::create(&fixture.core, request(record.id, 10)).unwrap();
        fixture
            .until("one timer send", || {
                fixture.pi_log().contains("timer fixture")
            })
            .await;
        fixture
            .until("timer retirement", || {
                fixture.core.timers.list(record.id).is_empty()
            })
            .await;
        let log = fixture.pi_log();
        assert_eq!(log.matches("SENT:[From Axo Session").count(), 1, "{log}");
        assert!(log.contains(&record.id.to_string()));
        crate::sessions::stop(&fixture.core).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn capacity_cancel_ownership_and_restart_are_runtime_only() {
        let mut fixture = Fixture::new().await;
        let record = fixture.new_session().await;
        for _ in 0..MAX_OWNER_TIMERS {
            Timers::create(&fixture.core, request(record.id, 3600000)).unwrap();
        }
        assert!(Timers::create(&fixture.core, request(record.id, 3600000)).is_err());
        let first = fixture.core.timers.list(record.id)[0].timer_id.clone();
        assert!(
            !fixture
                .core
                .timers
                .cancel(SessionId::from_u128(999), &first)
                .cancelled
        );
        assert_eq!(fixture.core.timers.list(record.id).len(), MAX_OWNER_TIMERS);
        assert!(!fixture.core.timers.cancel(record.id, &first).in_flight);
        fixture
            .until("cancelled timer retirement", || {
                fixture.core.timers.list(record.id).len() < MAX_OWNER_TIMERS
            })
            .await;
        fixture.restart().await;
        assert!(fixture.core.timers.list(record.id).is_empty());
        crate::sessions::stop(&fixture.core).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn closing_target_stops_another_sessions_timers() {
        let fixture = Fixture::new().await;
        let sender = fixture.new_session().await;
        let target = fixture.new_session().await;
        let mut scheduled = request(sender.id, 3600000);
        scheduled.session_id = target.id;
        Timers::create(&fixture.core, scheduled).unwrap();
        crate::sessions::close(&fixture.core, target.id)
            .await
            .unwrap();
        fixture
            .until("closed target timer retirement", || {
                fixture.core.timers.list(sender.id).is_empty()
            })
            .await;
        crate::sessions::stop(&fixture.core).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn timer_messages_share_immediate_self_prompt_rate_limits() {
        let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
        let record = fixture.new_session().await;
        fixture.wait_for_pi(record.id).await;
        for _ in 0..10 {
            crate::sessions::prompt(
                &fixture.core,
                rpc::PromptSession {
                    session_id: record.id,
                    from_session_id: Some(record.id),
                    text: rpc::PromptText::parse("immediate".into()).unwrap(),
                    delivery: rpc::PromptDelivery::FollowUp,
                },
                None,
                vec![],
                Duration::ZERO,
            )
            .await
            .unwrap();
        }
        Timers::create(&fixture.core, request(record.id, 1)).unwrap();
        fixture
            .until("rate-limited timer retirement", || {
                fixture.core.timers.list(record.id).is_empty()
            })
            .await;
        assert!(!fixture.pi_log().contains("timer fixture"));
        crate::sessions::stop(&fixture.core).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn uncertain_send_keeps_its_slot_and_future_until_actual_retirement() {
        let owner = SessionId::from_u128(1);
        let (timers, id, _receiver) = isolated_entry(owner);
        let timers = Arc::new(timers);
        assert!(timers.claim(&id).is_some());
        let (finish, result) = tokio::sync::oneshot::channel();
        let (expired, expiry) = tokio::sync::oneshot::channel();
        let running = Arc::clone(&timers);
        let task_id = id.clone();
        let task = tokio::spawn(async move {
            owned_send(
                async { result.await.unwrap() },
                Duration::from_millis(10),
                || {
                    running.uncertain(&task_id);
                    expired.send(()).unwrap();
                },
            )
            .await
        });
        expiry.await.unwrap();
        assert!(!task.is_finished());
        assert_eq!(timers.list(owner).len(), 1);
        assert!(timers.cancel(owner, &id).in_flight);
        assert!(timers.claim(&id).is_none());
        finish
            .send(Ok(rpc::PromptAccepted {
                accepted: true,
                queued: false,
            }))
            .unwrap();
        let (outcome, repeat) = task.await.unwrap();
        assert!(matches!(outcome, TimerOutcome::Accepted));
        assert_eq!(
            repeat,
            NextTick::Stop,
            "A deadline-uncertain interval never resumes automatically"
        );
        assert!(!timers.completed(&id, outcome));
    }

    #[test]
    fn a_send_still_queued_is_reported_queued_not_accepted() {
        let queued = tick_result(Ok(rpc::PromptAccepted {
            accepted: true,
            queued: true,
        }));
        assert!(matches!(queued.0, TimerOutcome::Queued));
        assert_eq!(queued.1, NextTick::Cadence);
        let dropped = tick_result(Err(PromptError::Dropped));
        assert!(matches!(dropped.0, TimerOutcome::Refused));
        assert_eq!(dropped.1, NextTick::Cadence);
    }

    #[test]
    fn only_definite_nonadmission_may_continue_an_interval() {
        for error in [PromptError::Busy, PromptError::QueueFull] {
            let (outcome, repeat) = tick_result(Err(error));
            assert!(matches!(outcome, TimerOutcome::Refused));
            assert_eq!(repeat, NextTick::Cadence);
        }
        let (outcome, repeat) = tick_result(Err(PromptError::Unavailable("receipt lost".into())));
        assert!(matches!(outcome, TimerOutcome::Uncertain));
        assert_eq!(repeat, NextTick::Stop);
        assert_eq!(tick_result(Err(PromptError::NoPi)).1, NextTick::Stop);
        assert_eq!(
            tick_result(Err(PromptError::RateLimited)).1,
            NextTick::AfterRateWindow
        );
    }

    #[test]
    fn late_and_slow_ticks_advance_to_the_future_without_catchup() {
        let start = Instant::now();
        let period = Duration::from_secs(10);
        assert_eq!(
            next_deadline(start, period, start + Duration::from_secs(2)),
            start + period
        );
        assert_eq!(
            next_deadline(start, period, start + Duration::from_secs(95)),
            start + Duration::from_secs(105)
        );
    }
}
