//! The loopback sign-in a host connection runs for an app (RFD0016): a service that only sends
//! a sign-in back to `http://localhost` (Kraken's public client) is signed into on the person's
//! Mac. axod opens the sign-in page in the browser, waits on the redirect port, and answers with
//! the code. The Worker built the URL and keeps the PKCE verifier, so the code is no use to anyone
//! who sees it; still, it is never logged.

use std::time::Duration;

use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::{INVALID_PARAMS, REFUSED, TIMED_OUT};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const METHOD: &str = "axo.apps.signIn";

/// A sign-in as the Worker asks for it, before it is checked.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SignInParams {
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

/// A sign-in, checked: what this Mac runs.
#[derive(Debug)]
pub struct SignInRequest {
    /// The Worker's id for it, for the logs.
    pub call_id: String,
    pub sign_in: axo_signin::SignIn,
}

/// What the Worker reads back: the code, or the service's error.
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct SignInResult {
    pub redirect_uri: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_description: Option<String>,
}

/// The sign-in could not be taken: no port was free, or the redirect was not one it could read.
const SIGN_IN_FAILED: i64 = -32009;

impl From<axo_signin::Callback> for SignInResult {
    fn from(callback: axo_signin::Callback) -> Self {
        let (code, error, error_description) = match callback.outcome {
            axo_signin::Outcome::Code(code) => (Some(code), None, None),
            axo_signin::Outcome::Refused { error, description } => (None, error, description),
        };
        Self {
            redirect_uri: callback.redirect_uri,
            code,
            error,
            error_description,
        }
    }
}

/// Checks a request: `Err` is a JSON-RPC error for the reply.
pub fn parse(params: &Value, account_id: &str) -> Result<SignInRequest, MethodError> {
    let params: SignInParams =
        serde_json::from_value(params.clone()).map_err(MethodError::invalid_params)?;
    if params.account_id != account_id {
        return Err(MethodError::new(
            REFUSED,
            "this Mac belongs to another account",
        ));
    }
    let invalid = |message: &str| Err(MethodError::new(INVALID_PARAMS, message));
    if !params.authorize_url.starts_with("https://")
        || params.authorize_url.len() > 8192
        || params.authorize_url.contains(char::is_whitespace)
    {
        return invalid("authorizeUrl must be an https URL of at most 8192 bytes");
    }
    if params.ports.is_empty()
        || params.ports.len() > 8
        || params.ports.iter().any(|&port| port < 1024)
    {
        return invalid("ports must be 1 to 8 ports from 1024");
    }
    let path_ok = params.path.starts_with('/')
        && params.path.len() <= 128
        && params
            .path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.'));
    if !path_ok {
        return invalid("path must start with / and use letters, digits and - _ . /");
    }
    let state_ok = (16..=256).contains(&params.state.len())
        && params
            .state
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~'));
    if !state_ok {
        return invalid("state must be 16 to 256 URL-safe characters");
    }
    if !params
        .authorize_url
        .contains(&format!("state={}", params.state))
    {
        return invalid("authorizeUrl must carry the state");
    }
    if params.timeout_ms == 0 || params.timeout_ms > axo_signin::MAX_TIMEOUT.as_millis() as u64 {
        return invalid("timeoutMs must be 1 to 600000");
    }
    Ok(SignInRequest {
        call_id: params.call_id,
        sign_in: axo_signin::SignIn {
            authorize_url: params.authorize_url,
            ports: params.ports,
            path: params.path,
            state: params.state,
            timeout: Duration::from_millis(params.timeout_ms),
        },
    })
}

/// Runs the sign-in to its callback or its timeout; the reply's result is what the Worker reads.
pub async fn run<F: std::future::Future<Output = std::io::Result<()>>>(
    request: &SignInRequest,
    open_browser: impl FnOnce(String) -> F,
) -> Result<Value, MethodError> {
    match axo_signin::sign_in(&request.sign_in, open_browser).await {
        Ok(callback) => Ok(serde_json::to_value(SignInResult::from(callback))
            .expect("a sign-in result serializes")),
        Err(axo_signin::SignInError::TimedOut) => Err(MethodError::new(
            TIMED_OUT,
            "the sign-in was not finished in time",
        )),
        Err(error) => Err(MethodError::new(SIGN_IN_FAILED, error.to_string())),
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
        assert_eq!(parsed.call_id, "call");
        assert_eq!(parsed.sign_in.ports, vec![27461, 27462, 27463]);
        assert_eq!(parsed.sign_in.timeout, Duration::from_secs(300));
    }

    #[test]
    fn the_worker_reads_a_code_or_the_services_error() {
        let result = |outcome| {
            serde_json::to_value(SignInResult::from(axo_signin::Callback {
                redirect_uri: "http://localhost:27461/callback".into(),
                outcome,
            }))
            .unwrap()
        };
        assert_eq!(
            result(axo_signin::Outcome::Code("c0de".into())),
            json!({ "redirectUri": "http://localhost:27461/callback", "code": "c0de" })
        );
        assert_eq!(
            result(axo_signin::Outcome::Refused {
                error: Some("access_denied".into()),
                description: None
            }),
            json!({ "redirectUri": "http://localhost:27461/callback", "error": "access_denied" })
        );
    }

    #[test]
    fn anything_else_is_refused() {
        let refused = |overrides: Value, account: &str| {
            parse(&params(overrides), account).unwrap_err().message
        };
        assert!(refused(json!({}), "other").contains("another account"));
        assert!(
            refused(
                json!({"authorizeUrl": "http://www.kraken.com/?state=0123456789abcdef"}),
                "acct"
            )
            .contains("https")
        );
        assert!(
            refused(
                json!({"authorizeUrl": "https://www.kraken.com/oauth/authorize"}),
                "acct"
            )
            .contains("state")
        );
        assert!(refused(json!({"ports": [80]}), "acct").contains("ports"));
        assert!(refused(json!({"ports": []}), "acct").contains("ports"));
        assert!(refused(json!({"path": "callback"}), "acct").contains("path"));
        assert!(refused(json!({"state": "short"}), "acct").contains("state"));
        assert!(refused(json!({"timeoutMs": 600001}), "acct").contains("timeoutMs"));
        assert!(refused(json!({"command": "rm -rf /"}), "acct").contains("Invalid params"));
    }
}
