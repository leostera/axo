//! What the relay needs from the daemon that hosts it.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::time::Duration;

use axo_protocol::elicitation::{DeviceProof, Elicitation, ElicitationAnswer, Sealed};
use axo_protocol::rpc::MethodError;
use axo_protocol::{Event, RelayStatus};

/// A key a remote person presses in a Session's Pi: what answering it on the Mac would take.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PiKey {
    /// Stops the reply in progress, or declines the question Pi is asking.
    Escape,
    /// Accepts the question Pi is asking.
    Enter,
}

/// When a remote person's prompt reaches a working Pi (RFD0033): once the run ends, within it,
/// or at once, stopping it.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClientDelivery {
    #[default]
    FollowUp,
    Steer,
    Interrupt,
}

/// A model a remote person picks for a Session, as Pi's registry names it (RFD0033).
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelChoice {
    pub provider: ModelName,
    pub id: ModelName,
}

/// A provider or model id: 1 to 128 characters, no control characters.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(try_from = "String")]
pub struct ModelName(String);

impl ModelName {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for ModelName {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if (1..=128).contains(&value.chars().count()) && !value.chars().any(char::is_control) {
            Ok(Self(value))
        } else {
            Err("a model name has 1 to 128 characters")
        }
    }
}

/// A future a host hands the relay: it waits without holding a thread.
pub type HostFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Who this Mac is to the account: its stable id, and this run's generation, which changes every
/// time axod starts so the cloud can drop what an earlier run left.
#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostIdentity {
    pub host_id: String,
    pub host_generation: String,
}

/// A person's answer to one of this Mac's questions, as the cloud brings it (RFD0029): an input
/// request's values sealed to this Mac, and the answering device's signature over it all.
#[derive(Clone, Debug)]
pub struct RemoteAnswer {
    pub elicitation_id: String,
    pub answer: ElicitationAnswer,
    pub sealed: Option<Sealed>,
    pub device: Option<DeviceProof>,
}

/// The daemon's sessions, as seen by the cloud relay. Implemented by axod.
///
/// Identifiers arrive already parsed; implementations still check that they name open sessions
/// and panes, because remote callers are untrusted. What waits returns a [`HostFuture`].
pub trait RelayHost: Send + Sync {
    fn identity(&self) -> &HostIdentity;
    fn publish_relay_status(&self, status: &RelayStatus);

    /// Subscribes to local events (including terminal output); returns the subscription ID.
    fn subscribe_remote_events(&self) -> io::Result<String>;
    /// The next local events, waiting up to `timeout`; none if it ran out. Dropping the wait
    /// loses nothing.
    fn next_remote_events<'a>(
        &'a self,
        subscription_id: &'a str,
        timeout: Duration,
    ) -> HostFuture<'a, io::Result<Vec<Event>>>;
    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()>;

    /// What agents here are asking the person now (RFD0029), sent again on every connection.
    fn pending_elicitations(&self) -> Vec<Elicitation> {
        Vec::new()
    }
    /// Takes a person's answer from the cloud; refused when it no longer waits, or its values
    /// or signature are no good.
    fn resolve_elicitation(&self, _answer: RemoteAnswer) -> Result<(), MethodError> {
        Err(MethodError::new(
            axo_protocol::elicitation::NOT_PENDING,
            "Already answered, or no longer asked",
        ))
    }

    /// One computer-use tool from another Mac's script (RFD0028): the gate, the person's answer
    /// in the calling Session if it must ask, then the tool's MCP answer with its images inline.
    /// `Err` is refused, declined, or not answered.
    fn remote_computer(
        &self,
        _request: crate::computer::ComputerParams,
    ) -> HostFuture<'_, Result<serde_json::Value, MethodError>> {
        Box::pin(std::future::ready(Err(MethodError::method_not_found())))
    }
    /// Local model inference from an account script. The host owns model/runtime policy.
    fn remote_ai(
        &self,
        _request: crate::ai::AiParams,
    ) -> HostFuture<'_, Result<serde_json::Value, MethodError>> {
        Box::pin(std::future::ready(Err(MethodError::method_not_found())))
    }

    /// Whether this Mac can do computer use now: `{ available, accessibility, screenRecording, locked }`.
    fn computer_status(&self) -> HostFuture<'_, serde_json::Value> {
        Box::pin(std::future::ready(serde_json::json!({
            "available": false,
            "accessibility": false,
            "screenRecording": false,
        })))
    }
    /// Where the account's assets are reached from while the relay is connected, so local
    /// callers (`axod mcp`) can fetch them; `None` once it disconnects.
    fn set_asset_source(&self, _source: Option<crate::assets::AssetSource>) {}

    /// Answers one of the account's calls (`axo.remote.*`), a whole JSON-RPC request, as the
    /// account would be answered: the response to send back, or `None` for a notification.
    /// The relay only carries it; what the methods do is the host's.
    fn answer_remote(
        &self,
        request: serde_json::Value,
    ) -> HostFuture<'_, Option<serde_json::Value>>;
}
