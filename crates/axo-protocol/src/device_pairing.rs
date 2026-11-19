//! QR linking is separate from answering a question. Its signatures cannot approve an action.
use serde::{Deserialize, Serialize};

pub const PAIRING_LIFETIME_MS: u64 = 5 * 60_000;

/// A short-lived capability shown only in the trusted native UI. Never log or relay `secret`.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevicePairingInvitation {
    pub version: u8,
    pub id: String,
    pub account_id: String,
    pub host_id: String,
    pub expires_at: u64,
    pub input_key: String,
    pub secret: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevicePairingClaim {
    pub id: String,
    pub account_id: String,
    pub host_id: String,
    pub key: String,
    pub name: String,
    /// Signed by the new device: it possesses the key being linked.
    pub signature: String,
    /// Signed with the one-time capability read by the camera, never the capability itself.
    pub proof: String,
}

impl DevicePairingInvitation {
    pub fn claim_message(&self, claim: &DevicePairingClaim) -> Vec<u8> {
        format!(
            "axo-link-phone/v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\nhub",
            self.id,
            self.account_id,
            self.host_id,
            self.expires_at,
            self.input_key,
            claim.key,
            crate::base64::encode(claim.name.as_bytes())
        )
        .into_bytes()
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevicePairingReceipt {
    pub paired: bool,
    pub signature: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevicePairingStatus {
    pub id: Option<String>,
    pub paired: bool,
}

/// A hub may link a responder, not silently delegate its management capability.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceLinkGrant {
    pub account_id: String,
    pub id: String,
    pub host_id: String,
    pub expires_at: u64,
    pub key: String,
    pub name: String,
    pub manager_key: String,
    pub signature: String,
    pub device_signature: String,
}

impl DeviceLinkGrant {
    pub fn device_message(&self) -> Vec<u8> {
        format!(
            "axo-link-recipient/v1\n{}\n{}\n{}\n{}\n{}",
            self.account_id,
            self.id,
            self.expires_at,
            self.key,
            crate::base64::encode(self.name.as_bytes())
        )
        .into_bytes()
    }

    pub fn manager_message(&self) -> Vec<u8> {
        format!(
            "axo-link-grant/v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\nresponder",
            self.account_id,
            self.id,
            self.host_id,
            self.expires_at,
            self.key,
            crate::base64::encode(self.name.as_bytes()),
            self.manager_key
        )
        .into_bytes()
    }
}
