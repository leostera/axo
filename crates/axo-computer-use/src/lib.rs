//! The computer-use extension (RFD0028, RFD0029, RFD0034): what axod itself does around the
//! computer tools. Input requests, the gate's questions, other Macs' calls, and hiding what the
//! person filled in.
//!
//! Input requests (RFD0029, the side channel for input): the computer tool `request_input` asks
//! the person for values the agent must not see, such as a password, and axod fills them into the
//! window itself. The agent gets a receipt; the values never reach `axod mcp`, the agent, the
//! transcript or the cloud in the clear.
//!
//! 1. axod reads the window's form itself (`axo_computer::form`): the app, the page's address
//!    and the fields. The agent only says which fields it wants, by label or by what they are for.
//! 2. It asks in the calling Session, as Axo, with that reading and this Mac's input key. The
//!    phone or the browser seals the values to the key; Axo.app on this Mac sends them locally.
//! 3. On the answer it checks the page is unchanged (same address, same elements), fills, presses
//!    the submit button if asked, and remembers a salted hash of each value, so every later read
//!    of any window shows `•••• (filled by you)` instead.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use axo_computer::form::{FieldKind, Form, pick_field};
use axo_ipc::peer::Signer;
use axo_ipc::{Only, TypedMethods};
use axo_protocol::SessionId;
use axo_protocol::elicitation::{
    Asker, ElicitationAction, InputField, InputFieldKind, InputRequest, MAX_INPUT_FIELDS,
    MAX_MESSAGE_CHARS, TIMEOUT_MS,
};
use axo_protocol::rpc::method::{COMPUTER_INPUT, COMPUTER_REDACTIONS};
use axo_relay::computer::ComputerParams;
use jsonrpc_core::IoHandler;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use axo_ipc::Extension;
use axo_protocol::elicitation::ElicitationOutcome;
use axo_questions::Values;
use jsonrpc_core::Error as RpcError;

/// Where this Mac's input key is kept, beside the host credential, under a fixed id.
/// Values remembered for redaction at most; the oldest go first.
const MAX_REDACTIONS: usize = 256;
/// Shorter values are too common to hide wherever they appear.
const SHORTEST_REDACTED: usize = 4;

/// Salted hashes of the values the person filled in.
struct Redactions {
    salt: [u8; 16],
    hashes: Mutex<Vec<[u8; 32]>>,
}

impl Default for Redactions {
    fn default() -> Self {
        let mut salt = [0; 16];
        let random = axo_protocol::new_uuid_v4()
            .unwrap_or_default()
            .replace('-', "");
        for (index, byte) in salt.iter_mut().enumerate() {
            *byte = u8::from_str_radix(random.get(index * 2..index * 2 + 2).unwrap_or("00"), 16)
                .unwrap_or(0);
        }
        Self {
            salt,
            hashes: Mutex::new(Vec::new()),
        }
    }
}

impl Redactions {
    fn remember(&self, value: &str) {
        if value.chars().count() < SHORTEST_REDACTED {
            return;
        }
        let hash = hash(&self.salt, value);
        if let Ok(mut hashes) = self.hashes.lock() {
            if !hashes.contains(&hash) {
                if hashes.len() >= MAX_REDACTIONS {
                    hashes.remove(0);
                }
                hashes.push(hash);
            }
        }
    }

    /// Hides every remembered value in a computer tool's result.
    fn apply(&self, result: &mut Value) {
        let Ok(hashes) = self.hashes.lock() else {
            return;
        };
        if !hashes.is_empty() {
            axo_computer::redact(result, &|candidate| {
                hashes.contains(&hash(&self.salt, candidate))
            });
        }
    }

    fn export(&self) -> Value {
        let hashes = self
            .hashes
            .lock()
            .map(|hashes| hashes.clone())
            .unwrap_or_default();
        json!({
            "salt": hex(&self.salt),
            "hashes": hashes.iter().map(|hash| hex(hash)).collect::<Vec<_>>(),
        })
    }
}

fn hash(salt: &[u8], value: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(salt);
    hasher.update(value.as_bytes());
    hasher.finalize().into()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `request_input`'s arguments, from the agent.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputArgs {
    pid: i32,
    window_id: u32,
    fields: Vec<WantedField>,
    /// The label of the button to press once filled, such as "Sign in".
    #[serde(default)]
    submit: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WantedField {
    kind: String,
    #[serde(default)]
    label: Option<String>,
}

fn protocol_kind(kind: FieldKind) -> InputFieldKind {
    match kind {
        FieldKind::Username => InputFieldKind::Username,
        FieldKind::Email => InputFieldKind::Email,
        FieldKind::Password => InputFieldKind::Password,
        FieldKind::Code => InputFieldKind::Code,
        FieldKind::Text => InputFieldKind::Text,
    }
}

fn tool_result(text: String, structured: Value, is_error: bool) -> Value {
    json!({ "content": [{ "type": "text", "text": text }], "structuredContent": structured, "isError": is_error })
}

fn refused(text: impl Into<String>) -> Value {
    let text = text.into();
    tool_result(
        text.clone(),
        json!({ "filled": false, "reason": text }),
        true,
    )
}

/// "Email and Password", "A, B and C".
fn listed(labels: &[String]) -> String {
    match labels {
        [] => String::new(),
        [one] => one.clone(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// What computer use needs of the rest of axod.
pub trait ComputerHost: Send + Sync {
    /// Asks the person in `session_id` and waits, for a form when `input` is given.
    fn ask_with(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<(ElicitationOutcome, Option<Values>), RpcError>;
    /// This Mac's input key, which forms are sealed to.
    fn input_key(&self) -> Option<&axo_seal::InputKey>;
    /// axod's socket, where the gate's state lives (`axo_computer::gate`).
    fn agent_socket(&self) -> Option<std::path::PathBuf>;
}

/// What computer use keeps: the values the person filled in, hidden from every later read.
#[derive(Default)]
pub struct ComputerUse {
    redactions: Redactions,
}

impl ComputerUse {
    /// Hides values the person filled in from a computer tool's result.
    pub fn redact(&self, result: &mut Value) {
        self.redactions.apply(result);
    }

    /// `request_input`, for an agent's Session here or another Mac's script (`from` names its
    /// Mac). Answers like a computer tool: a receipt, or an error saying why nothing was filled.
    pub fn request_input(
        &self,
        host: &dyn ComputerHost,
        session_id: SessionId,
        from: Option<&str>,
        args: Value,
        timeout: Duration,
    ) -> Value {
        let args: InputArgs = match serde_json::from_value(args) {
            Ok(args) => args,
            Err(error) => {
                return refused(format!(
                    "request_input takes {{ pid, window_id, fields: [{{ kind, label? }}], submit? }}: {error}"
                ));
            }
        };
        if args.fields.is_empty() || args.fields.len() > MAX_INPUT_FIELDS {
            return refused(format!("ask for 1 to {MAX_INPUT_FIELDS} fields"));
        }
        let Some(key) = host.input_key() else {
            return refused("this Mac could not make or read its input key");
        };
        let form = match Form::read(args.pid, args.window_id) {
            Ok(form) => form,
            Err(error) => return refused(error.0),
        };
        let mut picked = Vec::new();
        for wanted in &args.fields {
            let Some(kind) = FieldKind::parse(&wanted.kind) else {
                return refused(format!(
                    "{} is not a field kind: use username, email, password, code or text",
                    wanted.kind
                ));
            };
            match pick_field(&form.fields, wanted.label.as_deref(), kind) {
                Ok(index) if picked.iter().any(|&(other, _)| other == index) => {
                    return refused(format!(
                        "two fields asked for \"{}\"",
                        form.fields[index].label
                    ));
                }
                Ok(index) => picked.push((index, kind)),
                Err(error) => return refused(error.0),
            }
        }
        let submit = match &args.submit {
            None => None,
            Some(label) => {
                let wanted = label.trim().to_lowercase();
                match form
                    .buttons
                    .iter()
                    .position(|button| button.trim().to_lowercase() == wanted)
                {
                    Some(index) => Some(index),
                    None => {
                        return refused(format!(
                            "no button \"{label}\"; the window's buttons are {}",
                            form.buttons
                                .iter()
                                .map(|b| format!("\"{b}\""))
                                .collect::<Vec<_>>()
                                .join(", ")
                        ));
                    }
                }
            }
        };
        let labels: Vec<String> = picked
            .iter()
            .map(|&(index, kind)| match form.fields[index].label.trim() {
                "" => title_case(kind.as_str()),
                label => label.to_owned(),
            })
            .collect();
        let place = match &form.origin {
            Some(origin) => format!("{} — {origin}", form.app),
            None => format!("{} — {}", form.app, form.window_title),
        };
        let mut message = format!("Fill {} in {place}", listed(&labels));
        if let Some(index) = submit {
            message.push_str(&format!(
                ", then press \u{201c}{}\u{201d}",
                form.buttons[index]
            ));
        }
        message.push('.');
        if let Some(from) = from {
            message.push_str(&format!("\nAsked from {from}'s Session."));
        }
        let message: String = message.chars().take(MAX_MESSAGE_CHARS).collect();
        let input = InputRequest {
            app: form.app.clone(),
            window: form.window_title.clone(),
            origin: form.origin.clone(),
            fields: picked
                .iter()
                .zip(&labels)
                .enumerate()
                .map(|(position, (&(_, kind), label))| InputField {
                    id: format!("f{position}"),
                    label: label.clone(),
                    kind: protocol_kind(kind),
                })
                .collect(),
            submit: submit.map(|index| form.buttons[index].clone()),
            key: key.public_key(),
        };
        let timeout = timeout.min(Duration::from_millis(TIMEOUT_MS));
        let (outcome, values) = match host.ask_with(
            session_id,
            &message,
            Asker::ComputerUse,
            Some(input),
            timeout,
        ) {
            Ok(answer) => answer,
            Err(error) => {
                return refused(format!(
                    "Not done: the person could not be asked ({}).",
                    error.message
                ));
            }
        };
        let values = match (outcome.action, values) {
            (ElicitationAction::Accept, Some(values)) => values,
            (ElicitationAction::Decline, _) => return refused("Not done: the person declined."),
            _ => return refused("Not done: nobody answered in time."),
        };
        let receipt = self.fill(&form, &picked, &labels, submit, &values, &place);
        log::info!(
            "event=input.filled fields={} submitted={} outcome={}",
            picked.len(),
            submit.is_some(),
            if receipt["isError"] == json!(true) {
                "error"
            } else {
                "ok"
            }
        );
        receipt
    }

    fn fill(
        &self,
        form: &Form,
        picked: &[(usize, FieldKind)],
        labels: &[String],
        submit: Option<usize>,
        values: &Values,
        place: &str,
    ) -> Value {
        let indices: Vec<usize> = picked.iter().map(|&(index, _)| index).collect();
        if let Err(error) = form.check_unchanged(&indices, submit) {
            return refused(format!(
                "Not filled: {error}. Read the window again and ask again."
            ));
        }
        // Hidden before they are filled, so no read can catch one in between.
        for value in values.values() {
            self.redactions.remember(value);
        }
        for (position, &(index, _)) in picked.iter().enumerate() {
            let Some(value) = values.get(&format!("f{position}")) else {
                return refused("Not filled: a value is missing.");
            };
            if let Err(error) = form.fill(index, value) {
                return refused(format!("Not filled: {error}."));
            }
        }
        let pressed = match submit {
            Some(index) => match form.press(index) {
                Ok(()) => Some(form.buttons[index].clone()),
                Err(error) => {
                    return tool_result(
                        format!(
                            "Filled {} in {place}, but {error}. The values are not shown to you.",
                            listed(labels)
                        ),
                        json!({ "filled": labels, "submitted": false }),
                        true,
                    );
                }
            },
            None => None,
        };
        let text = match &pressed {
            Some(button) => format!(
                "Filled {} in {place} and pressed \u{201c}{button}\u{201d}. The values are not shown to you; reads show them as \u{2022}\u{2022}\u{2022}\u{2022} (filled by you).",
                listed(labels)
            ),
            None => format!(
                "Filled {} in {place}. The values are not shown to you; reads show them as \u{2022}\u{2022}\u{2022}\u{2022} (filled by you).",
                listed(labels)
            ),
        };
        tool_result(
            text,
            json!({ "filled": labels, "app": form.app, "origin": form.origin, "submitted": pressed.is_some() }),
            false,
        )
    }
}

fn title_case(word: &str) -> String {
    let mut chars = word.chars();
    chars
        .next()
        .map(|first| first.to_uppercase().chain(chars).collect())
        .unwrap_or_default()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerInput {
    session_id: SessionId,
    args: Value,
}

const AXOD_ONLY: Only = Only {
    signer: Signer::ThisBinary,
    code: -32003,
    message: "only axod's own tools ask for input",
};

/// `axo.computer.input` and `axo.computer.redactions`, for axod's own `axod mcp`.
pub struct ComputerExtension {
    computer: Arc<ComputerUse>,
    host: Arc<dyn ComputerHost>,
}

impl ComputerExtension {
    pub fn new(computer: Arc<ComputerUse>, host: Arc<dyn ComputerHost>) -> Self {
        Self { computer, host }
    }
}

impl Extension for ComputerExtension {
    fn name(&self) -> &'static str {
        "computer"
    }

    fn register(&self, handler: &mut IoHandler) {
        let (asking, host) = (Arc::clone(&self.computer), Arc::clone(&self.host));
        handler.add_typed_only(
            AXOD_ONLY,
            COMPUTER_INPUT,
            "expected {sessionId, args}",
            move |request: ComputerInput| {
                Ok(asking.request_input(
                    host.as_ref(),
                    request.session_id,
                    None,
                    request.args,
                    Duration::from_millis(TIMEOUT_MS),
                ))
            },
        );
        let hiding = Arc::clone(&self.computer);
        handler.add_typed_only(
            AXOD_ONLY,
            COMPUTER_REDACTIONS,
            "expected no parameters",
            move |_: Value| Ok(hiding.redactions.export()),
        );
    }
}

/// Why a computer call did not run; the script's call fails with it.
pub const NOT_ALLOWED: i64 = -32031;
/// Kept back from the call's time, so the question ends before the account stops waiting.
const ANSWER_MARGIN: Duration = Duration::from_secs(10);
/// The shortest question worth asking.
const SHORTEST_QUESTION: Duration = Duration::from_secs(15);

/// Calls from other Macs' scripts (RFD0028, Computer use from anywhere). A call runs the same
/// gate as the local `computer` tool. When it must ask, this Mac asks in the *calling* Session:
/// its card shows in that chat on the web and the phone, and the answer comes back here. The
/// tool runs only on the person's Accept or the gate passing it.
impl ComputerUse {
    /// One computer-use tool for another Mac's script. `Err` fails the script's call.

    pub fn remote(
        &self,
        host: &dyn ComputerHost,
        request: &ComputerParams,
    ) -> Result<Value, (i64, String)> {
        if !axo_computer::AVAILABLE {
            return Err((-32601, "this Mac has no computer use".into()));
        }
        if request.tool == axo_computer::REQUEST_INPUT {
            let timeout = Duration::from_millis(request.timeout_ms).saturating_sub(ANSWER_MARGIN);
            if timeout < SHORTEST_QUESTION {
                return Err((
                    NOT_ALLOWED,
                    "Not done: no time left to ask the person.".into(),
                ));
            }
            return Ok(self.request_input(
                host,
                request.session_id,
                Some(&request.from),
                request.args.clone(),
                timeout,
            ));
        }
        let socket = host
            .agent_socket()
            .ok_or_else(|| (-32603, "axod has no socket yet".to_owned()))?;
        let gate = axo_computer::gate::for_socket(&socket);
        if let axo_computer::gate::Verdict::Ask(question) =
            gate.check(&request.tool, &request.args, request.confirm)
        {
            ask_for_computer(host, request, &question)?;
        }
        let mut result = axo_computer::call(&request.tool, request.args.clone());
        gate.remember(&request.tool, &result);
        self.redact(&mut result);
        log::info!(
            "event=computer.remote_called tool={} outcome={}",
            request.tool,
            if result["isError"] == json!(true) {
                "error"
            } else {
                "ok"
            }
        );
        Ok(result)
    }

    /// Whether this Mac can do computer use now, from Cua's own probe.
    pub fn status() -> Value {
        let (accessibility, screen_recording) = axo_computer::permissions();
        json!({
            "available": axo_computer::AVAILABLE && accessibility && screen_recording,
            "accessibility": accessibility,
            "screenRecording": screen_recording,
        })
    }
}

/// Asks the person in the calling Session; `Ok` only on Accept.
fn ask_for_computer(
    host: &dyn ComputerHost,
    request: &ComputerParams,
    question: &str,
) -> Result<(), (i64, String)> {
    let available = Duration::from_millis(request.timeout_ms).saturating_sub(ANSWER_MARGIN);
    let timeout = available.min(Duration::from_millis(TIMEOUT_MS));
    if timeout < SHORTEST_QUESTION {
        return Err((
            NOT_ALLOWED,
            "Not done: no time left to ask the person.".into(),
        ));
    }
    let from = format!("\nAsked from {}'s Session.", request.from);
    let room = MAX_MESSAGE_CHARS.saturating_sub(from.chars().count());
    let message: String = question.chars().take(room).collect::<String>() + &from;
    let outcome = host
        .ask_with(
            request.session_id,
            &message,
            Asker::ComputerUse,
            None,
            timeout,
        )
        .map(|(outcome, _)| outcome)
        .map_err(|error| {
            (
                NOT_ALLOWED,
                format!(
                    "Not done: the person could not be asked ({}).",
                    error.message
                ),
            )
        })?;
    match outcome.action {
        ElicitationAction::Accept => Ok(()),
        ElicitationAction::Decline => Err((NOT_ALLOWED, "Not done: the person declined.".into())),
        ElicitationAction::Cancel => {
            Err((NOT_ALLOWED, "Not done: nobody answered in time.".into()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remembered_values_are_hidden_in_every_read() {
        let redactions = Redactions::default();
        redactions.remember("me@example.com");
        redactions.remember("abc");
        let mut read = json!({ "content": [{ "type": "text", "text": "- [16] AXTextField \"Email\" = \"me@example.com\"\n- abc" }] });
        redactions.apply(&mut read);
        assert_eq!(
            read["content"][0]["text"],
            "- [16] AXTextField \"Email\" = \"\u{2022}\u{2022}\u{2022}\u{2022} (filled by you)\"\n- abc"
        );
    }

    #[test]
    fn lists_read_like_a_sentence() {
        assert_eq!(
            listed(&["Email".into(), "Password".into()]),
            "Email and Password"
        );
        assert_eq!(listed(&["A".into(), "B".into(), "C".into()]), "A, B and C");
    }
}
