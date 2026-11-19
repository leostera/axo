//! Idle Pis going to sleep and waking (RFD0045).

use std::time::Duration;

use axo_protocol::rpc::{PromptDelivery, PromptText};
use axo_protocol::{Availability, PaneRole, SessionId};

use crate::session::prompts::{Origin, Outgoing};

use crate::idle_pis::{self, Policy};
use crate::sessions;
use crate::settings::IdleLimits;
use crate::test_support::{Fixture, Pi, alive, pid};

/// Every idle Pi sleeps at once.
const SLEEP_ALL: Policy = Policy {
    limits: IdleLimits {
        timeout: Some(Duration::ZERO),
        awake: 0,
    },
    grace: Duration::ZERO,
};

async fn prompt(fixture: &Fixture, id: SessionId, text: &str) -> bool {
    let accepted = sessions::prompt(
        &fixture.core,
        Outgoing {
            session_id: id,
            text: PromptText::parse(text.into()).unwrap(),
            delivery: PromptDelivery::FollowUp,
            origin: Origin::Person,
        },
        None,
        Vec::new(),
        Duration::ZERO,
    )
    .await
    .unwrap();
    accepted.queued
}

fn pi_is_dormant(fixture: &Fixture, id: SessionId) -> bool {
    fixture.listed(id).is_some_and(|record| {
        record
            .shells
            .iter()
            .any(|shell| shell.role == PaneRole::Pi && shell.availability == Availability::Dormant)
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn mac_pins_exempt_both_limits_and_unpin_restores_normal_sleep() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let pinned = fixture.new_session().await;
    let other = fixture.new_session().await;
    fixture.wait_for_pi(pinned.id).await;
    fixture.wait_for_pi(other.id).await;
    let original = pid(&fixture.listed(pinned.id).unwrap(), PaneRole::Pi);
    fixture
        .core
        .local_pins
        .use_source(move || Ok([pinned.id].into_iter().collect()));
    assert_eq!(
        idle_pis::look(&fixture.core, SLEEP_ALL).await,
        vec![other.id]
    );
    assert!(alive(original));
    fixture
        .core
        .local_pins
        .use_source(|| Ok(Default::default()));
    assert_eq!(
        idle_pis::look(&fixture.core, SLEEP_ALL).await,
        vec![pinned.id]
    );
    fixture
        .until("unpinned Pi to become dormant", || {
            pi_is_dormant(&fixture, pinned.id)
        })
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn pinning_a_dormant_session_wakes_it_once_without_a_prompt() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let original = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);
    assert_eq!(
        idle_pis::look(&fixture.core, SLEEP_ALL).await,
        vec![record.id]
    );
    fixture
        .until("Pi asleep", || pi_is_dormant(&fixture, record.id))
        .await;
    fixture
        .core
        .local_pins
        .use_source(move || Ok([record.id].into_iter().collect()));
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    fixture.wait_for_pi(record.id).await;
    let awake = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);
    assert!(alive(awake) && awake != original);
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    assert_eq!(
        pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi),
        awake
    );
    assert!(!fixture.pi_log().contains("SENT:"));
    assert!(!fixture.pi_log().contains("RESUME_TURN"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pin_admitted_during_idle_shutdown_starts_only_after_the_old_pi_exits() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let original = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);
    fixture
        .core
        .local_pins
        .use_source(move || Ok([record.id].into_iter().collect()));
    fixture
        .core
        .registry
        .get(record.id)
        .unwrap()
        .call(|session| {
            Box::pin(async move {
                assert!(session.sleep_pi());
                assert!(session.keep_pinned_awake().await);
                assert!(
                    !session.keep_pinned_awake().await,
                    "reconciliation must not restart an already-retained process"
                );
            })
        })
        .await
        .unwrap();
    fixture
        .until("replacement Pi", || {
            let next = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);
            next != original && alive(next)
        })
        .await;
    fixture.wait_for_pi(record.id).await;
    assert!(!alive(original));
    assert!(!fixture.pi_log().contains("SENT:"));
    assert!(!fixture.pi_log().contains("RESUME_TURN"));
}

#[tokio::test(flavor = "multi_thread")]
async fn unavailable_pinned_agents_recover_but_stale_pins_cannot_reopen_closed_sessions() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let original = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);
    fixture
        .core
        .local_pins
        .use_source(move || Ok([record.id].into_iter().collect()));
    // This is an owned synthetic child, never a personal Session.
    assert!(original > 1);
    assert_eq!(unsafe { libc::kill(original, libc::SIGKILL) }, 0);
    fixture
        .until("unavailable agent", || {
            fixture
                .listed(record.id)
                .unwrap()
                .shells
                .iter()
                .any(|shell| {
                    shell.role == PaneRole::Pi
                        && matches!(shell.availability, Availability::Unavailable { .. })
                })
        })
        .await;
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    fixture.wait_for_pi(record.id).await;
    assert!(alive(pid(
        &fixture.listed(record.id).unwrap(),
        PaneRole::Pi
    )));
    sessions::close(&fixture.core, record.id).await.unwrap();
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    assert!(!fixture.core.registry.contains(record.id));
    assert!(fixture.listed(record.id).is_none());
    assert!(!fixture.pi_log().contains("SENT:"));
    assert!(!fixture.pi_log().contains("RESUME_TURN"));
}

#[tokio::test(flavor = "multi_thread")]
async fn old_pinned_sessions_start_with_axod_while_old_unpinned_sessions_stay_dormant() {
    let mut fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let pinned = fixture.new_session().await;
    let other = fixture.new_session().await;
    fixture.wait_for_pi(pinned.id).await;
    fixture.wait_for_pi(other.id).await;
    let old_pids = [
        pid(&fixture.listed(pinned.id).unwrap(), PaneRole::Pi),
        pid(&fixture.listed(other.id).unwrap(), PaneRole::Pi),
    ];
    sessions::stop(&fixture.core).await;
    fixture
        .until("old agents stopped", || {
            old_pids.iter().all(|pid| !alive(*pid))
        })
        .await;
    fixture
        .core
        .store
        .call(move |database| {
            // These fake agents have no messages: age creation without inventing transcript contents.
            database
                .execute(
                    "UPDATE sessions SET created_at = ?1, last_message_at = NULL",
                    rusqlite::params![axo_store::unix_timestamp() - 7200],
                )
                .map_err(std::io::Error::other)?;
            Ok(())
        })
        .await
        .unwrap();
    let (core, previous) = crate::open_core(
        &fixture.directory,
        &fixture.directory.join("sessions"),
        &fixture.directory.join("axod.sock"),
    )
    .unwrap();
    core.local_pins
        .use_source(move || Ok([pinned.id].into_iter().collect()));
    assert!(
        crate::local_pins::read(&core)
            .await
            .unwrap()
            .contains(&pinned.id)
    );
    sessions::restore(&core, previous).await.unwrap();
    fixture.core = core;
    assert!(
        !pi_is_dormant(&fixture, pinned.id),
        "pinned restore: {:?}",
        fixture.listed(pinned.id)
    );
    let ready = sessions::wait_for_pi(&fixture.core, pinned.id, Duration::from_secs(10)).await;
    assert!(
        ready.is_ok(),
        "pinned start: {:?}; state: {:?}",
        ready,
        fixture.listed(pinned.id)
    );
    assert!(alive(pid(
        &fixture.listed(pinned.id).unwrap(),
        PaneRole::Pi
    )));
    assert!(pi_is_dormant(&fixture, other.id));
    assert!(!fixture.pi_log().contains("SENT:"));
    assert!(!fixture.pi_log().contains("RESUME_TURN"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pin_added_after_the_idle_scan_is_rechecked_before_sleep() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let reads = std::sync::atomic::AtomicUsize::new(0);
    fixture.core.local_pins.use_source(move || {
        if reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
            Ok(Default::default())
        } else {
            Ok([record.id].into_iter().collect())
        }
    });
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    assert!(alive(pid(
        &fixture.listed(record.id).unwrap(),
        PaneRole::Pi
    )));
}

#[tokio::test(flavor = "multi_thread")]
async fn unreadable_mac_pins_do_not_get_treated_as_an_empty_preference() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    fixture
        .core
        .local_pins
        .use_source(|| Err(std::io::Error::other("synthetic read failure")));
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    assert!(alive(pid(
        &fixture.listed(record.id).unwrap(),
        PaneRole::Pi
    )));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_idle_pi_sleeps_and_its_session_stays_until_a_prompt_wakes_it() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let first = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);

    assert_eq!(
        idle_pis::look(&fixture.core, SLEEP_ALL).await,
        vec![record.id]
    );
    fixture
        .until("Pi to be dormant", || pi_is_dormant(&fixture, record.id))
        .await;
    assert!(!alive(first), "its process is gone");
    assert!(
        fixture.core.catalog.contains(record.id),
        "the Session stays"
    );
    assert!(
        idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty(),
        "a dormant Pi is not idle"
    );

    prompt(&fixture, record.id, "good morning").await;
    fixture
        .until("the prompt to reach a new Pi", || {
            fixture.pi_log().contains("SENT:good morning")
        })
        .await;
    let second = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);
    assert!(alive(second) && second != first);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_working_pi_is_never_put_to_sleep() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 30_000 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    prompt(&fixture, record.id, "a long job").await;
    fixture
        .until("Pi to be working", || {
            fixture.core.catalog.view().sessions[&record.id].working
        })
        .await;
    assert!(idle_pis::look(&fixture.core, SLEEP_ALL).await.is_empty());
    assert!(alive(pid(
        &fixture.listed(record.id).unwrap(),
        PaneRole::Pi
    )));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_prompt_while_pi_goes_to_sleep_waits_for_the_next_pi() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let first = pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi);

    assert_eq!(
        idle_pis::look(&fixture.core, SLEEP_ALL).await,
        vec![record.id]
    );
    assert!(
        prompt(&fixture, record.id, "wait for me").await,
        "it waits rather than going to a Pi that is exiting"
    );
    fixture
        .until("the prompt to reach the next Pi", || {
            fixture.pi_log().contains("SENT:wait for me")
        })
        .await;
    assert!(!alive(first));
    assert!(!pi_is_dormant(&fixture, record.id));
}

#[tokio::test(flavor = "multi_thread")]
async fn past_the_limit_the_longest_idle_pi_sleeps() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let older = fixture.new_session().await;
    fixture.wait_for_pi(older.id).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let newer = fixture.new_session().await;
    fixture.wait_for_pi(newer.id).await;

    let one_awake = Policy {
        limits: IdleLimits {
            timeout: None,
            awake: 1,
        },
        grace: Duration::ZERO,
    };
    assert_eq!(
        idle_pis::look(&fixture.core, one_awake).await,
        vec![older.id]
    );
    fixture
        .until("the older Pi to be dormant", || {
            pi_is_dormant(&fixture, older.id)
        })
        .await;
    assert!(!pi_is_dormant(&fixture, newer.id));
}
