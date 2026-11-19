//! Physical QR bootstrap and narrowly delegated linking (RFD0078).
//! The relay never receives the QR capability and cannot create one through local agent IPC.
use crate::core::{Core, lock};
use axo_ipc::peer::{Caller, Signer};
use axo_ipc::{Extension, IoHandler, Only, TypedMethods};
use axo_protocol::device_pairing::{
    DeviceLinkGrant, DevicePairingClaim, DevicePairingInvitation, DevicePairingReceipt,
    PAIRING_LIFETIME_MS,
};
use axo_protocol::rpc::{MethodError, NoParams};
use std::sync::{Arc, Mutex};
use zeroize::Zeroize;

pub(crate) const CREATE: &str = "axo.device.pairing.create";
pub(crate) const CANCEL: &str = "axo.device.pairing.cancel";
pub(crate) const STATUS: &str = "axo.device.pairing.status";
pub(crate) const REDEEM: &str = "axo.remote.device.pairing.redeem";
pub(crate) const LINK: &str = "axo.remote.device.link";
pub(crate) const UNLINK: &str = "axo.remote.device.unlink";
const REFUSED: i64 = -32017;

struct Pending {
    invitation: DevicePairingInvitation,
    secret: zeroize::Zeroizing<Vec<u8>>,
    claimed: Option<Claimed>,
}

struct Claimed {
    message: Vec<u8>,
    receipt: DevicePairingReceipt,
    key: String,
}

#[derive(Default)]
pub(crate) struct Pairing(Mutex<Option<Pending>>);

fn refused() -> MethodError {
    MethodError::new(
        REFUSED,
        "Pairing expired, changed, or was not authorized. Start linking again.",
    )
}
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.trim() == name
        && name.chars().count() <= 80
        && !name.chars().any(char::is_control)
}
fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|n| n.as_millis() as u64)
        .unwrap_or_default()
}

impl Pairing {
    fn create(
        &self,
        account: String,
        host: String,
        input_key: String,
        at: u64,
    ) -> Result<DevicePairingInvitation, MethodError> {
        if !axo_protocol::is_uuid(&account) || !axo_protocol::is_uuid(&host) {
            return Err(refused());
        }
        let secret = axo_seal::new_pairing_secret();
        let invitation = DevicePairingInvitation {
            version: 1,
            id: axo_protocol::new_uuid_v4().map_err(|_| refused())?,
            account_id: account,
            host_id: host,
            expires_at: at + PAIRING_LIFETIME_MS,
            input_key,
            secret: axo_protocol::base64::encode(&secret),
        };
        let mut metadata = invitation.clone();
        metadata.secret.zeroize();
        *lock(&self.0) = Some(Pending {
            invitation: metadata,
            secret,
            claimed: None,
        });
        Ok(invitation)
    }

    fn status(&self, at: u64) -> axo_protocol::device_pairing::DevicePairingStatus {
        let mut state = lock(&self.0);
        if state
            .as_ref()
            .is_some_and(|pending| pending.invitation.expires_at <= at)
        {
            *state = None;
        }
        axo_protocol::device_pairing::DevicePairingStatus {
            id: state.as_ref().map(|pending| pending.invitation.id.clone()),
            paired: state
                .as_ref()
                .is_some_and(|pending| pending.claimed.is_some()),
        }
    }

    pub(crate) fn cancel(&self) {
        *lock(&self.0) = None;
    }

    fn redeem(
        &self,
        devices: &crate::devices::AllowedDevices,
        claim: DevicePairingClaim,
        account: &str,
        at: u64,
    ) -> Result<DevicePairingReceipt, MethodError> {
        if !valid_name(&claim.name)
            || claim.key.len() != 88
            || claim.signature.len() != 88
            || claim.proof.len() != 88
        {
            return Err(refused());
        }
        let mut state = lock(&self.0);
        let pending = state.as_mut().ok_or_else(refused)?;
        let invitation = &pending.invitation;
        if invitation.expires_at <= at
            || invitation.account_id != account
            || invitation.account_id != claim.account_id
            || invitation.host_id != claim.host_id
            || invitation.id != claim.id
        {
            return Err(refused());
        }
        let message = invitation.claim_message(&claim);
        let capability = axo_seal::pairing_public(&pending.secret).ok_or_else(refused)?;
        if !axo_seal::verify_answer(&capability, &claim.proof, &message)
            || !axo_seal::verify_answer(&claim.key, &claim.signature, &message)
        {
            return Err(refused());
        }
        if let Some(claimed) = &pending.claimed {
            // Identical transport retry, never a re-grant after revocation or another recipient.
            return if claimed.message == message && devices.can_link(&claimed.key) {
                Ok(claimed.receipt.clone())
            } else {
                Err(refused())
            };
        }
        devices
            .link(&claim.key, &claim.name, true)
            .map_err(|_| refused())?;
        let receipt_message = format!(
            "axo-link-phone-receipt/v1\n{}",
            axo_protocol::base64::encode(&message)
        );
        let receipt = DevicePairingReceipt {
            paired: true,
            signature: axo_seal::pairing_sign(&pending.secret, receipt_message.as_bytes())
                .ok_or_else(refused)?,
        };
        pending.claimed = Some(Claimed {
            message,
            receipt: receipt.clone(),
            key: claim.key,
        });
        Ok(receipt)
    }
}

fn account(core: &Core) -> Result<String, MethodError> {
    core.assets
        .get()
        .map(|source| source.account.account_id().to_owned())
        .ok_or_else(|| {
            MethodError::new(
                REFUSED,
                "Connect this Axo to your account before linking a phone.",
            )
        })
}

fn authorize_grant(
    devices: &crate::devices::AllowedDevices,
    grant: &DeviceLinkGrant,
    account: &str,
    host: &str,
    at: u64,
) -> Result<(), MethodError> {
    if grant.account_id != account
        || grant.host_id != host
        || !axo_protocol::is_uuid(&grant.id)
        || !valid_name(&grant.name)
        || grant.expires_at <= at
        || grant.expires_at > at + PAIRING_LIFETIME_MS
        || grant.key.len() != 88
        || grant.manager_key.len() != 88
        || grant.signature.len() != 88
        || grant.device_signature.len() != 88
        || grant.key == grant.manager_key
        || !devices.can_link(&grant.manager_key)
        || !axo_seal::verify_answer(&grant.key, &grant.device_signature, &grant.device_message())
        || !axo_seal::verify_answer(
            &grant.manager_key,
            &grant.signature,
            &grant.manager_message(),
        )
    {
        return Err(refused());
    }
    devices.link_once(grant, at).map_err(|_| refused())
}

pub(crate) struct DevicePairingExtension(pub(crate) Arc<Core>);
impl Extension for DevicePairingExtension {
    fn name(&self) -> &'static str {
        "device_pairing"
    }
    fn register(&self, handler: &mut IoHandler) {
        let person = Only {
            caller: Caller::Signed(Signer::AxoApp),
            code: axo_protocol::elicitation::NOT_A_PERSON,
            message: "only the person in signed Axo.app creates or cancels a linking code",
        };
        let core = Arc::clone(&self.0);
        handler.add_typed_only(
            person,
            CREATE,
            "expected no parameters",
            move |_: NoParams| {
                let core = Arc::clone(&core);
                async move {
                    let owner = account(&core).map_err(axo_ipc::rpc_error)?;
                    let input = core
                        .input_keys
                        .get()
                        .await
                        .ok_or_else(|| axo_ipc::rpc_error(refused()))?;
                    core.device_pairing
                        .create(owner, core.host_id.clone(), input.public_key(), now())
                        .map_err(axo_ipc::rpc_error)
                }
            },
        );
        let core = Arc::clone(&self.0);
        handler.add_typed_only(
            person,
            CANCEL,
            "expected no parameters",
            move |_: NoParams| {
                let core = Arc::clone(&core);
                async move {
                    core.device_pairing.cancel();
                    Ok(serde_json::json!({"cancelled": true}))
                }
            },
        );
        let status_core = Arc::clone(&self.0);
        handler.add_typed_only(
            person,
            STATUS,
            "expected no parameters",
            move |_: NoParams| {
                let core = Arc::clone(&status_core);
                async move { Ok(core.device_pairing.status(now())) }
            },
        );
        let relay = Only {
            caller: Caller::Relay,
            code: -32601,
            message: "Method not found",
        };
        let core = Arc::clone(&self.0);
        handler.add_typed_only(
            relay,
            REDEEM,
            "invalid pairing claim",
            move |claim: DevicePairingClaim| {
                let core = Arc::clone(&core);
                async move {
                    let owner = account(&core).map_err(axo_ipc::rpc_error)?;
                    let receipt = core
                        .device_pairing
                        .redeem(&core.devices, claim, &owner, now())
                        .map_err(axo_ipc::rpc_error)?;
                    core.events.publish(axo_protocol::Event::DevicesChanged);
                    Ok(receipt)
                }
            },
        );
        let unlinking = Arc::clone(&self.0);
        handler.add_typed_only(
            relay,
            UNLINK,
            "invalid device revocation",
            move |request: axo_protocol::device_unlinking::DeviceUnlink| {
                let core = Arc::clone(&unlinking);
                async move {
                    let at = now();
                    if request.account_id != account(&core).map_err(axo_ipc::rpc_error)?
                        || request.host_id != core.host_id
                        || !axo_protocol::is_uuid(&request.link_id)
                        || request.expires_at <= at
                        || request.expires_at > at + PAIRING_LIFETIME_MS
                        || request.key.len() != 88
                        || request.manager_key.len() != 88
                        || request.signature.len() != 88
                        || !axo_seal::verify_answer(
                            &request.manager_key,
                            &request.signature,
                            &request.message(),
                        )
                    {
                        return Err(axo_ipc::rpc_error(refused()));
                    }
                    core.devices
                        .unlink(&request.manager_key, &request.key, &request.link_id)
                        .map_err(|_| axo_ipc::rpc_error(refused()))?;
                    core.events.publish(axo_protocol::Event::DevicesChanged);
                    Ok(serde_json::json!({"unlinked": true}))
                }
            },
        );
        let core = Arc::clone(&self.0);
        handler.add_typed_only(
            relay,
            LINK,
            "invalid device grant",
            move |grant: DeviceLinkGrant| {
                let core = Arc::clone(&core);
                async move {
                    let owner = account(&core).map_err(axo_ipc::rpc_error)?;
                    authorize_grant(&core.devices, &grant, &owner, &core.host_id, now())
                        .map_err(axo_ipc::rpc_error)?;
                    core.events.publish(axo_protocol::Event::DevicesChanged);
                    Ok(serde_json::json!({"linked": true}))
                }
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (
        Pairing,
        crate::devices::AllowedDevices,
        DevicePairingInvitation,
        Vec<u8>,
    ) {
        let path = crate::test_support::test_directory("axo-qr-pairing");
        std::fs::create_dir_all(&path).unwrap();
        let devices = crate::devices::AllowedDevices::open(path.join("devices.json")).unwrap();
        let pairing = Pairing::default();
        let input = axo_seal::InputKey::generate();
        let qr = pairing
            .create(
                axo_protocol::new_uuid_v4().unwrap(),
                axo_protocol::new_uuid_v4().unwrap(),
                input.public_key(),
                1000,
            )
            .unwrap();
        (
            pairing,
            devices,
            qr,
            axo_seal::new_pairing_secret().to_vec(),
        )
    }
    fn claim(qr: &DevicePairingInvitation, secret: &[u8]) -> DevicePairingClaim {
        let mut claim = DevicePairingClaim {
            id: qr.id.clone(),
            account_id: qr.account_id.clone(),
            host_id: qr.host_id.clone(),
            key: axo_seal::pairing_public(secret).unwrap(),
            name: "New phone".into(),
            signature: String::new(),
            proof: String::new(),
        };
        let message = qr.claim_message(&claim);
        claim.signature = axo_seal::pairing_sign(secret, &message).unwrap();
        claim.proof =
            axo_seal::pairing_sign(&axo_protocol::base64::decode(&qr.secret).unwrap(), &message)
                .unwrap();
        claim
    }
    #[test]
    fn a_scan_links_exactly_one_key_and_authenticates_the_receipt() {
        let (pairing, devices, qr, key) = fixture();
        let claiming = claim(&qr, &key);
        let receipt = pairing
            .redeem(&devices, claiming.clone(), &qr.account_id, 2000)
            .unwrap();
        assert!(devices.can_link(&claiming.key));
        let message = format!(
            "axo-link-phone-receipt/v1\n{}",
            axo_protocol::base64::encode(&qr.claim_message(&claiming))
        );
        assert!(axo_seal::verify_answer(
            &axo_seal::pairing_public(&axo_protocol::base64::decode(&qr.secret).unwrap()).unwrap(),
            &receipt.signature,
            message.as_bytes()
        ));
        assert!(
            pairing
                .redeem(&devices, claiming, &qr.account_id, 2001)
                .is_ok()
        );
        assert!(
            pairing
                .redeem(
                    &devices,
                    claim(&qr, &axo_seal::new_pairing_secret()),
                    &qr.account_id,
                    2002
                )
                .is_err()
        );
    }
    #[test]
    fn only_a_qr_linked_manager_can_delegate_and_revocation_survives_replay_and_restart() {
        let (pairing, devices, qr, manager) = fixture();
        let claiming = claim(&qr, &manager);
        pairing
            .redeem(&devices, claiming.clone(), &qr.account_id, 2000)
            .unwrap();
        let recipient = axo_seal::new_pairing_secret();
        let mut grant = DeviceLinkGrant {
            account_id: qr.account_id.clone(),
            host_id: qr.host_id.clone(),
            id: axo_protocol::new_uuid_v4().unwrap(),
            expires_at: 10000,
            key: axo_seal::pairing_public(&recipient).unwrap(),
            name: "New iPad".into(),
            manager_key: claiming.key.clone(),
            signature: String::new(),
            device_signature: String::new(),
        };
        grant.device_signature =
            axo_seal::pairing_sign(&recipient, &grant.device_message()).unwrap();
        grant.signature = axo_seal::pairing_sign(&manager, &grant.manager_message()).unwrap();
        assert!(authorize_grant(&devices, &grant, &qr.account_id, &qr.host_id, 3000).is_ok());
        assert!(devices.contains(&grant.key));
        assert!(
            !devices.can_link(&grant.key),
            "responders cannot silently become managers"
        );
        for mutation in ["account", "host", "key", "name", "signature", "expired"] {
            let mut changed = grant.clone();
            match mutation {
                "account" => changed.account_id = axo_protocol::new_uuid_v4().unwrap(),
                "host" => changed.host_id = axo_protocol::new_uuid_v4().unwrap(),
                "key" => changed.key = claiming.key.clone(),
                "name" => changed.name = "Changed device".into(),
                "signature" => changed.signature = grant.device_signature.clone(),
                _ => changed.expires_at = 2999,
            }
            assert!(
                authorize_grant(&devices, &changed, &qr.account_id, &qr.host_id, 3000).is_err(),
                "{mutation}"
            );
        }
        devices
            .unlink(&claiming.key, &grant.key, &grant.id)
            .unwrap();
        assert!(!devices.contains(&grant.key));
        assert!(
            authorize_grant(&devices, &grant, &qr.account_id, &qr.host_id, 3001).is_err(),
            "a consumed grant cannot undo unlink"
        );
    }

    #[test]
    fn the_relay_cannot_substitute_a_key_account_host_name_or_signature() {
        let (pairing, devices, qr, key) = fixture();
        let good = claim(&qr, &key);
        for field in ["key", "account", "host", "name", "proof", "signature"] {
            let mut bad = good.clone();
            match field {
                "key" => {
                    bad.key = axo_seal::pairing_public(&axo_seal::new_pairing_secret()).unwrap()
                }
                "account" => bad.account_id = axo_protocol::new_uuid_v4().unwrap(),
                "host" => bad.host_id = axo_protocol::new_uuid_v4().unwrap(),
                "name" => bad.name = "Different phone".into(),
                "proof" => bad.proof = bad.signature.clone(),
                _ => bad.signature = bad.proof.clone(),
            }
            assert!(
                pairing.redeem(&devices, bad, &qr.account_id, 2000).is_err(),
                "{field}"
            );
        }
        assert!(!devices.can_link(&good.key));
        assert!(
            pairing
                .redeem(&devices, good.clone(), &qr.account_id, qr.expires_at)
                .is_err()
        );
        pairing.cancel();
        assert!(
            pairing
                .redeem(&devices, good, &qr.account_id, 2000)
                .is_err()
        );
    }
}
