//! Whether an app call may run (RFD0070): the account asks the calling Mac before a tool that
//! sends, pays, deletes or reveals a secret. The host (axod) asks the person in the calling
//! Session; this module only checks the request.

use axo_protocol::SessionId;
use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::{INVALID_PARAMS, REFUSED};
use serde::Deserialize;

pub const METHOD: &str = "axo.apps.consent";
/// The question, as the account built it from the call; longer is refused, never cut.
pub const MAX_MESSAGE_CHARS: usize = 900;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConsentParams {
    /// The account that sent it; axod refuses a call for any other.
    pub account_id: String,
    pub call_id: String,
    /// The Session that made the call: where the person is asked.
    pub session_id: SessionId,
    /// What the call would do, built by the account from the call's input.
    pub message: String,
    /// How long the person has, the answer included.
    pub timeout_ms: u64,
}

/// Checks a request: `Err` is a JSON-RPC error for the reply.
pub fn parse(params: &serde_json::Value, account_id: &str) -> Result<ConsentParams, MethodError> {
    let params: ConsentParams =
        serde_json::from_value(params.clone()).map_err(MethodError::invalid_params)?;
    if params.account_id != account_id {
        return Err(MethodError::new(
            REFUSED,
            "this Mac belongs to another account",
        ));
    }
    let chars = params.message.chars().count();
    if chars == 0 || chars > MAX_MESSAGE_CHARS {
        return Err(MethodError::new(
            INVALID_PARAMS,
            format!("message must be 1 to {MAX_MESSAGE_CHARS} characters"),
        ));
    }
    Ok(params)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn request(message: &str, account: &str) -> serde_json::Value {
        json!({
            "accountId": account,
            "callId": "c1",
            "sessionId": "82cfd1e8-1cc6-4473-a16d-6f0e77476311",
            "message": message,
            "timeoutMs": 60_000,
        })
    }

    #[test]
    fn a_request_names_this_account_and_a_question_that_fits() {
        let parsed = parse(&request("Gmail (ada): Send an email", "a1"), "a1").unwrap();
        assert_eq!(parsed.message, "Gmail (ada): Send an email");
        assert_eq!(parse(&request("x", "a2"), "a1").unwrap_err().code, REFUSED);
        assert_eq!(parse(&request("", "a1"), "a1").unwrap_err().code, INVALID_PARAMS);
        let long = "x".repeat(MAX_MESSAGE_CHARS + 1);
        assert_eq!(parse(&request(&long, "a1"), "a1").unwrap_err().code, INVALID_PARAMS);
    }
}
