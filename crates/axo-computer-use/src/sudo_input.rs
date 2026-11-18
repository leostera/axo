//! Linux's explicit sudo intent uses existing person-only encrypted answers.
use super::*;
use axo_sudo::{Decision, Failure, Password, PasswordAnswer, PromptFuture, Prompter, Receipt};

struct Person<'a> {
    host: &'a dyn ComputerHost,
    session: SessionId,
}
impl Prompter for Person<'_> {
    fn confirm<'a>(
        &'a self,
        preview: &'a str,
        timeout: Duration,
    ) -> PromptFuture<'a, Result<Decision, Failure>> {
        Box::pin(async move {
            let answer = self
                .host
                .ask_with(self.session, preview, Asker::ComputerUse, None, timeout)
                .await
                .map_err(|_| Failure::QuestionUnavailable)?;
            Ok(match answer.outcome.action {
                ElicitationAction::Accept => Decision::Accept,
                ElicitationAction::Decline => Decision::Decline,
                ElicitationAction::Cancel => Decision::Cancel,
            })
        })
    }
    fn password<'a>(
        &'a self,
        preview: &'a str,
        timeout: Duration,
    ) -> PromptFuture<'a, Result<PasswordAnswer, Failure>> {
        Box::pin(async move {
            let key = self
                .host
                .input_key()
                .await
                .ok_or(Failure::Unavailable)?
                .public_key();
            let input = InputRequest {
                app: "sudo".into(),
                window: preview.into(),
                origin: None,
                fields: vec![InputField {
                    id: "f0".into(),
                    label: "Sudo password".into(),
                    kind: InputFieldKind::Password,
                }],
                submit: Some("Authenticate sudo".into()),
                key,
            };
            let answer = self
                .host
                .ask_with(
                    self.session,
                    preview,
                    Asker::ComputerUse,
                    Some(input),
                    timeout,
                )
                .await
                .map_err(|_| Failure::QuestionUnavailable)?;
            match answer.outcome.action {
                ElicitationAction::Decline => Ok(PasswordAnswer::Decline),
                ElicitationAction::Cancel => Ok(PasswordAnswer::Cancel),
                ElicitationAction::Accept => {
                    Ok(PasswordAnswer::Accept(parse_password(answer.values)?))
                }
            }
        })
    }
}

/// Convert already-opened person input into one bounded, zeroizing password.
fn parse_password(values: Option<Values>) -> Result<Password, Failure> {
    let mut values = values.ok_or(Failure::InvalidPassword)?;
    if values.len() != 1 {
        return Err(Failure::InvalidPassword);
    }
    Password::parse(values.remove("f0").ok_or(Failure::InvalidPassword)?)
}

pub(super) async fn request(
    host: &dyn ComputerHost,
    session: SessionId,
    args: Value,
    timeout: Duration,
) -> Value {
    let invocation = match axo_sudo::Invocation::parse(args) {
        Ok(invocation) => invocation,
        Err(_) => {
            return refused(
                "Linux sudo input takes { target: { kind: \"sudo\", argv: [\"/absolute/program\", ...] } }; no values, consent or answer may be supplied.",
            );
        }
    };
    let Some(context) = host.sudo_context(session) else {
        return refused(
            "Sudo input requires an open local Session and the installed askpass helper.",
        );
    };
    let receipt = axo_sudo::run(invocation, context, &Person { host, session }, timeout).await;
    let success = matches!(
        receipt,
        Receipt::Completed {
            exit_code: Some(0),
            ..
        }
    );
    log::info!(
        "event=input.sudo_completed outcome={}",
        if success { "ok" } else { "not_completed" }
    );
    let text = match &receipt {
        Receipt::Completed {
            input_delivered,
            exit_code,
        } => format!(
            "Sudo invocation finished; exit code {exit_code:?}, input handed to its helper: {input_delivered}. Password and command output are not returned."
        ),
        Receipt::Declined { may_have_run } => format!(
            "The person declined sudo input. Command may have run: {may_have_run}; do not retry automatically."
        ),
        Receipt::Cancelled { may_have_run } => format!(
            "Sudo input cancelled; no password was delivered. Command may have run: {may_have_run}; do not retry automatically."
        ),
        Receipt::Failed { may_have_run, .. } => format!(
            "Sudo input failed. Command may have run: {may_have_run}; do not retry automatically. No values are returned."
        ),
    };
    tool_result(
        text,
        serde_json::to_value(receipt).expect("receipt contains no secret values"),
        !success,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepted_input_must_be_exactly_the_requested_password_field() {
        let values = |items: &[(&str, &str)]| -> Option<Values> {
            Some(
                items
                    .iter()
                    .map(|(key, value)| (key.to_string(), value.to_string().into()))
                    .collect(),
            )
        };
        assert!(parse_password(values(&[("f0", "synthetic-only")])).is_ok());
        for input in [
            None,
            values(&[]),
            values(&[("other", "synthetic-only")]),
            values(&[("f0", "synthetic-only"), ("extra", "synthetic-only")]),
            values(&[("f0", "")]),
            values(&[("f0", "synthetic\nonly")]),
        ] {
            assert!(matches!(
                parse_password(input),
                Err(Failure::InvalidPassword)
            ));
        }
    }
}
