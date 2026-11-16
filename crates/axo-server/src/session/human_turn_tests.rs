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
async fn settlement_and_explicit_stop_release_human_turn_protection() {
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
                session.pi_stop_link().unwrap();
                assert!(matches!(
                    session.admit_prompt(prompt()).await.unwrap(),
                    Admission::Send {
                        delivery: PromptDelivery::Interrupt,
                        ..
                    }
                ));
            })
        })
        .await
        .unwrap();
}
