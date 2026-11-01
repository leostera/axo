//! The loopback sign-in a host connection runs for an app (RFD0016): a service that only sends
//! a sign-in back to `http://localhost` (Kraken's public client) is signed into on the person's
//! Mac. axod opens the sign-in page in the browser, waits on the redirect port, and answers with
//! the code. The Worker built the URL and keeps the PKCE verifier, so the code is no use to anyone
//! who sees it; still, it is never logged.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const METHOD: &str = "axo.connections.signIn";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignInParams {
    /// The account that sent it; axod refuses a sign-in for any other.
    pub account_id: String,
    pub call_id: String,
    /// The service's sign-in page, https, with every parameter but `redirect_uri`.
    pub authorize_url: String,
    /// The redirect ports the service registered, tried in order.
    pub ports: Vec<u16>,
    pub path: String,
    pub state: String,
    pub timeout_ms: u64,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SignInResult {
    pub redirect_uri: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_description: Option<String>,
}

/// Checks a request: `Err` is a JSON-RPC error for the reply.
pub fn parse(params: &Value, account_id: &str) -> Result<SignInParams, (i64, String)> {
    let params: SignInParams = serde_json::from_value(params.clone())
        .map_err(|error| (-32602, format!("Invalid params: {error}")))?;
    if params.account_id != account_id {
        return Err((-32003, "this Mac belongs to another account".into()));
    }
    let invalid = |message: &str| Err((-32602, message.to_owned()));
    if !params.authorize_url.starts_with("https://") || params.authorize_url.len() > 8192 || params.authorize_url.contains(char::is_whitespace) {
        return invalid("authorizeUrl must be an https URL of at most 8192 bytes");
    }
    if params.ports.is_empty() || params.ports.len() > 8 || params.ports.iter().any(|&port| port < 1024) {
        return invalid("ports must be 1 to 8 ports from 1024");
    }
    let path_ok = params.path.starts_with('/')
        && params.path.len() <= 128
        && params.path.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.'));
    if !path_ok {
        return invalid("path must start with / and use letters, digits and - _ . /");
    }
    let state_ok = (16..=256).contains(&params.state.len())
        && params.state.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~'));
    if !state_ok {
        return invalid("state must be 16 to 256 URL-safe characters");
    }
    if !params.authorize_url.contains(&format!("state={}", params.state)) {
        return invalid("authorizeUrl must carry the state");
    }
    if params.timeout_ms == 0 || params.timeout_ms > axo_signin::MAX_TIMEOUT.as_millis() as u64 {
        return invalid("timeoutMs must be 1 to 600000");
    }
    Ok(params)
}

/// Runs the sign-in to its callback or its timeout.
pub fn run(params: &SignInParams, open_browser: impl FnOnce(&str) -> std::io::Result<()>) -> Result<SignInResult, (i64, String)> {
    let request = axo_signin::SignIn {
        authorize_url: params.authorize_url.clone(),
        ports: params.ports.clone(),
        path: params.path.clone(),
        state: params.state.clone(),
        timeout: Duration::from_millis(params.timeout_ms),
    };
    match axo_signin::sign_in(&request, open_browser) {
        Ok(callback) => Ok(SignInResult {
            redirect_uri: callback.redirect_uri,
            code: callback.code,
            error: callback.error,
            error_description: callback.error_description,
        }),
        Err(axo_signin::SignInError::TimedOut) => Err((-32008, "the sign-in was not finished in time".into())),
        Err(error) => Err((-32009, error.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn params(overrides: Value) -> Value {
        let mut value = json!({
            "accountId": "acct",
            "callId": "call",
            "authorizeUrl": "https://www.kraken.com/oauth/authorize?client_id=c&state=0123456789abcdef",
            "ports": [27461, 27462, 27463],
            "path": "/callback",
            "state": "0123456789abcdef",
            "timeoutMs": 300000,
        });
        for (key, v) in overrides.as_object().unwrap() {
            value[key] = v.clone();
        }
        value
    }

    #[test]
    fn a_sign_in_for_this_account_with_https_and_its_state_is_accepted() {
        let parsed = parse(&params(json!({})), "acct").unwrap();
        assert_eq!(parsed.ports, vec![27461, 27462, 27463]);
    }

    #[test]
    fn anything_else_is_refused() {
        let refused = |overrides: Value, account: &str| parse(&params(overrides), account).unwrap_err().1;
        assert!(refused(json!({}), "other").contains("another account"));
        assert!(refused(json!({"authorizeUrl": "http://www.kraken.com/?state=0123456789abcdef"}), "acct").contains("https"));
        assert!(refused(json!({"authorizeUrl": "https://www.kraken.com/oauth/authorize"}), "acct").contains("state"));
        assert!(refused(json!({"ports": [80]}), "acct").contains("ports"));
        assert!(refused(json!({"ports": []}), "acct").contains("ports"));
        assert!(refused(json!({"path": "callback"}), "acct").contains("path"));
        assert!(refused(json!({"state": "short"}), "acct").contains("state"));
        assert!(refused(json!({"timeoutMs": 600001}), "acct").contains("timeoutMs"));
        assert!(refused(json!({"command": "rm -rf /"}), "acct").contains("Invalid params"));
    }
}
