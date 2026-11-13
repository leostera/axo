//! Idle Pis go to sleep (RFD0045). Once a minute, every open Session says how long its Pi has
//! been idle; those idle past the timeout sleep, then the longest idle sleep until no more than
//! the limit are awake. Working Pis, and Pis asking the person something, are not idle: they are
//! never stopped, and not counted.

use std::sync::{Arc, Weak};
use std::time::Duration;

use axo_protocol::SessionId;

use crate::core::Core;
use crate::settings::IdleLimits;

/// How often axod looks at the idle Pis.
const TICK: Duration = Duration::from_secs(60);
/// How long a Pi must be idle before the limit counts it: a Pi between two prompts of a burst
/// is not idle.
const LIMIT_GRACE: Duration = Duration::from_secs(60);
/// How long a Session gets to say how idle its Pi is; one that is busy is skipped this time.
const ANSWER_WAIT: Duration = Duration::from_secs(2);

/// What decides which idle Pis sleep.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Policy {
    pub(crate) limits: IdleLimits,
    /// How long a Pi must be idle before the limit counts it.
    pub(crate) grace: Duration,
}

impl Policy {
    pub(crate) fn of(limits: IdleLimits) -> Self {
        Self {
            limits,
            grace: LIMIT_GRACE,
        }
    }
}

/// Looks at the idle Pis every minute until axod stops or goes.
pub(crate) async fn run(core: Weak<Core>) {
    loop {
        tokio::time::sleep(TICK).await;
        let Some(core) = core.upgrade().filter(|core| !core.is_stopping()) else {
            return;
        };
        let policy = Policy::of(core.settings().idle_limits());
        look(&core, policy).await;
    }
}

/// Puts to sleep the idle Pis `policy` chooses; the Sessions it asked.
pub(crate) async fn look(core: &Arc<Core>, policy: Policy) -> Vec<SessionId> {
    let mut asking = tokio::task::JoinSet::new();
    for handle in core.registry.all() {
        asking.spawn(async move {
            let idle = tokio::time::timeout(ANSWER_WAIT, handle.with(|session| session.pi_idle()))
                .await
                .ok()
                .and_then(Result::ok)
                .flatten();
            idle.map(|idle| (handle.id, idle))
        });
    }
    let mut idle: Vec<(SessionId, Duration)> = Vec::new();
    while let Some(answer) = asking.join_next().await {
        idle.extend(answer.ok().flatten());
    }
    let chosen = choose(&idle, policy);
    let mut slept = Vec::new();
    for id in chosen {
        let Some(handle) = core.registry.get(id) else {
            continue;
        };
        // A Pi that did something since it answered stays awake.
        if handle
            .with(|session| session.sleep_pi())
            .await
            .unwrap_or(false)
        {
            slept.push(id);
        }
    }
    if !slept.is_empty() {
        log::info!(
            "event=idle_pis.slept count={} idle={}",
            slept.len(),
            idle.len()
        );
    }
    slept
}

/// Which of the idle Pis sleep, longest idle first: those idle past the timeout, then, while
/// more than the limit are left awake, the longest idle of those past the grace.
pub(crate) fn choose<K: Copy>(idle: &[(K, Duration)], policy: Policy) -> Vec<K> {
    let mut by_idle: Vec<(K, Duration)> = idle.to_vec();
    by_idle.sort_by_key(|(_, idle)| std::cmp::Reverse(*idle));
    let timed_out = |idle: Duration| policy.limits.timeout.is_some_and(|timeout| idle >= timeout);
    let mut awake = by_idle.iter().filter(|(_, idle)| !timed_out(*idle)).count();
    let mut chosen = Vec::new();
    for (key, idle) in by_idle {
        if timed_out(idle) {
            chosen.push(key);
        } else if awake > policy.limits.awake && idle >= policy.grace {
            chosen.push(key);
            awake -= 1;
        }
    }
    chosen
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINUTE: Duration = Duration::from_secs(60);

    fn policy(timeout_minutes: Option<u32>, awake: usize) -> Policy {
        Policy {
            limits: IdleLimits {
                timeout: timeout_minutes.map(|minutes| MINUTE * minutes),
                awake,
            },
            grace: MINUTE,
        }
    }

    #[test]
    fn pis_idle_past_the_timeout_sleep_and_the_rest_stay_awake_under_the_limit() {
        let idle = [("a", MINUTE * 31), ("b", MINUTE * 5), ("c", MINUTE * 30)];
        assert_eq!(choose(&idle, policy(Some(30), 20)), vec!["a", "c"]);
        assert!(choose(&idle, policy(None, 20)).is_empty(), "no timeout");
    }

    #[test]
    fn past_the_limit_the_longest_idle_sleep_first() {
        let idle = [
            ("a", MINUTE * 2),
            ("b", MINUTE * 9),
            ("c", MINUTE * 4),
            ("d", MINUTE * 3),
        ];
        assert_eq!(choose(&idle, policy(Some(30), 2)), vec!["b", "c"]);
        assert_eq!(choose(&idle, policy(None, 0)), vec!["b", "c", "d", "a"]);
    }

    #[test]
    fn timed_out_pis_count_against_nothing_and_fresh_ones_are_spared() {
        // `a` sleeps for the timeout, leaving two awake under a limit of one; `c` is still in
        // its grace, so only `b` goes.
        let idle = [
            ("a", MINUTE * 40),
            ("b", MINUTE * 2),
            ("c", Duration::from_secs(10)),
        ];
        assert_eq!(choose(&idle, policy(Some(30), 1)), vec!["a", "b"]);
        let fresh = [("x", Duration::from_secs(5)), ("y", Duration::from_secs(1))];
        assert!(choose(&fresh, policy(None, 0)).is_empty());
    }
}
