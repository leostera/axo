//! The devices allowed to answer this Mac's questions (RFD0077). A phone or a browser signs each
//! answer with its own key, over that request's id, the action and the sealed values, and axod
//! takes it only from a key the person allowed here, in Axo.app, after comparing its fingerprint
//! with the one the device shows. So the cloud, or a bug in it, cannot forge an answer with a key
//! of its own, replay one onto another question, or turn a No into a Yes.
//!
//! An answer from a key axod does not know asks the person at the Mac (`device.requested`) and is
//! refused. Its signature is burned, so it never counts later, even once the device is allowed:
//! the person answers again from it.

use std::collections::VecDeque;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axo_ipc::peer::{Caller, Signer};
use axo_ipc::{Extension, IoHandler, Only, TypedMethods};
use axo_protocol::Event;
use axo_protocol::elicitation::{
    BAD_SIGNATURE, DecideDevice, Device, DeviceDecided, DeviceProof, DeviceRevoked, Devices,
    ElicitationAnswer, NOT_A_PERSON, RevokeDevice, Sealed, UNKNOWN_DEVICE,
};
use axo_protocol::rpc::{MethodError, NoParams, method};

use crate::core::{Core, lock};

/// Where the allowed devices are kept, in axod's directory.
pub(crate) const DEVICES_FILE: &str = "devices.json";
/// Devices waiting for the person at once; more are turned away until one is decided.
const MAX_WAITING: usize = 8;
/// Allowed devices at most.
const MAX_ALLOWED: usize = 64;
/// Refused signatures remembered, newest last.
const MAX_BURNED: usize = 1_024;
const MAX_NAME_CHARS: usize = 80;

#[derive(Default)]
struct State {
    allowed: Vec<Device>,
    waiting: Vec<Device>,
    burned: VecDeque<String>,
}

/// Why an answer did not count, and the device it puts in front of the person, if any.
#[derive(Debug)]
pub(crate) struct Refusal {
    pub(crate) error: MethodError,
    pub(crate) asking: Option<Device>,
}

impl Refusal {
    fn bad_signature(message: &str) -> Self {
        Self {
            error: MethodError::new(BAD_SIGNATURE, message),
            asking: None,
        }
    }

    fn unknown(message: String, asking: Option<Device>) -> Self {
        Self {
            error: MethodError::new(UNKNOWN_DEVICE, message),
            asking,
        }
    }
}

pub(crate) struct AllowedDevices {
    path: PathBuf,
    state: Mutex<State>,
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default()
}

impl AllowedDevices {
    /// The devices allowed before, from `path`; none when there is no file yet. A file that is
    /// there but unreadable fails: starting with none would quietly drop the person's choices.
    pub(crate) fn open(path: PathBuf) -> io::Result<Self> {
        let allowed = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Vec<Device>>(&bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error),
        };
        Ok(Self {
            path,
            state: Mutex::new(State {
                allowed,
                ..State::default()
            }),
        })
    }

    fn save(&self, allowed: &[Device]) -> io::Result<()> {
        let temporary = self.path.with_extension("json.tmp");
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec_pretty(allowed).map_err(io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(&temporary, &self.path)
    }

    /// Whether `proof` is an allowed device's signature over this answer. A key it does not know,
    /// with a good signature, waits for the person (returned, to announce), and that signature
    /// is burned.
    pub(crate) fn check(
        &self,
        id: &str,
        answer: ElicitationAnswer,
        sealed: Option<&Sealed>,
        proof: Option<&DeviceProof>,
    ) -> Result<(), Refusal> {
        let Some(proof) = proof else {
            return Err(Refusal::bad_signature(
                "Answers must be signed by your device: update Axo there.",
            ));
        };
        let mut state = lock(&self.state);
        if state.burned.contains(&proof.signature) {
            return Err(Refusal::unknown(
                "This answer was refused before; answer again.".into(),
                None,
            ));
        }
        // Only a key that signed this very answer counts, or asks: nobody asks in another's name.
        let signed = axo_seal::answer_message(id, answer, sealed);
        if !axo_seal::verify_answer(&proof.key, &proof.signature, &signed) {
            return Err(Refusal::bad_signature(
                "The answer's signature is not for this answer.",
            ));
        }
        if state.allowed.iter().any(|device| device.key == proof.key) {
            return Ok(());
        }
        if state.burned.len() >= MAX_BURNED {
            state.burned.pop_front();
        }
        state.burned.push_back(proof.signature.clone());
        // A verified key is base64, so it has a fingerprint.
        let fingerprint = axo_seal::fingerprint(&proof.key).unwrap_or_default();
        let why = format!(
            "This device isn't allowed to answer for this Mac yet. Allow it in Axo on the Mac (Settings › Devices), where it shows {fingerprint}, then answer again."
        );
        if state.waiting.iter().any(|device| device.key == proof.key)
            || state.waiting.len() >= MAX_WAITING
        {
            return Err(Refusal::unknown(why, None));
        }
        let device = Device {
            key: proof.key.clone(),
            name: proof.name.chars().take(MAX_NAME_CHARS).collect(),
            fingerprint,
            at: unix_millis(),
        };
        state.waiting.push(device.clone());
        Err(Refusal::unknown(why, Some(device)))
    }

    fn list(&self, input_key: Option<String>) -> Devices {
        let state = lock(&self.state);
        Devices {
            allowed: state.allowed.clone(),
            waiting: state.waiting.clone(),
            input_key,
        }
    }

    /// Allows a waiting device, or turns it away. False if it was not waiting.
    fn decide(&self, key: &str, allow: bool) -> io::Result<bool> {
        let mut state = lock(&self.state);
        let Some(index) = state.waiting.iter().position(|device| device.key == key) else {
            return Ok(false);
        };
        if !allow {
            state.waiting.remove(index);
            return Ok(true);
        }
        if state.allowed.len() >= MAX_ALLOWED {
            return Err(io::Error::other(
                "too many devices are allowed: remove one first",
            ));
        }
        let mut allowed = state.allowed.clone();
        let mut device = state.waiting[index].clone();
        device.at = unix_millis();
        allowed.push(device);
        // Kept on disk before it counts, so a device allowed is never forgotten by a restart.
        self.save(&allowed)?;
        state.waiting.remove(index);
        state.allowed = allowed;
        Ok(true)
    }

    /// Stops taking a device's answers. False if it was not allowed.
    fn revoke(&self, key: &str) -> io::Result<bool> {
        let mut state = lock(&self.state);
        let allowed: Vec<Device> = state
            .allowed
            .iter()
            .filter(|device| device.key != key)
            .cloned()
            .collect();
        if allowed.len() == state.allowed.len() {
            return Ok(false);
        }
        self.save(&allowed)?;
        state.allowed = allowed;
        Ok(true)
    }
}

/// A remote answer counts only with an allowed device's signature over that answer.
pub(crate) fn check_answer(
    core: &Core,
    id: &str,
    answer: ElicitationAnswer,
    sealed: Option<&Sealed>,
    device: Option<&DeviceProof>,
) -> Result<(), MethodError> {
    core.devices
        .check(id, answer, sealed, device)
        .map_err(|refusal| {
            log::warn!(
                "event=devices.answer_refused code={} asked={}",
                refusal.error.code,
                refusal.asking.is_some()
            );
            if let Some(device) = refusal.asking {
                core.events.publish(Event::DeviceRequested { device });
            }
            refusal.error
        })
}

const ONLY_AXO_APP: Only = Only {
    caller: Caller::Signed(Signer::AxoApp),
    code: NOT_A_PERSON,
    message: "only the person at the Mac, in Axo.app, decides which devices answer",
};

fn failed(error: io::Error) -> axo_ipc::RpcError {
    log::warn!("event=devices.unsaved error={error}");
    axo_ipc::RpcError {
        code: axo_ipc::ErrorCode::InternalError,
        message: format!("the devices could not be saved: {error}"),
        data: None,
    }
}

/// `axo.device.list`, and `axo.device.decide` and `axo.device.revoke` for Axo.app alone.
pub(crate) struct DevicesExtension(pub(crate) Arc<Core>);

impl Extension for DevicesExtension {
    fn name(&self) -> &'static str {
        "devices"
    }

    fn register(&self, handler: &mut IoHandler) {
        let listing = Arc::clone(&self.0);
        handler.add_typed(
            method::DEVICE_LIST,
            "expected no parameters",
            move |_: NoParams| {
                let core = Arc::clone(&listing);
                async move {
                    let input_key = core
                        .input_keys
                        .get()
                        .await
                        .and_then(|key| axo_seal::fingerprint(&key.public_key()));
                    Ok(core.devices.list(input_key))
                }
            },
        );
        let deciding = Arc::clone(&self.0);
        handler.add_typed_only(
            ONLY_AXO_APP,
            method::DEVICE_DECIDE,
            "expected {key, allow}",
            move |choice: DecideDevice| {
                let core = Arc::clone(&deciding);
                async move {
                    let decided = core
                        .devices
                        .decide(&choice.key, choice.allow)
                        .map_err(failed)?;
                    if decided {
                        log::info!("event=devices.decided allowed={}", choice.allow);
                        core.events.publish(Event::DevicesChanged);
                    }
                    Ok(DeviceDecided { decided })
                }
            },
        );
        let revoking = Arc::clone(&self.0);
        handler.add_typed_only(
            ONLY_AXO_APP,
            method::DEVICE_REVOKE,
            "expected {key}",
            move |choice: RevokeDevice| {
                let core = Arc::clone(&revoking);
                async move {
                    let revoked = core.devices.revoke(&choice.key).map_err(failed)?;
                    if revoked {
                        log::info!("event=devices.revoked");
                        core.events.publish(Event::DevicesChanged);
                    }
                    Ok(DeviceRevoked { revoked })
                }
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A device as the tests sign with: a software P-256 key, as the phone's tests do.
    fn sign(secret: &p256::ecdsa::SigningKey, id: &str, answer: ElicitationAnswer) -> DeviceProof {
        // Randomized, as WebCrypto's and CryptoKit's signatures are: no two are the same.
        use p256::ecdsa::signature::RandomizedSigner as _;
        let signature: p256::ecdsa::Signature = secret.sign_with_rng(
            &mut p256::elliptic_curve::rand_core::OsRng,
            &axo_seal::answer_message(id, answer, None),
        );
        DeviceProof {
            key: axo_protocol::base64::encode(
                secret.verifying_key().to_encoded_point(false).as_bytes(),
            ),
            name: "Leo's iPhone".into(),
            signature: axo_protocol::base64::encode(&signature.to_bytes()),
        }
    }

    fn new_key() -> p256::ecdsa::SigningKey {
        p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng)
    }

    fn directory() -> PathBuf {
        let directory = crate::test_support::test_directory("axo-devices");
        fs::create_dir_all(&directory).unwrap();
        directory
    }

    use ElicitationAnswer::{Accept, Decline};

    #[test]
    fn a_key_the_answer_brings_with_it_proves_nothing() {
        // What the cloud could do before: make a key, sign Yes with it, and send both.
        let devices = AllowedDevices::open(directory().join(DEVICES_FILE)).unwrap();
        let forged = sign(&new_key(), "r1", Accept);
        let refusal = devices.check("r1", Accept, None, Some(&forged)).unwrap_err();
        assert_eq!(refusal.error.code, UNKNOWN_DEVICE);
        let asking = refusal.asking.expect("the person is asked about it");
        assert_eq!(asking.fingerprint, axo_seal::fingerprint(&forged.key).unwrap());
        assert_eq!(devices.list(None).waiting, vec![asking]);
    }

    #[test]
    fn only_an_allowed_device_answers_and_only_for_what_it_signed() {
        let path = directory().join(DEVICES_FILE);
        let devices = AllowedDevices::open(path.clone()).unwrap();
        let phone = new_key();
        let first = sign(&phone, "r1", Decline);
        assert!(devices.check("r1", Decline, None, Some(&first)).is_err());
        // A signature over another answer asks nothing.
        let flipped = sign(&phone, "r1", Decline);
        let other = devices.check("r1", Accept, None, Some(&flipped)).unwrap_err();
        assert_eq!(other.error.code, BAD_SIGNATURE);
        assert!(other.asking.is_none());
        // Unsigned: refused.
        assert_eq!(
            devices.check("r1", Decline, None, None).unwrap_err().error.code,
            BAD_SIGNATURE
        );

        assert!(devices.decide(&first.key, true).unwrap());
        // The answer refused before never counts; a new one does, for what it signed alone.
        assert!(devices.check("r1", Decline, None, Some(&first)).is_err());
        let again = sign(&phone, "r1", Decline);
        assert!(devices.check("r1", Decline, None, Some(&again)).is_ok());
        assert!(devices.check("r2", Decline, None, Some(&again)).is_err());
        assert!(devices.check("r1", Accept, None, Some(&again)).is_err());
        let sealed = Sealed {
            enc: "QQ==".into(),
            ciphertext: "Qg==".into(),
        };
        assert!(
            devices
                .check("r1", Decline, Some(&sealed), Some(&again))
                .is_err()
        );

        // Kept across restarts, until revoked.
        let reopened = AllowedDevices::open(path).unwrap();
        assert_eq!(reopened.list(None).allowed.len(), 1);
        assert!(reopened.revoke(&first.key).unwrap());
        let later = sign(&phone, "r3", Accept);
        assert_eq!(
            reopened
                .check("r3", Accept, None, Some(&later))
                .unwrap_err()
                .error
                .code,
            UNKNOWN_DEVICE
        );
    }

    #[test]
    fn a_device_turned_away_is_not_allowed_and_may_ask_again() {
        let devices = AllowedDevices::open(directory().join(DEVICES_FILE)).unwrap();
        let stranger = new_key();
        let first = sign(&stranger, "r1", Accept);
        assert!(devices.check("r1", Accept, None, Some(&first)).is_err());
        assert!(devices.decide(&first.key, false).unwrap());
        assert!(devices.list(None).allowed.is_empty());
        assert!(devices.list(None).waiting.is_empty());
        assert!(!devices.decide(&first.key, true).unwrap());
    }

    #[test]
    fn an_unreadable_file_fails_rather_than_forgetting_the_choices() {
        let path = directory().join(DEVICES_FILE);
        fs::write(&path, b"not json").unwrap();
        assert!(AllowedDevices::open(path).is_err());
    }
}
