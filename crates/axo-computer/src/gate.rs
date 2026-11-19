//! The risk gate in front of computer use (RFD0029, Tools ask; agents cannot approve; RFD0070):
//! an action that may be destructive or hard to undo (deleting, sending, paying, publishing...)
//! runs only if a local check finds it harmless or the person allows it. The gate asks the person
//! itself; the agent cannot approve. `confirm: true` from the agent only asks for more: the person
//! is asked without the check.
//!
//! Each action a call performs is described from the gate's own reading, then checked:
//! 1. A word filter over what the action does: the target element's role and label (remembered
//!    from this process's reads of that window), the text it types, the keys it presses (named as
//!    Cua names them), the URLs an app is opened with. Nothing flagged, nothing checked.
//! 2. A flagged action goes to Clef on this Mac ([`axod_infer`]), text only (about a second).
//!    If Clef is not installed or fails, the flag alone decides: the person is asked.
//! 3. An action the gate cannot describe, such as a click on an element token it never read, is
//!    put to the person without Clef: nothing can judge an unknown target.
//!
//! Inside `run_script` every action is checked the same way, one by one (`crate::scripts`); a
//! top-level `run_script` is not judged by its source. Clicks at bare coordinates name no element,
//! so only their window is known; they pass the filter unless their text says otherwise.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::{Mutex, OnceLock};

#[cfg(not(windows))]
use axod_infer::Infer;
use serde_json::{Value, json};

/// hand's risk question (acoyfellow/hand `src/steer.ts`), for text instead of a screenshot.
#[cfg(not(windows))]
const RISK_QUESTION: &str = "Would doing `action` in `window` do something destructive or hard to undo, such as deleting data, removing a person, discarding work, emptying a trash, sending a message or email, posting publicly, sending money or placing an order?";

/// Clef's probability at or above which the person is asked about a flagged action.
const RISKY_AT: f64 = 0.5;

/// Words that make an action worth a check. Matched as whole words, case-insensitively, after
/// key names are canonicalised ([`canonical_key`]).
const RISK_WORDS: &[&str] = &[
    "delete",
    "deleted",
    "remove",
    "discard",
    "erase",
    "destroy",
    "wipe",
    "empty",
    "trash",
    "purge",
    "drop",
    "revoke",
    "uninstall",
    "reset",
    "overwrite",
    "replace",
    "send",
    "post",
    "publish",
    "submit",
    "reply",
    "forward",
    "share",
    "invite",
    "pay",
    "buy",
    "purchase",
    "order",
    "checkout",
    "transfer",
    "withdraw",
    "donate",
    "subscribe",
    "unsubscribe",
    "merge",
    "deploy",
    "push",
    "approve",
    "sign",
    "confirm",
    "kick",
    "ban",
    "block",
    "leave",
    "quit",
    "force",
    "permanently",
    "rm",
    // Keys that delete what is selected: Backspace deletes a mail, cmd+Backspace trashes a file.
    "backspace",
    "del",
    "forwarddelete",
];

/// Keys that commit what was typed, such as sending a message, as [`canonical_key`] names them.
const COMMIT_KEYS: &[&str] = &["return", "enter"];

/// Tools that only look.
const READ_ONLY: &[&str] = &[
    "check_permissions",
    "list_apps",
    "list_windows",
    "get_accessibility_tree",
    "get_window_state",
    "screenshot",
    "get_screen_size",
    "get_cursor_position",
    "get_guide",
    #[cfg(target_os = "linux")]
    "input_targets",
];

/// Element labels remembered at most; the oldest go first.
const MAX_LABELS: usize = 20_000;

/// The verdict on one `computer` call.
#[derive(Debug, PartialEq)]
pub enum Verdict {
    Allow,
    /// Run only if the person allows it; the question, from the gate's own reading of the call.
    Ask(String),
    /// Never run, whatever anyone answers; why.
    Refuse(String),
}

/// This process's gate, with Clef beside axod when installed. It runs in axod for every caller,
/// this Mac's agents (through `axod mcp`, a proxy) and other Macs' scripts alike (RFD0028).
/// `socket` is axod's, beside which Clef's runs. Blocks on the filesystem the first time: call
/// it off the runtime.
pub fn for_socket(_socket: &Path) -> &'static Gate {
    static GATE: OnceLock<Gate> = OnceLock::new();
    GATE.get_or_init(|| {
        // Until the model files are downloaded, its answers are "unavailable" and the word list
        // alone decides; the first process to find them missing starts the download.
        #[cfg(not(windows))]
        let judge = _socket
            .parent()
            .and_then(Infer::beside_current_exe)
            .filter(|infer| infer.helper.exists())
            .inspect(|infer| {
                if infer.installed().is_err() {
                    let outcome = infer.install_in_background();
                    log::info!(
                        "event=computer.gate_model_missing download={}",
                        outcome.map_or_else(|why| why.to_string(), |()| "started".into())
                    );
                }
            })
            .map(|infer| Box::new(infer) as Box<dyn Judge>);
        #[cfg(windows)]
        let judge = None;
        Gate::new(judge)
    })
}

/// What it guards is lookups, never half-written, so a panic elsewhere does not stop the gate.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// What decides a flagged action; Clef on this Mac in production.
pub trait Judge: Send + Sync {
    /// The probability that `action` in `window` is destructive or hard to undo.
    fn risky<'a>(&'a self, action: &'a str, window: &'a str) -> JudgeFuture<'a>;
}

/// The gate's classifier failure, independent of any platform's model runtime.
#[derive(Debug)]
pub enum JudgeError {
    Unavailable,
    Failed(String),
}

impl std::fmt::Display for JudgeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => formatter.write_str("no local model"),
            Self::Failed(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for JudgeError {}

pub type JudgeFuture<'a> = Pin<Box<dyn Future<Output = Result<f64, JudgeError>> + Send + 'a>>;

#[cfg(not(windows))]
impl Judge for Infer {
    fn risky<'a>(&'a self, action: &'a str, window: &'a str) -> JudgeFuture<'a> {
        Box::pin(async move {
            let answers = self
                .ask(&json!({
                    "state": { "action": action, "window": window },
                    "questions": { "risky": { "type": "noul", "instructions": RISK_QUESTION } },
                }))
                .await
                .map_err(|error| JudgeError::Failed(error.to_string()))?;
            answers["risky"]["noul"]
                .as_f64()
                .ok_or_else(|| JudgeError::Failed(format!("no probability in {answers}")))
        })
    }
}

/// One thing a call does, as the gate read it.
#[derive(Debug)]
struct Action {
    /// What it does, such as `click AXButton "Send"`.
    what: String,
    /// Where, such as `Mail — Inbox`.
    place: String,
    check: Check,
}

/// How an action is checked.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Check {
    /// Nothing about it is risky.
    Pass,
    /// Its words may be risky: Clef decides, or the person if Clef can't.
    Judge,
    /// The gate cannot tell what it does: the person decides, and this is why.
    Person(&'static str),
}

/// Element token -> `role "label"`, the oldest forgotten first.
#[derive(Default)]
struct Labels {
    by_token: HashMap<String, String>,
    order: VecDeque<String>,
}

impl Labels {
    fn insert(&mut self, token: String, label: String) {
        if self.by_token.insert(token.clone(), label).is_none() {
            self.order.push_back(token);
        }
        while self.order.len() > MAX_LABELS {
            if let Some(oldest) = self.order.pop_front() {
                self.by_token.remove(&oldest);
            }
        }
    }
}

pub struct Gate {
    judge: Option<Box<dyn Judge>>,
    elements: Mutex<Labels>,
    /// `pid:window_id` -> `App — window title`.
    windows: Mutex<HashMap<String, String>>,
}

impl Gate {
    pub fn new(judge: Option<Box<dyn Judge>>) -> Self {
        Self {
            judge,
            elements: Mutex::new(Labels::default()),
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Learns the elements and window a read shows, from its `structuredContent`. Reads carry
    /// their elements because `crate::call` asks Cua for them.
    pub fn remember(&self, tool: &str, structured: &Value) {
        if tool != "get_window_state" {
            return;
        }
        if let (Some(pid), Some(window)) =
            (structured["pid"].as_u64(), structured["window_id"].as_u64())
        {
            let name = format!(
                "{} — {}",
                structured["app_name"].as_str().unwrap_or("an app"),
                structured["window_title"]
                    .as_str()
                    .unwrap_or("untitled window")
            );
            lock(&self.windows).insert(format!("{pid}:{window}"), name);
        }
        let mut labels = lock(&self.elements);
        for element in structured["elements"].as_array().into_iter().flatten() {
            if let Some(token) = element["element_token"].as_str() {
                labels.insert(token.to_string(), describe_element(element));
            }
        }
    }

    /// Decides one call. `asked_for` is the agent's `confirm: true`: it can only make the gate
    /// ask, never let a call through.
    pub async fn check(&self, tool: &str, args: &Value, asked_for: bool) -> Verdict {
        if let Some(refusal) = refusal(tool, args) {
            log::info!("event=computer.gate_refused tool={tool}");
            return Verdict::Refuse(refusal.into());
        }
        let actions = self.describe(tool, args);
        if asked_for {
            log::info!("event=computer.gate_asked reason=agent");
            return Verdict::Ask(question(
                &actions,
                "The agent asked to check with you first.",
            ));
        }
        // A script is not judged by its source: each of its actions is (`crate::scripts`).
        if READ_ONLY.contains(&tool) || tool == "run_script" {
            return Verdict::Allow;
        }
        for action in &actions {
            match action.check {
                Check::Pass => {}
                Check::Person(why) => {
                    log::info!("event=computer.gate_asked reason=unreadable");
                    return Verdict::Ask(question(&actions, &format!("Stopped because {why}.")));
                }
                Check::Judge => {
                    let judged = match &self.judge {
                        Some(judge) => judge.risky(&action.what, &action.place).await,
                        None => Err(JudgeError::Unavailable),
                    };
                    match judged {
                        Ok(p) if p < RISKY_AT => {
                            log::info!("event=computer.gate_passed p={p:.3}");
                        }
                        Ok(p) => {
                            log::info!("event=computer.gate_asked reason=clef p={p:.3}");
                            return Verdict::Ask(question(
                                &actions,
                                &format!(
                                    "Stopped because Clef, on this Mac, rates it {:.0}% likely to be destructive or hard to undo.",
                                    p * 100.0
                                ),
                            ));
                        }
                        Err(error) => {
                            log::info!("event=computer.gate_asked reason=unjudged error={error}");
                            return Verdict::Ask(question(
                                &actions,
                                "Stopped because its words suggest it may be destructive or hard to undo, and it could not be checked on this Mac.",
                            ));
                        }
                    }
                }
            }
        }
        Verdict::Allow
    }

    /// Each action a call performs.
    fn describe(&self, tool: &str, args: &Value) -> Vec<Action> {
        match tool {
            "run_steps" => args["steps"]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(|step| {
                    let (step_tool, step_args) = step_parts(step);
                    let mut merged = step_args.clone();
                    // A step inherits the call's window.
                    for key in ["pid", "window_id", "app", "window"] {
                        if merged.get(key).is_none() && !args[key].is_null() {
                            merged[key] = args[key].clone();
                        }
                    }
                    self.describe(&step_tool, &merged)
                })
                .collect(),
            "run_script" => vec![Action {
                what: format!(
                    "run a script: {}",
                    args["script"].as_str().unwrap_or_default()
                ),
                place: "this Mac".into(),
                check: Check::Pass,
            }],
            "launch_app" => vec![describe_launch(args)],
            _ => vec![self.describe_one(tool, args)],
        }
    }

    fn describe_one(&self, tool: &str, args: &Value) -> Action {
        let mut unreadable = None;
        let target = args["element_token"]
            .as_str()
            .map(|token| match lock(&self.elements).by_token.get(token) {
                Some(label) => label.clone(),
                None => {
                    unreadable = Some("Axo has not read the element it acts on");
                    format!("element {token} (not read by Axo)")
                }
            })
            .or_else(|| {
                let role = args["role"].as_str();
                let name = args["name"].as_str();
                (role.is_some() || name.is_some())
                    .then(|| format!("{} \"{}\"", role.unwrap_or("element"), name.unwrap_or("")))
            })
            .or_else(|| {
                args["path"]
                    .as_array()
                    .map(|path| format!("menu {}", Value::Array(path.clone())))
            })
            .or_else(|| {
                args["x"]
                    .as_f64()
                    .map(|x| format!("the point ({x}, {})", args["y"].as_f64().unwrap_or(0.0)))
            });
        let mut what = tool.replace('_', " ");
        if let Some(target) = target {
            what = format!("{what} {target}");
        }
        for (key, label) in [("text", "typing"), ("value", "setting the value to")] {
            if let Some(text) = args[key].as_str() {
                what = format!("{what}, {label} {text:?}");
            }
        }
        if let Some(key) = args["key"].as_str() {
            what = format!("{what}, key {}", canonical_key(key));
        }
        if let Some(keys) = key_list(&args["keys"]) {
            what = format!("{what}, keys {keys}");
        }
        if let Some(modifiers) = key_list(&args["modifiers"]) {
            what = format!("{what} with {modifiers}");
        }
        let check = match unreadable {
            Some(why) => Check::Person(why),
            None if flags(&what) => Check::Judge,
            None => Check::Pass,
        };
        Action {
            place: self.window(args),
            what,
            check,
        }
    }

    fn window(&self, args: &Value) -> String {
        let key = match (args["pid"].as_u64(), args["window_id"].as_u64()) {
            (Some(pid), Some(window)) => Some(format!("{pid}:{window}")),
            _ => None,
        };
        key.and_then(|key| lock(&self.windows).get(&key).cloned())
            .or_else(|| args["app"].as_str().map(str::to_string))
            .unwrap_or_else(|| "an app on this Mac".into())
    }
}

/// Calls no answer makes safe, and why. Cua already refuses remote debugging; a WebKit inspector
/// port would hand a logged-in app's pages to whoever connects.
fn refusal(tool: &str, args: &Value) -> Option<&'static str> {
    if tool != "launch_app" {
        return None;
    }
    if !args["webkit_inspector_port"].is_null() {
        return Some("Not done: computer use does not open an app's web inspector (webkit_inspector_port).");
    }
    #[cfg(target_os = "linux")]
    if let Some(command) = linux_launch_target(args) {
        use cua_driver_core::launch_guard::{LaunchCommand, LaunchCommandError};
        let additional: Vec<String> = args["additional_arguments"].as_array().into_iter().flatten()
            .filter_map(|value| value.as_str().map(str::to_owned)).collect();
        if matches!(LaunchCommand::parse(command, &additional), Err(LaunchCommandError::RemoteDebugging)) {
            return Some(cua_driver_core::launch_guard::REMOTE_DEBUGGING_LAUNCH_REFUSAL);
        }
    }
    None
}

/// `launch_app`: the app, and everything it is opened with. A URL may run an action (a
/// Shortcuts link, a deep link), and arguments change what the app does, so either is judged.
#[cfg(target_os = "linux")]
fn linux_launch_target(args: &Value) -> Option<&str> {
    args["launch_path"].as_str().or_else(|| args["name"].as_str()).or_else(|| args["bundle_id"].as_str())
}

fn describe_launch(args: &Value) -> Action {
    #[cfg(target_os = "linux")]
    let app = linux_launch_target(args).unwrap_or("an app");
    #[cfg(not(target_os = "linux"))]
    let app = args["bundle_id"]
        .as_str()
        .or_else(|| args["name"].as_str())
        .unwrap_or("an app");
    let mut what = format!("launch app {app}");
    let mut judged = false;
    #[cfg(target_os = "linux")]
    if let Ok(command) = cua_driver_core::launch_guard::LaunchCommand::parse(app, &[]) {
        let program = command.program();
        let displayed = if program.chars().all(|c| c.is_alphanumeric() || matches!(c, '/' | '.' | '_' | '-')) {
            program.to_owned()
        } else {
            serde_json::json!(program).to_string()
        };
        what = format!("launch app {displayed}");
        if !command.arguments().is_empty() {
            what = format!("{what}, with arguments {}", serde_json::json!(command.arguments()));
            judged = true;
        }
    }
    for url in args["urls"].as_array().into_iter().flatten() {
        let url = url.as_str().unwrap_or_default();
        what = format!("{what}, opening {url:?}");
        judged |= !is_file_path(url);
    }
    if let Some(arguments) = args["additional_arguments"].as_array().filter(|list| !list.is_empty()) {
        what = format!("{what}, with arguments {}", Value::Array(arguments.clone()));
        judged = true;
    }
    let check = if judged || flags(&what) {
        Check::Judge
    } else {
        Check::Pass
    };
    Action {
        what,
        place: "this Mac".into(),
        check,
    }
}

fn is_file_path(url: &str) -> bool {
    url.starts_with('/') || url.starts_with("~/") || url == "~" || url.starts_with("file://")
}

/// A key's name as Cua resolves it (`platform-macos` `canonical_key_name`): lowercase, without
/// spaces, `_` or `-`, with the keypad's Enter folded onto `enter`. So `Re-turn`, `e_n_t_e_r`
/// and `numpad enter` read as the Return they press.
fn canonical_key(key: &str) -> String {
    let lower = key.trim().to_lowercase();
    if lower.chars().count() < 2 {
        return lower;
    }
    let compact: String = lower
        .chars()
        .filter(|c| !matches!(c, ' ' | '_' | '-'))
        .collect();
    match compact.as_str() {
        "kpenter" | "numpadenter" => "enter".into(),
        "forwarddelete" | "fwddelete" | "deleteforward" => "forwarddelete".into(),
        "bksp" => "backspace".into(),
        _ => compact,
    }
}

/// A list of key names, canonicalised: `[cmd, backspace]`.
fn key_list(keys: &Value) -> Option<String> {
    let keys = keys.as_array()?;
    let names: Vec<String> = keys
        .iter()
        .map(|key| key.as_str().map_or_else(|| key.to_string(), canonical_key))
        .collect();
    Some(format!("[{}]", names.join(", ")))
}

/// `{tool, args}` or `{<tool>: args}`.
fn step_parts(step: &Value) -> (String, Value) {
    if let Some(tool) = step["tool"].as_str() {
        return (tool.to_string(), step["args"].clone());
    }
    step.as_object()
        .and_then(|object| {
            object
                .iter()
                .find(|(key, _)| !["wait_for", "expect", "timeout_ms"].contains(&key.as_str()))
        })
        .map(|(tool, args)| (tool.clone(), args.clone()))
        .unwrap_or_else(|| ("wait".into(), json!({})))
}

fn describe_element(element: &Value) -> String {
    let role = element["role"].as_str().unwrap_or("element");
    match element["label"].as_str() {
        Some(label) => format!("{role} \"{label}\""),
        None => role.to_string(),
    }
}

/// Whether an action's description is worth a check.
fn flags(action: &str) -> bool {
    let lower = action.to_lowercase();
    let words = lower.split(|c: char| !c.is_alphanumeric() && c != '_');
    let mut words = words.filter(|word| !word.is_empty());
    words.any(|word| RISK_WORDS.contains(&word) || COMMIT_KEYS.contains(&word))
        // Typing a newline commits as Return does.
        || lower.contains("\\n")
        || lower.contains("\\r")
}

/// What the person is asked, all from the gate's reading of the call, never the agent's words:
/// why it stopped, then every action that made it stop, then the others while they fit. Fits an
/// elicitation; only the tail is ever cut, so the reason and the first flagged action always
/// show.
fn question(actions: &[Action], why: &str) -> String {
    let limit = axo_protocol::elicitation::MAX_MESSAGE_CHARS;
    let line = |action: &Action| format!("\n• {} — in {}", action.what, action.place);
    let mut text = format!("Computer use wants to: {why}");
    let (flagged, others): (Vec<&Action>, Vec<&Action>) =
        actions.iter().partition(|action| action.check != Check::Pass);
    for action in &flagged {
        text.push_str(&line(action));
    }
    // Room kept for the line that counts what did not fit.
    const SUMMARY_ROOM: usize = 40;
    let mut shown = 0;
    for action in &others {
        let next = line(action);
        if text.chars().count() + next.chars().count() + SUMMARY_ROOM > limit {
            break;
        }
        text.push_str(&next);
        shown += 1;
    }
    if shown < others.len() {
        text.push_str(&format!("\nAlso: {} more actions.", others.len() - shown));
    }
    if text.chars().count() > limit {
        text = text.chars().take(limit - 1).collect::<String>() + "…";
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(target_os = "linux")]
    fn linux_launch_intent_uses_the_effective_path_and_decoded_arguments() {
        let action = describe_launch(&json!({
            "name":"benign alias", "bundle_id":"another alias",
            "launch_path":r#""/opt/real app" "--re""set-all""#
        }));
        assert!(action.what.contains("/opt/real app"));
        assert!(action.what.contains("--reset-all"));
        assert!(!action.what.contains("benign alias"));
        assert!(matches!(action.check, Check::Judge));
        assert!(refusal("launch_app",&json!({
            "launch_path":r#"chrome "--remote-debugging-"port=0"#
        })).is_some());
        assert!(matches!(describe_launch(&json!({
            "launch_path":r#""/opt/app with spaces""#
        })).check,Check::Pass));
    }

    fn block<F: Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(future)
    }
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Fixed(f64, Arc<AtomicUsize>);
    impl Judge for Fixed {
        fn risky<'a>(&'a self, _: &'a str, _: &'a str) -> JudgeFuture<'a> {
            self.1.fetch_add(1, Ordering::SeqCst);
            Box::pin(std::future::ready(Ok(self.0)))
        }
    }

    /// A read of Mail's Inbox as `crate::call` hands it to the gate: with its elements.
    fn inbox() -> Value {
        json!({
            "pid": 7, "window_id": 9, "app_name": "Mail", "window_title": "Inbox",
            "elements": [
                { "role": "AXButton", "label": "Delete account", "element_token": "s1:4" },
                { "role": "AXButton", "label": "Cancel", "element_token": "s1:5" },
            ],
        })
    }

    fn gate(p: f64) -> (Gate, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let gate = Gate::new(Some(Box::new(Fixed(p, calls.clone()))));
        gate.remember("get_window_state", &inbox());
        (gate, calls)
    }

    fn asked(verdict: Verdict) -> String {
        match verdict {
            Verdict::Ask(question) => question,
            other => panic!("the person must be asked, not {other:?}"),
        }
    }

    #[test]
    fn harmless_actions_are_never_checked() {
        let (gate, calls) = gate(0.99);
        let click = json!({ "pid": 7, "window_id": 9, "element_token": "s1:5" });
        assert_eq!(block(gate.check("click", &click, false)), Verdict::Allow);
        assert_eq!(
            block(gate.check("get_window_state", &json!({}), false)),
            Verdict::Allow
        );
        assert_eq!(
            block(gate.check("type_text", &json!({ "text": "hello there" }), false)),
            Verdict::Allow
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_flagged_action_runs_only_if_clef_finds_it_harmless_or_the_person_is_asked() {
        let click = json!({ "pid": 7, "window_id": 9, "element_token": "s1:4" });
        let (risky, _) = gate(0.97);
        let question = asked(block(risky.check("click", &click, false)));
        assert!(
            question.contains("click AXButton \"Delete account\" — in Mail — Inbox"),
            "{question}"
        );
        assert!(question.contains("97%"), "{question}");
        let (harmless, calls) = gate(0.02);
        assert_eq!(
            block(harmless.check("click", &click, false)),
            Verdict::Allow
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn an_element_the_gate_never_read_is_put_to_the_person() {
        // Before RFD0070 an unread token was described as "click element s2:4", which holds no
        // risk word, so it ran: Cua's default read carries no elements to learn from.
        let (gate, calls) = gate(0.01);
        let click = json!({ "pid": 7, "window_id": 9, "element_token": "s2:4" });
        let question = asked(block(gate.check("click", &click, false)));
        assert!(question.contains("not read by Axo"), "{question}");
        assert_eq!(calls.load(Ordering::SeqCst), 0, "Clef cannot judge an unknown target");
    }

    #[test]
    fn many_reads_forget_the_oldest_labels_not_all_of_them() {
        let (gate, _) = gate(0.99);
        let many: Vec<Value> = (0..MAX_LABELS)
            .map(|i| json!({ "element_token": format!("s2:{i}"), "role": "AXCell" }))
            .collect();
        gate.remember("get_window_state", &json!({ "elements": many }));
        gate.remember("get_window_state", &inbox());
        let question = asked(block(gate.check(
            "click",
            &json!({ "pid": 7, "window_id": 9, "element_token": "s1:4" }),
            false,
        )));
        assert!(question.contains("Delete account"), "{question}");
        let labels = lock(&gate.elements);
        assert_eq!(labels.by_token.len(), MAX_LABELS);
        assert!(!labels.by_token.contains_key("s2:0"), "the oldest went first");
    }

    #[test]
    fn confirm_only_asks_and_never_lets_a_call_through() {
        let (gate, calls) = gate(0.01);
        let delete = json!({ "pid": 7, "window_id": 9, "element_token": "s1:4" });
        let cancel = json!({ "pid": 7, "window_id": 9, "element_token": "s1:5" });
        for args in [&delete, &cancel] {
            let question = asked(block(gate.check("click", args, true)));
            assert!(question.contains("The agent asked"), "{question}");
        }
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "confirm skips the check, not the person"
        );
    }

    #[test]
    fn without_a_local_model_the_flag_alone_asks() {
        let gate = Gate::new(None);
        let send = json!({ "role": "AXButton", "name": "Send" });
        asked(block(gate.check("click", &send, false)));
    }

    #[test]
    fn every_key_spelling_cua_presses_as_return_or_delete_is_checked() {
        let gate = Gate::new(None);
        for key in ["return", "RETURN", "re-turn", "Re Turn", "e_n_t_e_r", "numpad_enter", "kp-enter", "backspace", "del", "Forward_Delete"] {
            let call = json!({ "pid": 7, "window_id": 9, "key": key });
            asked(block(gate.check("press_key", &call, false)));
        }
        for keys in [json!(["cmd", "backspace"]), json!(["cmd", "re-turn"]), json!(["del"])] {
            let call = json!({ "pid": 7, "window_id": 9, "keys": keys });
            asked(block(gate.check("hotkey", &call, false)));
        }
        let tab = json!({ "pid": 7, "window_id": 9, "key": "tab" });
        assert_eq!(block(gate.check("press_key", &tab, false)), Verdict::Allow);
    }

    #[test]
    fn the_question_leads_with_why_and_the_flagged_action() {
        // Thirty harmless steps before a Send used to push the Send and the reason past the
        // elicitation's limit, so the person approved what they never saw.
        let gate = Gate::new(None);
        let mut steps: Vec<Value> = (0..30)
            .map(|i| json!({ "tool": "scroll", "args": { "x": i, "y": 0, "direction": "down" } }))
            .collect();
        steps.push(json!({ "tool": "click", "args": { "role": "AXButton", "name": "Send" } }));
        let question = asked(block(gate.check(
            "run_steps",
            &json!({ "pid": 7, "window_id": 9, "steps": steps }),
            false,
        )));
        let mut lines = question.lines();
        assert!(lines.next().unwrap().contains("Stopped because"), "{question}");
        assert!(lines.next().unwrap().contains("click AXButton \"Send\""), "{question}");
        assert!(question.contains("more actions."), "{question}");
        assert!(question.chars().count() <= axo_protocol::elicitation::MAX_MESSAGE_CHARS);
    }

    #[test]
    fn the_question_fits_an_elicitation() {
        let gate = Gate::new(None);
        let long = json!({ "text": "x".repeat(5_000) + "\n" });
        let question = asked(block(gate.check("type_text", &long, false)));
        assert_eq!(
            question.chars().count(),
            axo_protocol::elicitation::MAX_MESSAGE_CHARS
        );
        assert!(question.starts_with("Computer use wants to: Stopped because"));
    }

    #[test]
    fn every_step_of_run_steps_is_looked_at_and_scripts_are_judged_inside() {
        let (gate, calls) = gate(0.9);
        let steps = json!({ "pid": 7, "window_id": 9, "steps": [
            { "tool": "click", "args": { "element_token": "s1:5" } },
            { "press_key": { "key": "return" } },
        ] });
        asked(block(gate.check("run_steps", &steps, false)));
        // Each action inside a script is checked as it runs (`crate::scripts`), not its source.
        let script = json!({ "script": "await click({ role: 'AXButton', name: 'Empty Trash' })" });
        assert_eq!(block(gate.check("run_script", &script, false)), Verdict::Allow);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn what_an_app_is_opened_with_is_shown_and_judged() {
        let (gate, calls) = gate(0.97);
        let shortcut = json!({ "bundle_id": "com.apple.shortcuts",
            "urls": ["shortcuts://run-shortcut?name=Tidy"] });
        let question = asked(block(gate.check("launch_app", &shortcut, false)));
        assert!(question.contains("shortcuts://run-shortcut?name=Tidy"), "{question}");
        let arguments = json!({ "bundle_id": "com.example.app", "additional_arguments": ["--reset-all"] });
        assert!(asked(block(gate.check("launch_app", &arguments, false))).contains("--reset-all"));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        let folder = json!({ "bundle_id": "com.apple.finder", "urls": ["/Users/me/Documents"] });
        assert_eq!(block(gate.check("launch_app", &folder, false)), Verdict::Allow);
        let confirmed = asked(block(gate.check("launch_app", &shortcut, true)));
        assert!(confirmed.contains("launch app com.apple.shortcuts, opening"), "{confirmed}");
    }

    #[test]
    fn an_apps_web_inspector_is_never_opened() {
        let (gate, _) = gate(0.01);
        let inspector = json!({ "bundle_id": "com.apple.mail", "webkit_inspector_port": 9222 });
        for confirm in [false, true] {
            assert!(matches!(
                block(gate.check("launch_app", &inspector, confirm)),
                Verdict::Refuse(_)
            ));
        }
    }

    #[test]
    fn the_filter_matches_whole_words() {
        assert!(flags("click AXButton \"Send\""));
        assert!(flags("type text, typing \"hi\\n\""));
        assert!(!flags("click AXButton \"Sender details\""));
        assert!(!flags("click AXTextField \"Search\""));
    }
}
