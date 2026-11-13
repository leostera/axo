//! Idle Pis going to sleep and waking (RFD0045).

use std::time::Duration;

use axo_protocol::rpc::{PromptDelivery, PromptSession, PromptText};
use axo_protocol::{Availability, PaneRole, SessionId};

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
        PromptSession {
            session_id: id,
            text: PromptText::parse(text.into()).unwrap(),
            delivery: PromptDelivery::FollowUp,
            from_session_id: None,
        },
        None,
        Vec::new(),
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
