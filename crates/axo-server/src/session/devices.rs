//! Device-signed answers (RFD0029, every remote answer is signed): a phone or a browser signs
//! each answer with its own key, and axod takes it only from a key the person allowed here, in
//! Axo.app, after comparing its fingerprint with the one the device shows. So the cloud, or a bug
//! in it, cannot forge an answer, replay one onto another question, or turn a No into a Yes.
//!
//! An answer from a key axod does not know asks the person at the Mac (`device.requested`) and is
//! refused; its signature is burned, so it never counts later, even once the device is allowed:
//! the person answers again from it.

use std::collections::VecDeque;
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axo_ipc::TypedMethods;
use axo_ipc::peer::{self, Signer};
use axo_protocol::Event;
use axo_protocol::elicitation::{
    Device, DeviceChoice, DeviceProof, Devices, ElicitationAnswer, NOT_A_PERSON, NOT_TRUSTED,
    Sealed,
};
use axo_protocol::rpc::method;
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use serde_json::Value;

use super::SessionManager;

/// Devices waiting for the person at once; more are turned away until one is decided.
const MAX_PENDING: usize = 8;
/// Trusted devices at most.
const MAX_TRUSTED: usize = 64;
/// Refused signatures remembered, newest last.
const MAX_BURNED: usize = 1_024;
const MAX_NAME_CHARS: usize = 80;

#[derive(Default)]
struct State {
    trusted: Vec<Device>,
    pending: Vec<Device>,
    burned: VecDeque<String>,
}

pub(crate) struct DeviceTrust {
    path: PathBuf,
    state: Mutex<State>,
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default()
}

fn refused(message: String) -> (i64, String) {
    (NOT_TRUSTED, message)
}

impl DeviceTrust {
    /// The devices allowed before, from `path`; none if it is missing or unreadable.
    pub(crate) fn open(path: PathBuf) -> Self {
        let trusted = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Vec<Device>>(&bytes).ok())
            .unwrap_or_default();
        Self {
            path,
            state: Mutex::new(State {
                trusted,
                ..Default::default()
            }),
        }
    }

    fn save(&self, trusted: &[Device]) {
        let temporary = self.path.with_extension("json.tmp");
        let written = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .and_then(|mut file| {
                file.write_all(&serde_json::to_vec_pretty(trusted).unwrap_or_default())
            })
            .and_then(|()| fs::rename(&temporary, &self.path));
        if let Err(error) = written {
            log::warn!("event=devices.unsaved error={error}");
        }
    }

    /// Whether `proof` is a trusted device's signature over this answer (`signed`). A key it does
    /// not know, with a good signature, is held for the person (returned, to announce), and that
    /// signature burned.
    fn check(
        &self,
        signed: &[u8],
        proof: &DeviceProof,
    ) -> Result<(), ((i64, String), Option<Device>)> {
        let Ok(mut state) = self.state.lock() else {
            return Err((refused("device trust is unavailable".into()), None));
        };
        if state.burned.contains(&proof.signature) {
            return Err((
                refused("This answer was refused before; answer again.".into()),
                None,
            ));
        }
        // Only a key that signed this very answer counts, or asks: nobody asks in another's name.
        if !axo_seal::verify_answer(&proof.key, &proof.signature, signed) {
            return Err((
                refused("The answer's signature is not for this answer.".into()),
                None,
            ));
        }
        if state.trusted.iter().any(|device| device.key == proof.key) {
            return Ok(());
        }
        if state.burned.len() >= MAX_BURNED {
            state.burned.pop_front();
        }
        state.burned.push_back(proof.signature.clone());
        let fingerprint = axo_seal::fingerprint(&proof.key);
        let why = refused(format!(
            "This device isn't allowed to answer for this Mac yet. Allow it in Axo on the Mac, where it shows {fingerprint}, then answer again."
        ));
        if state.pending.iter().any(|device| device.key == proof.key)
            || state.pending.len() >= MAX_PENDING
        {
            return Err((why, None));
        }
        let device = Device {
            key: proof.key.clone(),
            name: proof.name.chars().take(MAX_NAME_CHARS).collect(),
            fingerprint,
            at: unix_millis(),
        };
        state.pending.push(device.clone());
        Err((why, Some(device)))
    }

    fn list(&self) -> Devices {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        Devices {
            trusted: state.trusted.clone(),
            pending: state.pending.clone(),
        }
    }

    /// Allows a waiting device, or turns it away. False if it was not waiting.
    fn decide(&self, key: &str, allow: bool) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(index) = state.pending.iter().position(|device| device.key == key) else {
            return false;
        };
        let mut device = state.pending.remove(index);
        if allow && state.trusted.len() < MAX_TRUSTED {
            device.at = unix_millis();
            state.trusted.push(device);
            let trusted = state.trusted.clone();
            drop(state);
            self.save(&trusted);
        }
        true
    }

    /// Stops taking a device's answers. False if it was not trusted.
    fn revoke(&self, key: &str) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let before = state.trusted.len();
        state.trusted.retain(|device| device.key != key);
        let changed = state.trusted.len() != before;
        let trusted = state.trusted.clone();
        drop(state);
        if changed {
            self.save(&trusted);
        }
        changed
    }
}

impl SessionManager {
    /// A remote answer counts only with a trusted device's signature over that answer.
    pub(crate) fn check_answer(
        &self,
        id: &str,
        answer: ElicitationAnswer,
        sealed: Option<&Sealed>,
        device: Option<&DeviceProof>,
    ) -> Result<(), (i64, String)> {
        let Some(proof) = device else {
            return Err(refused(
                "Answers must be signed by your device: update Axo there.".into(),
            ));
        };
        let action = match answer {
            ElicitationAnswer::Accept => "accept",
            ElicitationAnswer::Decline => "decline",
        };
        let signed = axo_seal::answer_message(
            id,
            action,
            sealed.map(|sealed| (sealed.enc.as_str(), sealed.ciphertext.as_str())),
        );
        match self.devices.check(&signed, proof) {
            Ok(()) => Ok(()),
            Err((why, asking)) => {
                log::warn!("event=devices.answer_refused asked={}", asking.is_some());
                if let Some(device) = asking {
                    self.publish_event(Event::DeviceRequested { device });
                }
                Err(why)
            }
        }
    }
}

fn not_axo_app() -> RpcError {
    RpcError {
        code: ErrorCode::ServerError(NOT_A_PERSON),
        message: "only the person at the Mac, in Axo.app, decides which devices answer".into(),
        data: None,
    }
}

/// Registers `axo.device.list`, and `axo.device.trust` and `axo.device.revoke` for Axo.app alone.
pub(crate) fn add_methods(manager: &Arc<SessionManager>, handler: &mut IoHandler) {
    let listing = Arc::clone(manager);
    handler.add_typed(
        method::DEVICE_LIST,
        "expected no parameters",
        move |_: Value| Ok(listing.devices.list()),
    );
    let trusting = Arc::clone(manager);
    handler.add_typed(
        method::DEVICE_TRUST,
        "expected {key, allow?}",
        move |choice: DeviceChoice| {
            if !peer::current().is(Signer::AxoApp) {
                return Err(not_axo_app());
            }
            let decided = trusting.devices.decide(&choice.key, choice.allow);
            if decided {
                log::info!("event=devices.decided allowed={}", choice.allow);
                trusting.publish_event(Event::DevicesChanged);
            }
            Ok(serde_json::json!({ "decided": decided }))
        },
    );
    let revoking = Arc::clone(manager);
    handler.add_typed(
        method::DEVICE_REVOKE,
        "expected {key}",
        move |choice: DeviceChoice| {
            if !peer::current().is(Signer::AxoApp) {
                return Err(not_axo_app());
            }
            let revoked = revoking.devices.revoke(&choice.key);
            if revoked {
                log::info!("event=devices.revoked");
                revoking.publish_event(Event::DevicesChanged);
            }
            Ok(serde_json::json!({ "revoked": revoked }))
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A device as the tests sign with: a software P-256 key, as the phone's tests do.
    fn sign(secret: &p256::ecdsa::SigningKey, id: &str, action: &str) -> DeviceProof {
        // Randomized, as WebCrypto's and CryptoKit's signatures are: no two are the same.
        use p256::ecdsa::signature::RandomizedSigner as _;
        let signature: p256::ecdsa::Signature = secret.sign_with_rng(
            &mut p256::elliptic_curve::rand_core::OsRng,
            &axo_seal::answer_message(id, action, None),
        );
        DeviceProof {
            key: axo_protocol::base64::encode(
                secret.verifying_key().to_encoded_point(false).as_bytes(),
            ),
            name: "Leo's iPhone".into(),
            signature: axo_protocol::base64::encode(&signature.to_bytes()),
        }
    }

    #[test]
    fn only_a_device_allowed_at_the_mac_answers_and_only_for_what_it_signed() {
        let directory = std::env::temp_dir().join(format!(
            "axo-devices-{}",
            axo_protocol::new_uuid_v4().unwrap()
        ));
        fs::create_dir_all(&directory).unwrap();
        let trust = DeviceTrust::open(directory.join("devices.json"));
        let phone = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let first = sign(&phone, "r1", "decline");
        let signed = |id: &str, action: &str| axo_seal::answer_message(id, action, None);

        // Unknown: refused, and held for the person.
        let (why, asking) = trust.check(&signed("r1", "decline"), &first).unwrap_err();
        assert_eq!(why.0, NOT_TRUSTED);
        assert_eq!(
            asking.unwrap().fingerprint,
            axo_seal::fingerprint(&first.key)
        );
        assert_eq!(trust.list().pending.len(), 1);
        // A signature over another answer asks nothing.
        assert!(
            trust
                .check(&signed("r1", "accept"), &first)
                .unwrap_err()
                .1
                .is_none()
        );

        assert!(trust.decide(&first.key, true));
        // The answer refused before never counts; a new one does, for what it signed alone.
        assert!(trust.check(&signed("r1", "decline"), &first).is_err());
        let again = sign(&phone, "r1", "decline");
        assert!(trust.check(&signed("r1", "decline"), &again).is_ok());
        assert!(trust.check(&signed("r2", "decline"), &again).is_err());
        assert!(trust.check(&signed("r1", "accept"), &again).is_err());

        // Kept across restarts, until revoked.
        let reopened = DeviceTrust::open(directory.join("devices.json"));
        assert_eq!(reopened.list().trusted.len(), 1);
        assert!(reopened.revoke(&first.key));
        assert!(
            reopened
                .check(&signed("r3", "accept"), &sign(&phone, "r3", "accept"))
                .is_err()
        );
        let _ = fs::remove_dir_all(&directory);
    }
}
