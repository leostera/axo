//! Device-signed answers (RFD0029, every remote answer is signed): a phone or a browser signs
//! each answer with its own key, over that request's id, the action and the sealed values. axod
//! takes an answer only with a good signature for it, so a relay bug cannot replay an answer onto
//! another question, turn a No into a Yes, or swap sealed values. Which devices answer is the
//! account's to say: any device signed in to it may (the person trusts their account, which
//! Cloudflare Access guards).

use axo_protocol::elicitation::{BAD_SIGNATURE, DeviceProof, ElicitationAnswer, Sealed};
use axo_protocol::rpc::MethodError;

/// A remote answer counts only with its device's signature over that answer.
pub(crate) fn check_answer(
    id: &str,
    answer: ElicitationAnswer,
    sealed: Option<&Sealed>,
    device: Option<&DeviceProof>,
) -> Result<(), MethodError> {
    let Some(proof) = device else {
        return Err(MethodError::new(
            BAD_SIGNATURE,
            "Answers must be signed by your device: update Axo there.",
        ));
    };
    let signed = axo_seal::answer_message(id, answer, sealed);
    if axo_seal::verify_answer(&proof.key, &proof.signature, &signed) {
        return Ok(());
    }
    log::warn!("event=devices.answer_refused reason=signature");
    Err(MethodError::new(
        BAD_SIGNATURE,
        "The answer's signature is not for this answer.",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sign(secret: &p256::ecdsa::SigningKey, id: &str, answer: ElicitationAnswer) -> DeviceProof {
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

    #[test]
    fn an_answer_counts_only_with_its_own_signature() {
        let phone = p256::ecdsa::SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let no = sign(&phone, "r1", ElicitationAnswer::Decline);
        assert!(check_answer("r1", ElicitationAnswer::Decline, None, Some(&no)).is_ok());
        // Replayed onto another question, or turned into a Yes: refused.
        assert_eq!(
            check_answer("r2", ElicitationAnswer::Decline, None, Some(&no))
                .unwrap_err()
                .code,
            BAD_SIGNATURE
        );
        assert!(check_answer("r1", ElicitationAnswer::Accept, None, Some(&no)).is_err());
        // Sealed values swapped under the signature: refused.
        let sealed = Sealed {
            enc: "QQ==".into(),
            ciphertext: "Qg==".into(),
        };
        assert!(check_answer("r1", ElicitationAnswer::Decline, Some(&sealed), Some(&no)).is_err());
        // Unsigned: refused.
        assert!(check_answer("r1", ElicitationAnswer::Decline, None, None).is_err());
    }
}
