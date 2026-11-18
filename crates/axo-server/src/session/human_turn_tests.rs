//! Scheduling protection belongs to one Session/run, and explicit Stop remains an override.
use super::super::prompts::Prompt;
use super::{Admission, PiState};
use crate::test_support::{Fixture, Pi};
use axo_protocol::rpc::PromptDelivery;

fn prompt() -> Prompt {
    Prompt {
        text: "real user words".into(),
        delivery: PromptDelivery::Interrupt,
        command_id: None,
        attachments: Vec::new(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn settlement_releases_protection_but_unconfirmed_stop_does_not() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    fixture
        .core
        .registry
        .get(record.id)
        .unwrap()
        .call(|session| {
            Box::pin(async move {
                let runtime_id = match &session.pi.as_ref().unwrap().state {
                    PiState::Running { runtime_id, .. } => *runtime_id,
                    _ => panic!("fixture Pi is running"),
                };
                session.protect_human_turn();
                assert!(matches!(
                    session.admit_prompt(prompt()).await.unwrap(),
                    Admission::Send {
                        delivery: PromptDelivery::FollowUp,
                        ..
                    }
                ));
                session
                    .pi_event(runtime_id, "agent.settled", &serde_json::json!({}))
                    .await;
                assert!(matches!(
                    session.admit_prompt(prompt()).await.unwrap(),
                    Admission::Send {
                        delivery: PromptDelivery::Interrupt,
                        ..
                    }
                ));
                session.protect_human_turn();
                // The dedicated Stop path remains available, without authorizing a later
                // Send to interrupt work if the Stop itself is stale or loses its receipt.
                session.pi_stop_link().unwrap();
                assert!(matches!(
                    session.admit_prompt(prompt()).await.unwrap(),
                    Admission::Send {
                        delivery: PromptDelivery::FollowUp,
                        ..
                    }
                ));
            })
        })
        .await
        .unwrap();
}

/// While the queue is being sent to a Pi that just came up, new prompts queue behind it instead
/// of overtaking it on the link.
#[tokio::test(flavor = "multi_thread")]
async fn prompts_taken_during_a_flush_queue_behind_it() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    fixture
        .core
        .registry
        .get(record.id)
        .unwrap()
        .call(|session| {
            Box::pin(async move {
                session.pi.as_mut().unwrap().flushing = true;
                let mut later = prompt();
                later.delivery = PromptDelivery::FollowUp;
                assert!(matches!(
                    session.admit_prompt(later).await.unwrap(),
                    Admission::Queued { .. }
                ));
            })
        })
        .await
        .unwrap();
}
