//! What the person types for an input request reaches this Mac sealed (RFD0029, the side channel
//! for input): the phone or the browser encrypts it to this Mac's input key with HPKE (RFC 9180,
//! base mode), so the relay, the agent and the transcript only ever carry ciphertext.
//!
//! The suite is DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM: the one CryptoKit,
//! WebCrypto (through `@hpke/core`) and this crate all have. Public keys travel as base64 of the
//! uncompressed SEC1 point (65 bytes); `enc` likewise.

use hpke::aead::AesGcm256;
use hpke::kdf::HkdfSha256;
use hpke::kem::DhP256HkdfSha256;
use hpke::{Deserializable, Kem as _, OpModeR, Serializable};
use rand_core::TryRngCore as _;
use zeroize::Zeroizing;

type Kem = DhP256HkdfSha256;
type PrivateKey = <Kem as hpke::Kem>::PrivateKey;
type PublicKey = <Kem as hpke::Kem>::PublicKey;
type EncappedKey = <Kem as hpke::Kem>::EncappedKey;

/// Shared with `@axo/protocol`'s `INPUT_SEAL.info`, and the phone's and the Mac app's.
pub const INFO: &[u8] = b"axo-ask-input/v1";

/// What a sealed answer is bound to: its request, and the address the person was shown. A
/// ciphertext for another request or another address does not open.
pub fn aad(request_id: &str, origin: Option<&str>) -> Vec<u8> {
    format!("{request_id}\n{}", origin.unwrap_or("")).into_bytes()
}

/// This Mac's input key.
pub struct InputKey {
    private: PrivateKey,
    public: PublicKey,
}

/// Why a sealed answer did not open.
#[derive(Debug, PartialEq, Eq)]
pub enum OpenError {
    /// `enc` or the ciphertext is not base64 of the right shape.
    Malformed,
    /// Sealed to another key, for another request or address, or altered on the way.
    Refused,
}

impl InputKey {
    /// A new key from the OS's random numbers.
    pub fn generate() -> Self {
        let (private, public) = Kem::gen_keypair(&mut rand_core::OsRng.unwrap_err());
        Self { private, public }
    }

    /// The key stored as `to_secret_bytes`.
    pub fn from_secret_bytes(bytes: &[u8]) -> Option<Self> {
        let private = PrivateKey::from_bytes(bytes).ok()?;
        let public = Kem::sk_to_pk(&private);
        Some(Self { private, public })
    }

    pub fn to_secret_bytes(&self) -> Zeroizing<Vec<u8>> {
        Zeroizing::new(self.private.to_bytes().to_vec())
    }

    /// Base64 of the uncompressed SEC1 public key, as clients pin it.
    pub fn public_key(&self) -> String {
        axo_protocol::base64::encode(&self.public.to_bytes())
    }

    /// Opens what a client sealed to this key for `aad`.
    pub fn open(
        &self,
        enc: &str,
        ciphertext: &str,
        aad: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, OpenError> {
        let enc = axo_protocol::base64::decode(enc).map_err(|_| OpenError::Malformed)?;
        let ciphertext =
            axo_protocol::base64::decode(ciphertext).map_err(|_| OpenError::Malformed)?;
        let enc = EncappedKey::from_bytes(&enc).map_err(|_| OpenError::Malformed)?;
        hpke::single_shot_open::<AesGcm256, HkdfSha256, Kem>(
            &OpModeR::Base,
            &self.private,
            &enc,
            INFO,
            &ciphertext,
            aad,
        )
        .map(Zeroizing::new)
        .map_err(|_| OpenError::Refused)
    }
}

/// Seals `plaintext` to `public_key` (base64 SEC1) as a client does: `(enc, ciphertext)` in
/// base64. axod itself never seals; this is the reference the clients' tests are held to.
pub fn seal(public_key: &str, plaintext: &[u8], aad: &[u8]) -> Option<(String, String)> {
    let public = PublicKey::from_bytes(&axo_protocol::base64::decode(public_key).ok()?).ok()?;
    let (enc, ciphertext) = hpke::single_shot_seal::<AesGcm256, HkdfSha256, Kem, _>(
        &hpke::OpModeS::Base,
        &public,
        INFO,
        plaintext,
        aad,
        &mut rand_core::OsRng.unwrap_err(),
    )
    .ok()?;
    Some((
        axo_protocol::base64::encode(&enc.to_bytes()),
        axo_protocol::base64::encode(&ciphertext),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sealed_answer_opens_only_for_its_request_and_address() {
        let key = InputKey::generate();
        let bound = aad("req-1", Some("https://github.com"));
        let (enc, ciphertext) = seal(&key.public_key(), b"hunter2", &bound).unwrap();
        assert_eq!(&**key.open(&enc, &ciphertext, &bound).unwrap(), b"hunter2");
        assert_eq!(
            key.open(&enc, &ciphertext, &aad("req-2", Some("https://github.com"))),
            Err(OpenError::Refused)
        );
        assert_eq!(
            key.open(&enc, &ciphertext, &aad("req-1", Some("https://github.co"))),
            Err(OpenError::Refused)
        );
        assert_eq!(
            InputKey::generate().open(&enc, &ciphertext, &bound),
            Err(OpenError::Refused)
        );
        assert_eq!(
            key.open("!!", &ciphertext, &bound),
            Err(OpenError::Malformed)
        );
    }

    /// What the browser and CryptoKit sealed opens here: the three implementations agree.
    #[test]
    fn the_browser_s_and_cryptokit_s_sealed_values_open_here() {
        let vectors: serde_json::Value =
            serde_json::from_str(include_str!("../testdata/vectors.json")).unwrap();
        let secret = axo_protocol::base64::decode(vectors["secretKey"].as_str().unwrap()).unwrap();
        let key = InputKey::from_secret_bytes(&secret).unwrap();
        assert_eq!(key.public_key(), vectors["publicKey"].as_str().unwrap());
        let cases = vectors["cases"].as_array().unwrap();
        let from: Vec<&str> = cases
            .iter()
            .map(|case| case["from"].as_str().unwrap())
            .collect();
        assert_eq!(from, ["webcrypto", "cryptokit"]);
        for case in cases {
            let bound = aad(case["requestId"].as_str().unwrap(), case["origin"].as_str());
            let opened = key
                .open(
                    case["enc"].as_str().unwrap(),
                    case["ciphertext"].as_str().unwrap(),
                    &bound,
                )
                .unwrap_or_else(|error| panic!("{}: {error:?}", case["from"]));
            assert_eq!(
                std::str::from_utf8(&opened).unwrap(),
                case["plaintext"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn the_key_survives_being_stored() {
        let key = InputKey::generate();
        let again = InputKey::from_secret_bytes(&key.to_secret_bytes()).unwrap();
        assert_eq!(again.public_key(), key.public_key());
        assert_eq!(
            axo_protocol::base64::decode(&key.public_key())
                .unwrap()
                .len(),
            65
        );
    }
}
