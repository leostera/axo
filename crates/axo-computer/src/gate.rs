//! The risk gate in front of computer use (RFD0029, Tools ask; agents cannot approve): an action
//! that may be destructive or hard to undo (deleting, sending, paying, publishing...) runs only
//! if a local check finds it harmless or the person allows it. The gate asks the person itself;
//! the agent cannot approve. `confirm: true` from the agent only asks for more: the person is
//! asked without the check.
//!
//! The check is two-stage, so most actions cost nothing:
//! 1. A word filter over what the action does: the target element's role and label (remembered
//!    from the agent's last `get_window_state` of that window), the text it types, the keys it
//!    presses, the script it runs. Nothing flagged, nothing checked.
//! 2. A flagged action goes to Clef on this Mac ([`axod_infer`]), text only (about a second).
//!    If Clef is not installed or fails, the flag alone decides: the person is asked.
//!
//! A flagged action reaches the app only after the person allows it. Clicks at bare coordinates
//! name no element, so only their window is known; they pass the filter unless their text says
//! otherwise.

use std::collections::HashMap;
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::{Mutex, OnceLock};

use axod_infer::{Infer, InferError};
use serde_json::{Value, json};

/// hand's risk question (acoyfellow/hand `src/steer.ts`), for text instead of a screenshot.
const RISK_QUESTION: &str = "Would doing `action` in `window` do something destructive or hard to undo, such as deleting data, removing a person, discarding work, emptying a trash, sending a message or email, posting publicly, sending money or placing an order?";

/// Clef's probability at or above which the person is asked about a flagged action.
const RISKY_AT: f64 = 0.5;

/// Words that make an action worth a check. Matched as whole words, case-insensitively.
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
];

/// Keys that commit what was typed, such as sending a message.
const COMMIT_KEYS: &[&str] = &["return", "enter", "kp_enter", "keypad_enter"];

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
];

/// The verdict on one `computer` call.
#[derive(Debug, PartialEq)]
pub enum Verdict {
    Allow,
    /// Run only if the person allows it; the question, from the gate's own reading of the call.
    Ask(String),
}

/// This process's gate, with Clef beside axod when installed: `axod mcp` for this Mac's agents,
/// axod for other Macs' scripts (RFD0028). `socket` is axod's, beside which Clef's runs.
pub fn for_socket(socket: &Path) -> &'static Gate {
    static GATE: OnceLock<Gate> = OnceLock::new();
    GATE.get_or_init(|| {
        // Until the model files are downloaded, its answers are "unavailable" and the word list
        // alone decides; the first process to find them missing starts the download.
        let judge = socket
            .parent()
            .and_then(Infer::beside_current_exe)
            .filter(|infer| infer.helper.exists())
            .inspect(|infer| {
                if infer.installed().is_err() {
                    let outcome = infer.install_in_background();
                    log::info!(
                        "event=computer.gate_model_missing download={}",
                        outcome.map_or_else(|why| why, |()| "started".into())
                    );
                }
            })
            .map(|infer| Box::new(infer) as Box<dyn Judge>);
        Gate::new(judge)
    })
}

/// What decides a flagged action; Clef on this Mac in production.
pub trait Judge: Send + Sync {
    /// The probability that `action` in `window` is destructive or hard to undo.
    fn risky<'a>(&'a self, action: &'a str, window: &'a str) -> JudgeFuture<'a>;
}

pub type JudgeFuture<'a> = Pin<Box<dyn Future<Output = Result<f64, InferError>> + Send + 'a>>;

impl Judge for Infer {
    fn risky<'a>(&'a self, action: &'a str, window: &'a str) -> JudgeFuture<'a> {
        Box::pin(async move {
            let answers = self
                .ask(&json!({
                    "state": { "action": action, "window": window },
                    "questions": { "risky": { "type": "noul", "instructions": RISK_QUESTION } },
                }))
                .await?;
            answers["risky"]["noul"]
                .as_f64()
                .ok_or_else(|| InferError::Failed(format!("no probability in {answers}")))
        })
    }
}

pub struct Gate {
    judge: Option<Box<dyn Judge>>,
    /// Element token -> `role "label"`, from the latest reads.
    elements: Mutex<HashMap<String, String>>,
    /// `pid:window_id` -> `App — window title`.
    windows: Mutex<HashMap<String, String>>,
}

impl Gate {
    pub fn new(judge: Option<Box<dyn Judge>>) -> Self {
        Self {
            judge,
            elements: Mutex::new(HashMap::new()),
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Learns the elements and window a `get_window_state` result shows.
    pub fn remember(&self, tool: &str, result: &Value) {
        if tool != "get_window_state" {
            return;
        }
        let structured = &result["structuredContent"];
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
            self.windows
                .lock()
                .unwrap()
                .insert(format!("{pid}:{window}"), name);
        }
        let mut elements = self.elements.lock().unwrap();
        // Tokens die when a newer read supersedes them; keep memory bounded.
        if elements.len() > 20_000 {
            elements.clear();
        }
        for element in structured["elements"].as_array().into_iter().flatten() {
            if let Some(token) = element["element_token"].as_str() {
                elements.insert(token.to_string(), describe_element(element));
            }
        }
    }

    /// Decides one call. `asked_for` is the agent's `confirm: true`: it can only make the gate
    /// ask, never let a call through.
    pub async fn check(&self, tool: &str, args: &Value, asked_for: bool) -> Verdict {
        let actions = self.describe(tool, args);
        if asked_for {
            log::info!("event=computer.gate_asked reason=agent");
            return Verdict::Ask(question(
                &actions,
                "The agent asked to check with you first.",
            ));
        }
        if READ_ONLY.contains(&tool) {
            return Verdict::Allow;
        }
        let flagged: Vec<&(String, String)> =
            actions.iter().filter(|(action, _)| flags(action)).collect();
        for (action, window) in flagged {
            let judged = match &self.judge {
                Some(judge) => judge.risky(action, window).await,
                None => Err(InferError::Unavailable("no local model".into())),
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
                            "Stopped because \"{action}\" may be destructive or hard to undo: Clef, on this Mac, rates it {:.0}% likely.",
                            p * 100.0
                        ),
                    ));
                }
                Err(error) => {
                    log::info!("event=computer.gate_asked reason=unjudged error={error}");
                    return Verdict::Ask(question(
                        &actions,
                        &format!(
                            "Stopped because the words in \"{action}\" suggest it may be destructive or hard to undo, and it could not be checked on this Mac."
                        ),
                    ));
                }
            }
        }
        Verdict::Allow
    }

    /// Each action a call performs, as (what it does, where).
    fn describe(&self, tool: &str, args: &Value) -> Vec<(String, String)> {
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
            "run_script" => vec![(
                format!(
                    "run a script: {}",
                    args["script"].as_str().unwrap_or_default()
                ),
                "this Mac".into(),
            )],
            _ => vec![(self.describe_one(tool, args), self.window(args))],
        }
    }

    fn describe_one(&self, tool: &str, args: &Value) -> String {
        let target = args["element_token"]
            .as_str()
            .map(|token| {
                self.elements
                    .lock()
                    .unwrap()
                    .get(token)
                    .cloned()
                    .unwrap_or_else(|| format!("element {token}"))
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
        let mut action = tool.replace('_', " ");
        if let Some(target) = target {
            action = format!("{action} {target}");
        }
        for (key, label) in [
            ("text", "typing"),
            ("value", "setting the value to"),
            ("key", "key"),
        ] {
            if let Some(text) = args[key].as_str() {
                action = format!("{action}, {label} {text:?}");
            }
        }
        if let Some(keys) = args["keys"].as_array() {
            action = format!("{action}, keys {}", Value::Array(keys.clone()));
        }
        if let Some(modifiers) = args["modifiers"].as_array() {
            action = format!("{action} with {}", Value::Array(modifiers.clone()));
        }
        action
    }

    fn window(&self, args: &Value) -> String {
        let key = match (args["pid"].as_u64(), args["window_id"].as_u64()) {
            (Some(pid), Some(window)) => Some(format!("{pid}:{window}")),
            _ => None,
        };
        key.and_then(|key| self.windows.lock().unwrap().get(&key).cloned())
            .or_else(|| args["app"].as_str().map(str::to_string))
            .unwrap_or_else(|| "an app on this Mac".into())
    }
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

/// What the person is asked: every action the call performs, where, and why the gate stopped,
/// all from the gate's reading of the call, never the agent's words. Fits an elicitation.
fn question(actions: &[(String, String)], why: &str) -> String {
    let mut text = String::from("Computer use wants to:");
    for (action, window) in actions {
        text.push_str(&format!("\n• {action} — in {window}"));
    }
    text.push_str(&format!("\n{why}"));
    let limit = axo_protocol::elicitation::MAX_MESSAGE_CHARS;
    if text.chars().count() > limit {
        text = text.chars().take(limit - 1).collect::<String>() + "…";
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
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

    fn gate(p: f64) -> (Gate, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let gate = Gate::new(Some(Box::new(Fixed(p, calls.clone()))));
        gate.remember(
            "get_window_state",
            &json!({ "structuredContent": {
                "pid": 7, "window_id": 9, "app_name": "Mail", "window_title": "Inbox",
                "elements": [
                    { "role": "AXButton", "label": "Delete account", "element_token": "s1:4" },
                    { "role": "AXButton", "label": "Cancel", "element_token": "s1:5" },
                ],
            } }),
        );
        (gate, calls)
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
        let Verdict::Ask(question) = block(risky.check("click", &click, false)) else {
            panic!("the person must be asked about a risky click");
        };
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
    fn confirm_only_asks_and_never_lets_a_call_through() {
        let (gate, calls) = gate(0.01);
        let delete = json!({ "pid": 7, "window_id": 9, "element_token": "s1:4" });
        let cancel = json!({ "pid": 7, "window_id": 9, "element_token": "s1:5" });
        for args in [&delete, &cancel] {
            let Verdict::Ask(question) = block(gate.check("click", args, true)) else {
                panic!("confirm: true must ask the person");
            };
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
        assert!(matches!(
            block(gate.check("click", &send, false)),
            Verdict::Ask(_)
        ));
    }

    #[test]
    fn the_question_fits_an_elicitation() {
        let long = vec![(
            "type text, typing ".to_string() + &"x".repeat(5_000),
            "Notes".to_string(),
        )];
        let text = question(&long, "why");
        assert_eq!(
            text.chars().count(),
            axo_protocol::elicitation::MAX_MESSAGE_CHARS
        );
    }

    #[test]
    fn every_step_of_run_steps_and_every_script_is_looked_at() {
        let (gate, calls) = gate(0.9);
        let steps = json!({ "pid": 7, "window_id": 9, "steps": [
            { "tool": "click", "args": { "element_token": "s1:5" } },
            { "press_key": { "key": "return" } },
        ] });
        assert!(matches!(
            block(gate.check("run_steps", &steps, false)),
            Verdict::Ask(_)
        ));
        let script = json!({ "script": "await click({ role: 'AXButton', name: 'Empty Trash' })" });
        assert!(matches!(
            block(gate.check("run_script", &script, false)),
            Verdict::Ask(_)
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn the_filter_matches_whole_words() {
        assert!(flags("click AXButton \"Send\""));
        assert!(flags("type text, typing \"hi\\n\""));
        assert!(!flags("click AXButton \"Sender details\""));
        assert!(!flags("click AXTextField \"Search\""));
    }
}
