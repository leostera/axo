//! Elicitations on the relay (RFD0029): the method names, and taking a person's answer from the
//! cloud to the host.

use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::{INVALID_PARAMS, STALE_HOST};
use serde::Deserialize;
use serde_json::Value;

use super::session::RelaySessionContext;
use crate::host::RemoteAnswer;

/// Elicitations on the relay (RFD0029): axod tells the cloud what it asks and how each ended, and
/// the cloud brings a person's answer, which it takes only from a signed-in person's client.
pub(super) const ELICITATION_REQUESTED: &str = "axo.elicitation.requested";
pub(super) const ELICITATION_RESOLVED: &str = "axo.elicitation.resolved";
pub(super) const ELICITATION_RESOLVE: &str = "axo.elicitation.resolve";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ResolveElicitation {
    target: RemoteTarget,
    elicitation_id: String,
    action: axo_protocol::elicitation::ElicitationAnswer,
    #[serde(default)]
    sealed: Option<axo_protocol::elicitation::Sealed>,
    #[serde(default)]
    device: Option<axo_protocol::elicitation::DeviceProof>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemoteTarget {
    host_id: String,
    host_generation: String,
}

pub(super) fn resolve_elicitation(
    params: &Value,
    context: &RelaySessionContext,
) -> Result<(), MethodError> {
    let request = serde_json::from_value::<ResolveElicitation>(params.clone())
        .map_err(|_| MethodError::new(INVALID_PARAMS, "Invalid params"))?;
    if request.target.host_id != context.identity.host_id
        || request.target.host_generation != context.identity.host_generation
    {
        return Err(MethodError::new(STALE_HOST, "Stale host"));
    }
    context.sessions.resolve_elicitation(RemoteAnswer {
        elicitation_id: request.elicitation_id,
        answer: request.action,
        sealed: request.sealed,
        device: request.device,
    })
}
