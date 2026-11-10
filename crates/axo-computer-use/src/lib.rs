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

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axo_computer::form::{FieldKind, FieldReading, Form, FormError, pick_field};
use axo_ipc::peer::{Caller, Signer};
use axo_ipc::{Only, TypedMethods};
use axo_protocol::SessionId;
use axo_protocol::elicitation::{
    Asker, ElicitationAction, InputField, InputFieldKind, InputRequest, MAX_INPUT_FIELDS,
    MAX_MESSAGE_CHARS, TIMEOUT_MS,
};
use axo_protocol::rpc::method::{COMPUTER_INPUT, COMPUTER_REDACTIONS};
use axo_protocol::rpc::{MethodError, error_code};
use axo_relay::computer::ComputerParams;
use jsonrpc_core::IoHandler;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use axo_ipc::Extension;
use axo_questions::{Answer, Values};
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

/// What axod read of a window's form: what the person sees there.
#[derive(Clone)]
struct Reading {
    app: String,
    window_title: String,
    origin: Option<String>,
    fields: Vec<FieldReading>,
    buttons: Vec<String>,
}

/// A window with a form: read once, then filled only if it is unchanged. [`Form`] is the real
/// one; tests stand in for it. Its calls block on the app's accessibility: run them off the
/// runtime.
trait Window: Send {
    fn reading(&self) -> Reading;
    fn check_unchanged(&self, fields: &[usize], submit: Option<usize>) -> Result<(), FormError>;
    fn fill(&self, field: usize, value: &str) -> Result<(), FormError>;
    fn press(&self, button: usize) -> Result<(), FormError>;
}

impl Window for Form {
    fn reading(&self) -> Reading {
        Reading {
            app: self.app.clone(),
            window_title: self.window_title.clone(),
            origin: self.origin.clone(),
            fields: self.fields.clone(),
            buttons: self.buttons.clone(),
        }
    }
    fn check_unchanged(&self, fields: &[usize], submit: Option<usize>) -> Result<(), FormError> {
        Form::check_unchanged(self, fields, submit)
    }
    fn fill(&self, field: usize, value: &str) -> Result<(), FormError> {
        Form::fill(self, field, value)
    }
    fn press(&self, button: usize) -> Result<(), FormError> {
        Form::press(self, button)
    }
}

/// Who asked for input, where to ask, and for how long.
struct Asking<'a> {
    session_id: SessionId,
    from: Option<&'a str>,
    timeout: Duration,
}

/// A future computer use waits on: it holds no thread.
pub type HostFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What computer use needs of the rest of axod.
pub trait ComputerHost: Send + Sync {
    /// Asks the person in `session_id` and waits, for a form when `input` is given.
    fn ask_with<'a>(
        &'a self,
        session_id: SessionId,
        message: &'a str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> HostFuture<'a, Result<Answer, RpcError>>;
    /// This Mac's input key, which forms are sealed to; read or made on first use.
    fn input_key(&self) -> HostFuture<'_, Option<&axo_seal::InputKey>>;
    /// axod's socket, where the gate's state lives (`axo_computer::gate`).
    fn agent_socket(&self) -> Option<std::path::PathBuf>;
}

/// A field of the window's form picked for one the agent asked for.
#[derive(Clone, Copy)]
struct PickedField {
    /// Its place among the form's fields.
    index: usize,
    kind: FieldKind,
}

/// What to ask the person for and fill in: the fields picked in a window's form, what each is
/// called there, and the button to press once filled.
struct FillPlan {
    form: Reading,
    picked: Vec<PickedField>,
    labels: Vec<String>,
    submit: Option<usize>,
    /// The app and its page or window, as the question and the receipt name them.
    place: String,
}

impl FillPlan {
    /// Picks the fields asked for in what the window shows; the refusal to answer with when it
    /// cannot satisfy them.
    fn pick(form: Reading, args: &InputArgs) -> Result<Self, Value> {
        let mut picked: Vec<PickedField> = Vec::new();
        for wanted in &args.fields {
            let Some(kind) = FieldKind::parse(&wanted.kind) else {
                return Err(refused(format!(
                    "{} is not a field kind: use username, email, password, code or text",
                    wanted.kind
                )));
            };
            match pick_field(&form.fields, wanted.label.as_deref(), kind) {
                Ok(index) if picked.iter().any(|field| field.index == index) => {
                    return Err(refused(format!(
                        "two fields asked for \"{}\"",
                        form.fields[index].label
                    )));
                }
                Ok(index) => picked.push(PickedField { index, kind }),
                Err(error) => return Err(refused(error.0)),
            }
        }
        let submit = match &args.submit {
            None => None,
            Some(label) => {
                let wanted = label.trim().to_lowercase();
                let found = form
                    .buttons
                    .iter()
                    .position(|button| button.trim().to_lowercase() == wanted);
                match found {
                    Some(index) => Some(index),
                    None => {
                        return Err(refused(format!(
                            "no button \"{label}\"; the window's buttons are {}",
                            form.buttons
                                .iter()
                                .map(|b| format!("\"{b}\""))
                                .collect::<Vec<_>>()
                                .join(", ")
                        )));
                    }
                }
            }
        };
        let labels: Vec<String> = picked
            .iter()
            .map(|field| match form.fields[field.index].label.trim() {
                "" => title_case(field.kind.as_str()),
                label => label.to_owned(),
            })
            .collect();
        let place = match &form.origin {
            Some(origin) => format!("{} — {origin}", form.app),
            None => format!("{} — {}", form.app, form.window_title),
        };
        Ok(Self {
            form,
            picked,
            labels,
            submit,
            place,
        })
    }

    /// The question, as the person reads it.
    fn message(&self, asking: &Asking) -> String {
        let mut message = format!("Fill {} in {}", listed(&self.labels), self.place);
        if let Some(index) = self.submit {
            message.push_str(&format!(
                ", then press \u{201c}{}\u{201d}",
                self.form.buttons[index]
            ));
        }
        message.push('.');
        if let Some(from) = asking.from {
            message.push_str(&format!("\nAsked from {from}'s Session."));
        }
        message.chars().take(MAX_MESSAGE_CHARS).collect()
    }

    /// The form the person fills in, sealed to `key`.
    fn input(&self, key: String) -> InputRequest {
        InputRequest {
            app: self.form.app.clone(),
            window: self.form.window_title.clone(),
            origin: self.form.origin.clone(),
            fields: self
                .picked
                .iter()
                .zip(&self.labels)
                .enumerate()
                .map(|(position, (field, label))| InputField {
                    id: format!("f{position}"),
                    label: label.clone(),
                    kind: protocol_kind(field.kind),
                })
                .collect(),
            submit: self.submit.map(|index| self.form.buttons[index].clone()),
            key,
        }
    }
}

/// What computer use keeps: the values the person filled in, hidden from every later read.
#[derive(Default)]
pub struct ComputerUse {
    redactions: Arc<Redactions>,
}

impl ComputerUse {
    /// Hides values the person filled in from a computer tool's result.
    pub fn redact(&self, result: &mut Value) {
        self.redactions.apply(result);
    }

    /// `request_input`, for an agent's Session here or another Mac's script (`from` names its
    /// Mac). Answers like a computer tool: a receipt, or an error saying why nothing was filled.
    pub async fn request_input(
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
        let Some(key) = host.input_key().await.map(axo_seal::InputKey::public_key) else {
            return refused("this Mac could not make or read its input key");
        };
        let (pid, window_id) = (args.pid, args.window_id);
        let window = match off_runtime(move || Form::read(pid, window_id)).await {
            Ok(form) => Arc::new(Mutex::new(form)),
            Err(error) => return refused(error.0),
        };
        let asking = Asking {
            session_id,
            from,
            timeout,
        };
        self.ask_and_fill(host, &asking, &args, key, window).await
    }

    /// Picks the fields asked for in `window`, asks the person for them and fills them in.
    async fn ask_and_fill(
        &self,
        host: &dyn ComputerHost,
        asking: &Asking<'_>,
        args: &InputArgs,
        key: String,
        window: Arc<Mutex<dyn Window>>,
    ) -> Value {
        let plan = match FillPlan::pick(window.lock().unwrap().reading(), args) {
            Ok(plan) => plan,
            Err(refusal) => return refusal,
        };
        let message = plan.message(asking);
        let timeout = asking.timeout.min(Duration::from_millis(TIMEOUT_MS));
        let asked = host
            .ask_with(
                asking.session_id,
                &message,
                Asker::ComputerUse,
                Some(plan.input(key)),
                timeout,
            )
            .await;
        let answer = match asked {
            Ok(answer) => answer,
            Err(error) => {
                return refused(format!(
                    "Not done: the person could not be asked ({}).",
                    error.message
                ));
            }
        };
        let values = match (answer.outcome.action, answer.values) {
            (ElicitationAction::Accept, Some(values)) => values,
            (ElicitationAction::Decline, _) => return refused("Not done: the person declined."),
            _ => return refused("Not done: nobody answered in time."),
        };
        let redactions = Arc::clone(&self.redactions);
        let fields = plan.picked.len();
        let submitted = plan.submit.is_some();
        let receipt =
            off_runtime(move || fill(&redactions, &*window.lock().unwrap(), &plan, &values)).await;
        log::info!(
            "event=input.filled fields={fields} submitted={submitted} outcome={}",
            if receipt["isError"] == json!(true) {
                "error"
            } else {
                "ok"
            }
        );
        receipt
    }
}

/// Fills the person's values into the window if it is unchanged, presses the button asked for,
/// and answers with a receipt that never shows them.
fn fill(redactions: &Redactions, window: &dyn Window, plan: &FillPlan, values: &Values) -> Value {
    let FillPlan {
        form,
        picked,
        labels,
        submit,
        place,
    } = plan;
    let indices: Vec<usize> = picked.iter().map(|field| field.index).collect();
    if let Err(error) = window.check_unchanged(&indices, *submit) {
        return refused(format!(
            "Not filled: {error}. Read the window again and ask again."
        ));
    }
    // Hidden before they are filled, so no read can catch one in between.
    for value in values.values() {
        redactions.remember(value);
    }
    for (position, field) in picked.iter().enumerate() {
        let Some(value) = values.get(&format!("f{position}")) else {
            return refused("Not filled: a value is missing.");
        };
        if let Err(error) = window.fill(field.index, value) {
            return refused(format!("Not filled: {error}."));
        }
    }
    let pressed = match submit {
        Some(index) => match window.press(*index) {
            Ok(()) => Some(form.buttons[*index].clone()),
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

/// Runs the accessibility or Cua work of a call on the blocking pool. A panic there is this
/// call's.
async fn off_runtime<R: Send + 'static>(work: impl FnOnce() -> R + Send + 'static) -> R {
    match tokio::task::spawn_blocking(work).await {
        Ok(result) => result,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
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
    caller: Caller::Signed(Signer::ThisBinary),
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
                let (asking, host) = (Arc::clone(&asking), Arc::clone(&host));
                async move {
                    Ok(asking
                        .request_input(
                            host.as_ref(),
                            request.session_id,
                            None,
                            request.args,
                            Duration::from_millis(TIMEOUT_MS),
                        )
                        .await)
                }
            },
        );
        let hiding = Arc::clone(&self.computer);
        handler.add_typed_only(
            AXOD_ONLY,
            COMPUTER_REDACTIONS,
            "expected no parameters",
            move |_: Value| std::future::ready(Ok(hiding.redactions.export())),
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
    pub async fn remote(
        &self,
        host: &dyn ComputerHost,
        request: &ComputerParams,
    ) -> Result<Value, MethodError> {
        if !axo_computer::AVAILABLE {
            return Err(MethodError::new(
                error_code::METHOD_NOT_FOUND,
                "this Mac has no computer use",
            ));
        }
        if request.tool == axo_computer::REQUEST_INPUT {
            let timeout = Duration::from_millis(request.timeout_ms).saturating_sub(ANSWER_MARGIN);
            if timeout < SHORTEST_QUESTION {
                return Err(MethodError::new(
                    NOT_ALLOWED,
                    "Not done: no time left to ask the person.",
                ));
            }
            return Ok(self
                .request_input(
                    host,
                    request.session_id,
                    Some(&request.from),
                    request.args.clone(),
                    timeout,
                )
                .await);
        }
        let socket = host.agent_socket().ok_or_else(|| {
            MethodError::new(error_code::INTERNAL_ERROR, "axod has no socket yet")
        })?;
        let gate = off_runtime(move || axo_computer::gate::for_socket(&socket)).await;
        let verdict = gate
            .check(&request.tool, &request.args, request.confirm)
            .await;
        if let axo_computer::gate::Verdict::Ask(question) = verdict {
            ask_for_computer(host, request, &question).await?;
        }
        let (tool, args) = (request.tool.clone(), request.args.clone());
        let redactions = Arc::clone(&self.redactions);
        let result = off_runtime(move || {
            let mut result = axo_computer::call(&tool, args);
            gate.remember(&tool, &result);
            redactions.apply(&mut result);
            result
        })
        .await;
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

    /// Whether this Mac can do computer use now, from Cua's own probe. Blocks on the window
    /// server and TCC.
    pub fn status() -> Value {
        let (accessibility, screen_recording) = axo_computer::permissions();
        json!({
            "available": axo_computer::AVAILABLE && accessibility && screen_recording,
            "accessibility": accessibility,
            "screenRecording": screen_recording,
            "locked": axo_computer::screen_locked(),
        })
    }
}

/// Asks the person in the calling Session; `Ok` only on Accept.
async fn ask_for_computer(
    host: &dyn ComputerHost,
    request: &ComputerParams,
    question: &str,
) -> Result<(), MethodError> {
    let available = Duration::from_millis(request.timeout_ms).saturating_sub(ANSWER_MARGIN);
    let timeout = available.min(Duration::from_millis(TIMEOUT_MS));
    if timeout < SHORTEST_QUESTION {
        return Err(MethodError::new(
            NOT_ALLOWED,
            "Not done: no time left to ask the person.",
        ));
    }
    let from = format!("\nAsked from {}'s Session.", request.from);
    let room = MAX_MESSAGE_CHARS.saturating_sub(from.chars().count());
    let message: String = question.chars().take(room).collect::<String>() + &from;
    let answer = host
        .ask_with(
            request.session_id,
            &message,
            Asker::ComputerUse,
            None,
            timeout,
        )
        .await
        .map_err(|error| {
            MethodError::new(
                NOT_ALLOWED,
                format!(
                    "Not done: the person could not be asked ({}).",
                    error.message
                ),
            )
        })?;
    match answer.outcome.action {
        ElicitationAction::Accept => Ok(()),
        ElicitationAction::Decline => Err(MethodError::new(
            NOT_ALLOWED,
            "Not done: the person declined.",
        )),
        ElicitationAction::Cancel => Err(MethodError::new(
            NOT_ALLOWED,
            "Not done: nobody answered in time.",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zeroize::Zeroizing;

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

    /// A host that answers every question as told and records what was asked.
    struct Host {
        answer: Result<ElicitationAction, &'static str>,
        key: Option<axo_seal::InputKey>,
        asked: Mutex<Vec<(String, Duration, bool)>>,
        /// What an accepted form is answered with.
        values: Option<Values>,
        forms: Mutex<Vec<InputRequest>>,
    }

    impl Host {
        fn answering(answer: Result<ElicitationAction, &'static str>) -> Self {
            Self {
                answer,
                key: Some(axo_seal::InputKey::generate()),
                asked: Mutex::default(),
                values: None,
                forms: Mutex::default(),
            }
        }

        fn asked(&self) -> Vec<(String, Duration, bool)> {
            self.asked.lock().unwrap().clone()
        }
    }

    impl ComputerHost for Host {
        fn ask_with<'a>(
            &'a self,
            _session_id: SessionId,
            message: &'a str,
            asked_by: Asker,
            input: Option<InputRequest>,
            timeout: Duration,
        ) -> HostFuture<'a, Result<Answer, RpcError>> {
            assert_eq!(asked_by, Asker::ComputerUse);
            self.asked
                .lock()
                .unwrap()
                .push((message.to_owned(), timeout, input.is_some()));
            self.forms.lock().unwrap().extend(input);
            let answer = match self.answer {
                Ok(action) => Ok(Answer {
                    outcome: axo_protocol::elicitation::ElicitationOutcome {
                        id: "e-1".into(),
                        action,
                    },
                    values: self.values.clone(),
                }),
                Err(message) => Err(RpcError::invalid_params(message)),
            };
            Box::pin(std::future::ready(answer))
        }

        fn input_key(&self) -> HostFuture<'_, Option<&axo_seal::InputKey>> {
            Box::pin(std::future::ready(self.key.as_ref()))
        }

        fn agent_socket(&self) -> Option<std::path::PathBuf> {
            None
        }
    }

    const SESSION: SessionId = SessionId::from_u128(7);

    fn call(tool: &str, timeout_ms: u64) -> ComputerParams {
        ComputerParams {
            account_id: "account".into(),
            call_id: "call".into(),
            tool: tool.into(),
            args: json!({}),
            confirm: true,
            session_id: SESSION,
            from: "Leo's MacBook".into(),
            timeout_ms,
        }
    }

    fn refusal(result: &Value) -> String {
        assert_eq!(result["isError"], json!(true), "{result}");
        result["content"][0]["text"].as_str().unwrap().to_owned()
    }

    /// Runs one call to its end, as axod's runtime would.
    fn block<F: Future>(call: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(call)
    }

    fn ask(host: &Host, question: &str, timeout_ms: u64) -> Result<(), MethodError> {
        block(ask_for_computer(host, &call("click", timeout_ms), question))
    }

    #[test]
    fn the_gates_question_runs_the_tool_only_on_accept() {
        let minute = 60_000;
        assert_eq!(
            ask(
                &Host::answering(Ok(ElicitationAction::Accept)),
                "Click?",
                minute
            ),
            Ok(())
        );
        for (answer, said) in [
            (
                Ok(ElicitationAction::Decline),
                "Not done: the person declined.",
            ),
            (
                Ok(ElicitationAction::Cancel),
                "Not done: nobody answered in time.",
            ),
            (
                Err("no such Session"),
                "Not done: the person could not be asked (no such Session).",
            ),
        ] {
            assert_eq!(
                ask(&Host::answering(answer), "Click?", minute),
                Err(MethodError::new(NOT_ALLOWED, said))
            );
        }
    }

    #[test]
    fn the_question_names_the_calling_mac_and_fits_the_limit() {
        let host = Host::answering(Ok(ElicitationAction::Accept));
        ask(&host, &"x".repeat(MAX_MESSAGE_CHARS * 2), 60_000).unwrap();
        let (message, timeout, form) = host.asked().remove(0);
        assert!(
            message.ends_with("\nAsked from Leo's MacBook's Session."),
            "{message}"
        );
        assert_eq!(message.chars().count(), MAX_MESSAGE_CHARS);
        assert_eq!(
            timeout,
            Duration::from_secs(50),
            "the call's time less the margin"
        );
        assert!(!form, "the gate asks yes or no");
    }

    #[test]
    fn a_question_never_outlasts_its_own_limit() {
        let host = Host::answering(Ok(ElicitationAction::Accept));
        ask(&host, "Click?", TIMEOUT_MS * 10).unwrap();
        assert_eq!(host.asked()[0].1, Duration::from_millis(TIMEOUT_MS));
    }

    #[test]
    fn with_no_time_left_nobody_is_asked() {
        let host = Host::answering(Ok(ElicitationAction::Accept));
        let short = (ANSWER_MARGIN + SHORTEST_QUESTION).as_millis() as u64 - 1;
        assert_eq!(
            ask(&host, "Click?", short),
            Err(MethodError::new(
                NOT_ALLOWED,
                "Not done: no time left to ask the person."
            ))
        );
        if axo_computer::AVAILABLE {
            assert_eq!(
                block(
                    ComputerUse::default().remote(&host, &call(axo_computer::REQUEST_INPUT, short))
                ),
                Err(MethodError::new(
                    NOT_ALLOWED,
                    "Not done: no time left to ask the person."
                ))
            );
        }
        assert!(host.asked().is_empty());
    }

    #[test]
    fn a_mac_without_computer_use_says_so_and_a_missing_socket_fails_the_call() {
        let host = Host::answering(Ok(ElicitationAction::Accept));
        let outcome = block(ComputerUse::default().remote(&host, &call("click", 60_000)));
        if axo_computer::AVAILABLE {
            assert_eq!(
                outcome,
                Err(MethodError::new(
                    error_code::INTERNAL_ERROR,
                    "axod has no socket yet"
                ))
            );
        } else {
            assert_eq!(
                outcome,
                Err(MethodError::new(
                    error_code::METHOD_NOT_FOUND,
                    "this Mac has no computer use"
                ))
            );
        }
        assert!(host.asked().is_empty());
    }

    #[test]
    fn input_requests_that_cannot_be_filled_are_refused_before_asking() {
        let computer = ComputerUse::default();
        let host = Host::answering(Ok(ElicitationAction::Accept));
        let request = |host: &Host, args: Value| {
            refusal(&block(computer.request_input(
                host,
                SESSION,
                None,
                args,
                Duration::from_secs(60),
            )))
        };
        assert!(request(&host, json!({ "pid": 1 })).starts_with("request_input takes {"));
        let field = json!({ "kind": "password" });
        for fields in [vec![], vec![field; MAX_INPUT_FIELDS + 1]] {
            assert_eq!(
                request(&host, json!({ "pid": 1, "window_id": 2, "fields": fields })),
                format!("ask for 1 to {MAX_INPUT_FIELDS} fields")
            );
        }
        let keyless = Host {
            key: None,
            ..Host::answering(Ok(ElicitationAction::Accept))
        };
        assert_eq!(
            request(
                &keyless,
                json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "password" }] })
            ),
            "this Mac could not make or read its input key"
        );
        assert!(host.asked().is_empty() && keyless.asked().is_empty());
    }

    #[test]
    fn the_extension_offers_input_and_redactions_to_axod_alone() {
        let extension = ComputerExtension::new(
            Arc::default(),
            Arc::new(Host::answering(Ok(ElicitationAction::Accept))),
        );
        assert_eq!(extension.name(), "computer");
        let mut handler = IoHandler::new();
        extension.register(&mut handler);
        let mut methods: Vec<_> = handler.iter().map(|(name, _)| name.clone()).collect();
        methods.sort();
        assert_eq!(methods, [COMPUTER_INPUT, COMPUTER_REDACTIONS]);
    }

    #[test]
    fn a_fresh_computer_hides_nothing_and_exports_its_salt() {
        let computer = ComputerUse::default();
        let mut read = json!({ "content": [{ "type": "text", "text": "hunter2" }] });
        computer.redact(&mut read);
        assert_eq!(read["content"][0]["text"], "hunter2");
        let exported = computer.redactions.export();
        assert_eq!(exported["hashes"], json!([]), "{exported}");
    }

    /// A window that reads as given, fails where told, and records what was done to it.
    #[derive(Default, Clone)]
    struct FakeWindow {
        fields: Vec<(&'static str, bool)>,
        buttons: Vec<&'static str>,
        changed: bool,
        fill_fails: bool,
        press_fails: bool,
        filled: Arc<Mutex<Vec<(usize, String)>>>,
        pressed: Arc<Mutex<Vec<usize>>>,
    }

    impl FakeWindow {
        /// A sign-in page: an email field, a password field and a "Sign in" button.
        fn sign_in() -> Self {
            Self {
                fields: vec![("Email address", false), ("Password", true)],
                buttons: vec!["Forgot password?", "Sign in"],
                ..Self::default()
            }
        }
    }

    impl Window for FakeWindow {
        fn reading(&self) -> Reading {
            Reading {
                app: "Safari".into(),
                window_title: "Sign in to GitHub".into(),
                origin: Some("https://github.com".into()),
                fields: self
                    .fields
                    .iter()
                    .map(|&(label, secure)| FieldReading {
                        label: label.into(),
                        secure,
                    })
                    .collect(),
                buttons: self.buttons.iter().map(|&b| b.to_owned()).collect(),
            }
        }
        fn check_unchanged(&self, _: &[usize], _: Option<usize>) -> Result<(), FormError> {
            if self.changed {
                return Err(FormError("the page changed".into()));
            }
            Ok(())
        }
        fn fill(&self, field: usize, value: &str) -> Result<(), FormError> {
            if self.fill_fails {
                return Err(FormError("the field took no value".into()));
            }
            self.filled.lock().unwrap().push((field, value.to_owned()));
            Ok(())
        }
        fn press(&self, button: usize) -> Result<(), FormError> {
            if self.press_fails {
                return Err(FormError("the button did not press".into()));
            }
            self.pressed.lock().unwrap().push(button);
            Ok(())
        }
    }

    fn values(pairs: &[(&str, &str)]) -> Values {
        pairs
            .iter()
            .map(|&(id, value)| (id.to_owned(), Zeroizing::new(value.to_owned())))
            .collect()
    }

    fn answering_with(values: Values) -> Host {
        Host {
            values: Some(values),
            ..Host::answering(Ok(ElicitationAction::Accept))
        }
    }

    /// `request_input` on `window`, asked from another Mac with a minute to answer.
    fn ask_in(computer: &ComputerUse, host: &Host, window: &FakeWindow, args: Value) -> Value {
        let args: InputArgs = serde_json::from_value(args).unwrap();
        let asking = Asking {
            session_id: SESSION,
            from: Some("Leo's MacBook"),
            timeout: Duration::from_secs(60),
        };
        let key = host.key.as_ref().unwrap().public_key();
        let window: Arc<Mutex<dyn Window>> = Arc::new(Mutex::new(window.clone()));
        block(computer.ask_and_fill(host, &asking, &args, key, window))
    }

    const SIGN_IN: &str = "Sign in";

    fn sign_in_args() -> Value {
        json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "email" }, { "kind": "password" }], "submit": "sign IN" })
    }

    #[test]
    fn a_form_is_asked_for_by_what_the_person_sees_then_filled_submitted_and_hidden() {
        let computer = ComputerUse::default();
        let host = answering_with(values(&[("f0", "leo@example.com"), ("f1", "hunter22")]));
        let window = FakeWindow::sign_in();
        let receipt = ask_in(&computer, &host, &window, sign_in_args());

        let (message, timeout, _) = host.asked().remove(0);
        assert_eq!(
            message,
            "Fill Email address and Password in Safari \u{2014} https://github.com, then press \u{201c}Sign in\u{201d}.\nAsked from Leo's MacBook's Session."
        );
        assert_eq!(timeout, Duration::from_secs(60));
        let form = host.forms.lock().unwrap().remove(0);
        assert_eq!(
            (
                form.app.as_str(),
                form.origin.as_deref(),
                form.submit.as_deref()
            ),
            ("Safari", Some("https://github.com"), Some(SIGN_IN))
        );
        assert_eq!(form.key, host.key.as_ref().unwrap().public_key());
        let fields: Vec<_> = form
            .fields
            .iter()
            .map(|field| (field.id.as_str(), field.label.as_str(), field.kind))
            .collect();
        assert_eq!(
            fields,
            [
                ("f0", "Email address", InputFieldKind::Email),
                ("f1", "Password", InputFieldKind::Password)
            ]
        );

        assert_eq!(
            *window.filled.lock().unwrap(),
            [(0, "leo@example.com".into()), (1, "hunter22".into())]
        );
        assert_eq!(*window.pressed.lock().unwrap(), [1]);
        assert_eq!(receipt["isError"], json!(false), "{receipt}");
        assert_eq!(
            receipt["structuredContent"],
            json!({ "filled": ["Email address", "Password"], "app": "Safari", "origin": "https://github.com", "submitted": true })
        );
        let text = receipt["content"][0]["text"].as_str().unwrap();
        assert!(
            !text.contains("hunter22") && text.contains("pressed"),
            "{text}"
        );

        // Every later read hides both values.
        let mut read = json!({ "text": "hunter22", "email": "leo@example.com" });
        computer.redact(&mut read);
        assert!(!read.to_string().contains("hunter22"), "{read}");
        assert!(!read.to_string().contains("leo@example.com"), "{read}");
        assert_eq!(
            computer.redactions.export()["hashes"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn a_field_with_no_label_is_named_by_its_kind_and_nothing_is_pressed_unless_asked() {
        let computer = ComputerUse::default();
        let host = answering_with(values(&[("f0", "123456")]));
        let window = FakeWindow {
            fields: vec![("  ", false)],
            ..FakeWindow::default()
        };
        let receipt = ask_in(
            &computer,
            &host,
            &window,
            json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "code" }] }),
        );
        assert!(
            host.asked()[0].0.starts_with("Fill Code in Safari"),
            "{:?}",
            host.asked()
        );
        assert_eq!(receipt["structuredContent"]["submitted"], json!(false));
        assert!(window.pressed.lock().unwrap().is_empty());
        // Too short to hide wherever it appears.
        let mut read = json!("123");
        computer.redact(&mut read);
        assert_eq!(read, json!("123"));
    }

    #[test]
    fn a_request_the_window_cannot_satisfy_is_refused_before_asking() {
        let computer = ComputerUse::default();
        let host = Host::answering(Ok(ElicitationAction::Accept));
        let window = FakeWindow::sign_in();
        let refuse = |args: Value| refusal(&ask_in(&computer, &host, &window, args));
        assert_eq!(
            refuse(json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "pin" }] })),
            "pin is not a field kind: use username, email, password, code or text"
        );
        assert_eq!(
            refuse(
                json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "password" }, { "kind": "text", "label": "password" }] })
            ),
            "two fields asked for \"Password\""
        );
        assert_eq!(
            refuse(
                json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "password", "label": "Email address" }] })
            ),
            "\"Email address\" is not a secure field; a password goes only into one"
        );
        assert_eq!(
            refuse(
                json!({ "pid": 1, "window_id": 2, "fields": [{ "kind": "password" }], "submit": "Log in" })
            ),
            "no button \"Log in\"; the window's buttons are \"Forgot password?\", \"Sign in\""
        );
        assert!(host.asked().is_empty());
    }

    #[test]
    fn nothing_is_filled_unless_the_person_accepts_with_values() {
        for (host, said) in [
            (
                Host::answering(Ok(ElicitationAction::Decline)),
                "Not done: the person declined.",
            ),
            (
                Host::answering(Ok(ElicitationAction::Cancel)),
                "Not done: nobody answered in time.",
            ),
            (
                Host::answering(Ok(ElicitationAction::Accept)),
                "Not done: nobody answered in time.",
            ),
            (
                Host::answering(Err("no such Session")),
                "Not done: the person could not be asked (no such Session).",
            ),
        ] {
            let window = FakeWindow::sign_in();
            let result = ask_in(&ComputerUse::default(), &host, &window, sign_in_args());
            assert_eq!(refusal(&result), said);
            assert_eq!(result["structuredContent"]["filled"], json!(false));
            assert!(window.filled.lock().unwrap().is_empty());
        }
    }

    #[test]
    fn a_changed_page_or_a_failed_fill_fills_nothing_more() {
        let both = values(&[("f0", "leo@example.com"), ("f1", "hunter22")]);
        let cases = [
            (
                FakeWindow {
                    changed: true,
                    ..FakeWindow::sign_in()
                },
                both.clone(),
                "Not filled: the page changed. Read the window again and ask again.",
            ),
            (
                FakeWindow {
                    fill_fails: true,
                    ..FakeWindow::sign_in()
                },
                both.clone(),
                "Not filled: the field took no value.",
            ),
            (
                FakeWindow::sign_in(),
                values(&[("f0", "leo@example.com")]),
                "Not filled: a value is missing.",
            ),
        ];
        for (window, answer, said) in cases {
            let host = answering_with(answer);
            let result = ask_in(&ComputerUse::default(), &host, &window, sign_in_args());
            assert_eq!(refusal(&result), said);
            assert!(window.pressed.lock().unwrap().is_empty());
        }
    }

    #[test]
    fn a_button_that_will_not_press_reports_the_fields_filled_but_not_submitted() {
        let host = answering_with(values(&[("f0", "leo@example.com"), ("f1", "hunter22")]));
        let window = FakeWindow {
            press_fails: true,
            ..FakeWindow::sign_in()
        };
        let result = ask_in(&ComputerUse::default(), &host, &window, sign_in_args());
        assert_eq!(
            refusal(&result),
            "Filled Email address and Password in Safari \u{2014} https://github.com, but the button did not press. The values are not shown to you."
        );
        assert_eq!(
            result["structuredContent"],
            json!({ "filled": ["Email address", "Password"], "submitted": false })
        );
        assert_eq!(window.filled.lock().unwrap().len(), 2);
    }

    #[test]
    fn an_input_question_never_outlasts_its_own_limit() {
        let host = answering_with(values(&[("f0", "x"), ("f1", "y")]));
        let args: InputArgs = serde_json::from_value(sign_in_args()).unwrap();
        let asking = Asking {
            session_id: SESSION,
            from: None,
            timeout: Duration::from_millis(TIMEOUT_MS * 10),
        };
        block(ComputerUse::default().ask_and_fill(
            &host,
            &asking,
            &args,
            host.key.as_ref().unwrap().public_key(),
            Arc::new(Mutex::new(FakeWindow::sign_in())),
        ));
        let (message, timeout, _) = host.asked().remove(0);
        assert_eq!(timeout, Duration::from_millis(TIMEOUT_MS));
        assert!(!message.contains("Asked from"), "{message}");
    }
}
