//! Account-authenticated local inference jobs. Model/runtime validation belongs to the host.

use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::{INVALID_PARAMS, REFUSED};
use serde::Deserialize;
use serde_json::Value;

pub const METHOD: &str = "axo.apps.ai";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AiParams {
    pub account_id: String,
    pub call_id: String,
    pub request: Value,
    pub timeout_ms: u64,
}

pub fn parse(value: &Value, account_id: &str) -> Result<AiParams, MethodError> {
    let params: AiParams =
        serde_json::from_value(value.clone()).map_err(MethodError::invalid_params)?;
    if params.account_id != account_id {
        return Err(MethodError::new(
            REFUSED,
            "this Mac belongs to another account",
        ));
    }
    if params.call_id.is_empty()
        || params.call_id.len() > 64
        || !(1..=240_000).contains(&params.timeout_ms)
        || !params.request.is_object()
        || serde_json::to_vec(&params.request).map_or(true, |bytes| bytes.len() > 65_536)
    {
        return Err(MethodError::new(INVALID_PARAMS, "invalid ai job"));
    }
    Ok(params)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_this_accounts_bounded_jobs_are_admitted() {
        let request =
            json!({"accountId":"a","callId":"call","request":{"op":"list"},"timeoutMs":1000});
        assert!(parse(&request, "a").is_ok());
        assert_eq!(parse(&request, "b").unwrap_err().code, REFUSED);
        for (key, value) in [
            ("timeoutMs", json!(0)),
            ("request", json!([])),
            ("approved", json!(true)),
        ] {
            let mut bad = request.clone();
            bad[key] = value;
            assert_eq!(parse(&bad, "a").unwrap_err().code, INVALID_PARAMS);
        }
    }
}
