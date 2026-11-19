//! Scoped, signed revocation; never interchangeable with an approval or linking grant.
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceUnlink {
    pub account_id: String,
    pub host_id: String,
    pub link_id: String,
    pub expires_at: u64,
    pub key: String,
    pub manager_key: String,
    pub signature: String,
}

impl DeviceUnlink {
    pub fn message(&self) -> Vec<u8> {
        format!(
            "axo-unlink-device/v1\n{}\n{}\n{}\n{}\n{}\n{}",
            self.account_id,
            self.host_id,
            self.link_id,
            self.expires_at,
            self.key,
            self.manager_key
        )
        .into_bytes()
    }
}
