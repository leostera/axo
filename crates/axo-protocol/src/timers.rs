//! Runtime-only Session message scheduling; no persistence or human-origin delivery.
use crate::rpc::{InvalidParam, PromptDelivery, PromptText};
use crate::{SessionId, is_uuid};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Hash, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct TimerId(String);
impl TryFrom<String> for TimerId {
    type Error = InvalidParam;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if !is_uuid(&value) {
            return Err(InvalidParam("timerId must be a UUID"));
        }
        Ok(Self(value.to_ascii_lowercase()))
    }
}
impl From<TimerId> for String {
    fn from(value: TimerId) -> String {
        value.0
    }
}
impl std::fmt::Display for TimerId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

macro_rules! milliseconds {
    ($name:ident, $min:expr, $max:expr) => {
        #[derive(Clone, Copy, Debug, Deserialize, Serialize)]
        #[serde(try_from = "u64", into = "u64")]
        pub struct $name(u64);
        impl $name {
            pub fn get(self) -> u64 {
                self.0
            }
        }
        impl TryFrom<u64> for $name {
            type Error = InvalidParam;
            fn try_from(value: u64) -> Result<Self, Self::Error> {
                if !($min..=$max).contains(&value) {
                    return Err(InvalidParam(concat!(
                        stringify!($name),
                        " is outside its millisecond bounds"
                    )));
                }
                Ok(Self(value))
            }
        }
        impl From<$name> for u64 {
            fn from(value: $name) -> u64 {
                value.0
            }
        }
    };
}
milliseconds!(AfterMillis, 1, 2_592_000_000);
milliseconds!(IntervalMillis, 1000, 86_400_000);

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    content = "milliseconds",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Timing {
    After(AfterMillis),
    Interval(IntervalMillis),
}
impl Timing {
    pub fn milliseconds(self) -> u64 {
        match self {
            Self::After(v) => v.get(),
            Self::Interval(v) => v.get(),
        }
    }
    pub fn recurring(self) -> bool {
        matches!(self, Self::Interval(_))
    }
}
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Delivery {
    #[default]
    FollowUp,
    Steer,
    Turn,
}
impl From<Delivery> for PromptDelivery {
    fn from(value: Delivery) -> Self {
        match value {
            Delivery::FollowUp => Self::FollowUp,
            Delivery::Steer => Self::Steer,
            Delivery::Turn => Self::Turn,
        }
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateTimer {
    pub session_id: SessionId,
    pub from_session_id: SessionId,
    pub text: PromptText,
    #[serde(default)]
    pub delivery: Delivery,
    pub timing: Timing,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TimerOwner {
    pub from_session_id: SessionId,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CancelTimer {
    pub from_session_id: SessionId,
    pub timer_id: TimerId,
}
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TimerState {
    Waiting,
    Sending,
    Cancelling,
}
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TimerOutcome {
    Accepted,
    Refused,
    Uncertain,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimerInfo {
    pub timer_id: TimerId,
    pub session_id: SessionId,
    pub from_session_id: SessionId,
    pub timing: Timing,
    pub state: TimerState,
    pub fired: u64,
    pub last_outcome: Option<TimerOutcome>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimerCancelled {
    pub cancelled: bool,
    pub in_flight: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn durations_and_delivery_are_parsed_before_admission() {
        for value in [0, 2_592_000_001] {
            assert!(AfterMillis::try_from(value).is_err());
        }
        for value in [0, 999, 86_400_001] {
            assert!(IntervalMillis::try_from(value).is_err());
        }
        assert!(AfterMillis::try_from(1).is_ok());
        assert!(IntervalMillis::try_from(1000).is_ok());
        assert!(serde_json::from_value::<Delivery>(json!("interrupt")).is_err());
        assert!(
            serde_json::from_value::<Timing>(
                json!({"kind":"after","milliseconds":1,"intervalMs":4})
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<Timing>(json!({"kind":"after","milliseconds":1.5})).is_err()
        );
        assert!(serde_json::from_value::<TimerId>(json!("not-an-id")).is_err());
    }
}
