use super::*;
use proptest::prelude::*;

proptest! {
    #[test]
    fn arbitrary_bounded_utf8_never_panics_or_expands_request_batches(raw in ".{0,2048}") {
        match decode(&raw) {
            Ok(message) => {
                prop_assert!(!message.entries.is_empty());
                prop_assert!(message.entries.len() <= 8);
                for call in message.entries.into_iter().flatten() {
                    prop_assert!(call.method.encode_utf16().count() <= 128);
                    prop_assert!(!call.method.is_empty());
                }
            }
            Err(error) => {
                prop_assert!(matches!(error["error"]["code"].as_i64(), Some(-32700 | -32600)));
                prop_assert_eq!(&error["id"], &Value::Null);
            }
        }
    }
    #[test]
    fn ieee_numbers_round_trip_without_changing_hop_identity(value in any::<f64>().prop_filter("Finite JSON numbers", |v| v.is_finite())) {
        let raw = serde_json::to_string(&value).unwrap();
        let parsed: f64 = serde_json::from_str(&raw).unwrap();
        prop_assert_eq!(value.to_bits(), parsed.to_bits());
    }
    #[test]
    fn oversized_batch_results_keep_every_request_id(ids in prop::collection::vec("[a-z0-9]{1,128}", 1..=8)) {
        let replies: Vec<_> = ids.iter().map(|id| json!({"jsonrpc":"2.0","id":id,"result":"x".repeat(FRAME_BYTES)})).collect();
        let result = bounded_replies(true, replies).unwrap();
        let replies = result.as_array().unwrap();
        prop_assert_eq!(replies.len(), ids.len());
        prop_assert!(serde_json::to_vec(&result).unwrap().len() <= FRAME_BYTES);
        for (reply, id) in replies.iter().zip(ids) {
            prop_assert_eq!(&reply["id"], &json!(id));
            prop_assert_eq!(&reply["error"]["code"], &json!(-32004));
        }
    }
    #[test]
    fn encoded_byte_bound_is_not_a_character_limit(count in 16000usize..17000) {
        let raw = "😃".repeat(count);
        let code = decode(&raw).err().unwrap()["error"]["code"].as_i64().unwrap();
        prop_assert_eq!(code, if raw.len() > FRAME_BYTES { -32600 } else { -32700 });
    }
}

#[test]
fn integral_numeric_spelling_is_normalized_before_typed_read_admission() {
    for spelling in ["1", "1.0", "1e0", "0.1e1"] {
        let raw = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"read\",\"params\":{{\"limit\":{spelling}}}}}"
        );
        let call = decode(&raw).unwrap().entries.pop().unwrap().unwrap();
        assert_eq!(call.params.unwrap()["limit"].as_u64(), Some(1));
    }
}
