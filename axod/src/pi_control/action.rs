//! Command-correlated acknowledgement evidence; never model execution/delivery.
use super::{ChatId, ControlError, InteractionId, OptionId, QuestionId};
use crate::model::{CommandId, RuntimeRef};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Action {
    Send {
        text: String,
    },
    Steer {
        interaction_id: InteractionId,
        text: String,
    },
    Cancel {
        interaction_id: InteractionId,
    },
    Answer {
        interaction_id: InteractionId,
        question_id: QuestionId,
        option_id: OptionId,
    },
}
impl Action {
    pub(super) fn digest(&self) -> Result<[u8; 32], ControlError> {
        if let Self::Send { text } | Self::Steer { text, .. } = self
            && text.len() > super::REQUEST_BYTES
        {
            return Err(ControlError::Capacity);
        }
        let bytes = serde_json::to_vec(self).map_err(|_| ControlError::Invalid)?;
        // Bound before hashing and keep the same budget as the wire producer.
        if bytes.len() > super::REQUEST_BYTES {
            return Err(ControlError::Capacity);
        }
        let mut hash = Sha256::new();
        hash.update(b"axo.pi-control.action.v1\0");
        hash.update(bytes);
        Ok(hash.finalize().into())
    }
}
/// Minted only after the exact correlated extension acknowledgement. Not Clone,
/// Copy, deserializable or publicly constructible; one original consumes it.
pub struct Dispatched {
    command: CommandId,
    runtime: RuntimeRef,
    chat: ChatId,
    action: [u8; 32],
}
impl Dispatched {
    pub(super) fn acknowledged(
        command: CommandId,
        runtime: RuntimeRef,
        chat: ChatId,
        action: [u8; 32],
    ) -> Self {
        Self {
            command,
            runtime,
            chat,
            action,
        }
    }
    pub fn matches(
        &self,
        command: CommandId,
        runtime: RuntimeRef,
        chat: ChatId,
        action: &Action,
    ) -> bool {
        self.command == command
            && self.runtime == runtime
            && self.chat == chat
            && action.digest().is_ok_and(|digest| digest == self.action)
    }
}
/// Lifecycle shutdown is not a submitted-input receipt.
pub struct ShutdownAcknowledged {
    pub(super) _ack: (),
}
