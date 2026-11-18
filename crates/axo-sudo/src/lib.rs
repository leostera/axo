//! A receipt-only sudo invocation. Passwords use sudo's askpass pipe, never a PTY.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    time::Duration,
};
use zeroize::Zeroizing;

const MAX_ARGUMENTS: usize = 32;
const MAX_PREVIEW: usize = 1000;
pub const MAX_PASSWORD_BYTES: usize = 255;
pub type PromptFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Accept,
    Decline,
    Cancel,
}

// Deliberately neither Debug, Display nor Serialize.
pub struct Password(Zeroizing<String>);
impl Password {
    pub fn parse(value: Zeroizing<String>) -> Result<Self, Failure> {
        if value.is_empty()
            || value.len() > MAX_PASSWORD_BYTES
            || value.bytes().any(|b| matches!(b, 0 | b'\n' | b'\r'))
        {
            return Err(Failure::InvalidPassword);
        }
        Ok(Self(value))
    }
}
pub enum PasswordAnswer {
    Accept(Password),
    Decline,
    Cancel,
}
pub trait Prompter: Send + Sync {
    fn confirm<'a>(
        &'a self,
        preview: &'a str,
        timeout: Duration,
    ) -> PromptFuture<'a, Result<Decision, Failure>>;
    fn password<'a>(
        &'a self,
        preview: &'a str,
        timeout: Duration,
    ) -> PromptFuture<'a, Result<PasswordAnswer, Failure>>;
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    InvalidTarget,
    InvalidPassword,
    Unavailable,
    Busy,
    QuestionUnavailable,
    TargetGone,
    ForeignHelper,
    ChannelClosed,
    TimedOut,
}
#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Receipt {
    Declined {
        may_have_run: bool,
    },
    Cancelled {
        may_have_run: bool,
    },
    Failed {
        reason: Failure,
        may_have_run: bool,
    },
    Completed {
        /// Handoff to the bound helper, not a claim that PAM accepted it.
        input_delivered: bool,
        exit_code: Option<i32>,
    },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRequest {
    target: RawTarget,
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum RawTarget {
    Sudo { argv: Vec<String> },
}

/// Parsed command intent; no password, answer or authorization can be supplied.
pub struct Invocation {
    argv: Vec<String>,
}
impl Invocation {
    pub fn parse(value: Value) -> Result<Self, Failure> {
        let RawRequest {
            target: RawTarget::Sudo { argv },
        } = serde_json::from_value(value).map_err(|_| Failure::InvalidTarget)?;
        if argv.is_empty()
            || argv.len() > MAX_ARGUMENTS
            || !Path::new(&argv[0]).is_absolute()
            || argv.iter().any(|arg| arg.contains('\0'))
            || serde_json::to_string(&argv)
                .map_err(|_| Failure::InvalidTarget)?
                .len()
                > MAX_PREVIEW / 2
        {
            return Err(Failure::InvalidTarget);
        }
        Ok(Self { argv })
    }
    fn preview(&self, directory: &Path) -> Result<String, Failure> {
        let argv = serde_json::to_string(&self.argv).map_err(|_| Failure::InvalidTarget)?;
        let directory = serde_json::to_string(directory.to_str().ok_or(Failure::InvalidTarget)?)
            .map_err(|_| Failure::InvalidTarget)?;
        let preview = format!(
            "Run with sudo: {argv}\nWorking directory: {directory}\nCommand output is discarded; only an exit receipt is returned."
        );
        if preview.chars().count() > MAX_PREVIEW {
            return Err(Failure::InvalidTarget);
        }
        Ok(preview)
    }
}

pub struct Context {
    directory: PathBuf,
    helper: PathBuf,
}
impl Context {
    pub fn new(directory: PathBuf, helper: PathBuf) -> Result<Self, Failure> {
        if !directory.is_absolute() || !helper.is_absolute() {
            return Err(Failure::InvalidTarget);
        }
        Ok(Self { directory, helper })
    }
}

mod linux;

pub async fn run(
    invocation: Invocation,
    context: Context,
    prompter: &dyn Prompter,
    timeout: Duration,
) -> Receipt {
    linux::run(invocation, context, prompter, timeout).await
}

/// Only the dedicated askpass executable calls this. No secret is printed on failure.
pub fn askpass() -> bool {
    linux::askpass().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn only_explicit_bounded_command_intents_parse() {
        assert!(
            Invocation::parse(json!({"target":{"kind":"sudo","argv":["/usr/bin/true"]}})).is_ok()
        );
        for value in [
            json!({}),
            json!({"target":{"kind":"sudo","argv":[]}}),
            json!({"target":{"kind":"sudo","argv":["relative"]}}),
            json!({"target":{"kind":"sudo","argv":["/bin/true"],"password":"not accepted"}}),
            json!({"target":{"kind":"sudo","argv":["/bin/true"]},"approval":"yes"}),
            json!({"target":{"kind":"sudo","argv":["/bin/true","x".repeat(1001)]}}),
        ] {
            assert!(Invocation::parse(value).is_err());
        }
    }
    #[test]
    fn password_framing_is_one_nonempty_line() {
        for value in ["", "a\nb", "a\rb", "a\0b"] {
            assert!(Password::parse(Zeroizing::new(value.into())).is_err());
        }
        assert!(Password::parse(Zeroizing::new("synthetic fixture password".into())).is_ok());
        assert!(Password::parse(Zeroizing::new("x".repeat(MAX_PASSWORD_BYTES + 1))).is_err());
    }
}
