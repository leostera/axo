//! The risk gate in front of computer use: an action that may be destructive or hard to undo
//! (deleting, sending, paying, publishing...) runs only if the agent says the person agreed
//! (`confirm: true`), or a local check finds it harmless.
//!
//! The check is two-stage, so most actions cost nothing:
//! 1. A word filter over what the action does: the target element's role and label (remembered
//!    from the agent's last `get_window_state` of that window), the text it types, the keys it
//!    presses, the script it runs. Nothing flagged, nothing checked.
//! 2. A flagged action goes to Clef on this Mac ([`axo_decide`]), text only (about a second).
//!    If Clef is not installed or fails, the flag alone decides: the action is refused.
//!
//! A refused action never reaches the app. The agent is told why and to ask the person, then to
//! call again with `confirm: true`. Clicks at bare coordinates name no element, so only their
//! window is known; they pass the filter unless their text says otherwise.

use std::collections::HashMap;
use std::sync::Mutex;

use axo_decide::{Decide, DecideError};
use serde_json::{Value, json};

/// hand's risk question (acoyfellow/hand `src/steer.ts`), for text instead of a screenshot.
const RISK_QUESTION: &str = "Would doing `action` in `window` do something destructive or hard to undo, such as deleting data, removing a person, discarding work, emptying a trash, sending a message or email, posting publicly, sending money or placing an order?";

/// Clef's probability at or above which a flagged action is refused.
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
    "get_desktop_state",
    "get_screen_size",
    "get_cursor_position",
    "get_guide",
];

/// The verdict on one `computer` call.
#[derive(Debug, PartialEq)]
pub enum Verdict {
    Allow,
    Refuse(String),
}

/// What decides a flagged action; Clef on this Mac in production.
pub trait Judge: Send + Sync {
    /// The probability that `action` in `window` is destructive or hard to undo.
    fn risky(&self, action: &str, window: &str) -> Result<f64, DecideError>;
}

impl Judge for Decide {
    fn risky(&self, action: &str, window: &str) -> Result<f64, DecideError> {
        let answers = self.ask(&json!({
            "state": { "action": action, "window": window },
            "questions": { "risky": { "type": "noul", "instructions": RISK_QUESTION } },
        }))?;
        answers["risky"]["noul"]
            .as_f64()
            .ok_or_else(|| DecideError::Failed(format!("no probability in {answers}")))
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

    /// Decides one call; `args` has had `confirm` taken out already.
    pub fn check(&self, tool: &str, args: &Value, confirmed: bool) -> Verdict {
        if confirmed || READ_ONLY.contains(&tool) {
            return Verdict::Allow;
        }
        let actions = self.describe(tool, args);
        let flagged: Vec<&(String, String)> =
            actions.iter().filter(|(action, _)| flags(action)).collect();
        for (action, window) in flagged {
            let judged = match &self.judge {
                Some(judge) => judge.risky(action, window),
                None => Err(DecideError::Unavailable("no local model".into())),
            };
            match judged {
                Ok(p) if p < RISKY_AT => {
                    log::info!("event=computer.gate_passed p={p:.3}");
                }
                Ok(p) => {
                    log::info!("event=computer.gate_refused p={p:.3}");
                    return Verdict::Refuse(refusal(
                        action,
                        &format!(
                            "Clef, on this Mac, rates it {:.0}% likely to be destructive or hard to undo",
                            p * 100.0
                        ),
                    ));
                }
                Err(error) => {
                    log::info!("event=computer.gate_refused reason=unjudged error={error}");
                    return Verdict::Refuse(refusal(
                        action,
                        &format!(
                            "its words suggest it may be destructive or hard to undo, and it could not be checked ({error})"
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

fn refusal(action: &str, why: &str) -> String {
    format!(
        "Not done: {action:?}; {why}. Ask the person whether to go ahead; if they agree, call `computer` again with the same tool and args and `confirm: true`."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Fixed(f64, Arc<AtomicUsize>);
    impl Judge for Fixed {
        fn risky(&self, _: &str, _: &str) -> Result<f64, DecideError> {
            self.1.fetch_add(1, Ordering::SeqCst);
            Ok(self.0)
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
        assert_eq!(gate.check("click", &click, false), Verdict::Allow);
        assert_eq!(
            gate.check("get_window_state", &json!({}), false),
            Verdict::Allow
        );
        assert_eq!(
            gate.check("type_text", &json!({ "text": "hello there" }), false),
            Verdict::Allow
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_flagged_action_runs_only_if_clef_finds_it_harmless_or_the_agent_confirms() {
        let click = json!({ "pid": 7, "window_id": 9, "element_token": "s1:4" });
        let (risky, _) = gate(0.97);
        let Verdict::Refuse(message) = risky.check("click", &click, false) else {
            panic!("a risky click must be refused");
        };
        assert!(
            message.contains("AXButton \\\"Delete account\\\""),
            "{message}"
        );
        assert!(message.contains("confirm: true"), "{message}");
        assert_eq!(risky.check("click", &click, true), Verdict::Allow);
        let (harmless, calls) = gate(0.02);
        assert_eq!(harmless.check("click", &click, false), Verdict::Allow);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn without_a_local_model_the_flag_alone_refuses() {
        let gate = Gate::new(None);
        let send = json!({ "role": "AXButton", "name": "Send" });
        assert!(matches!(
            gate.check("click", &send, false),
            Verdict::Refuse(_)
        ));
        assert_eq!(gate.check("click", &send, true), Verdict::Allow);
    }

    #[test]
    fn every_step_of_run_steps_and_every_script_is_looked_at() {
        let (gate, calls) = gate(0.9);
        let steps = json!({ "pid": 7, "window_id": 9, "steps": [
            { "tool": "click", "args": { "element_token": "s1:5" } },
            { "press_key": { "key": "return" } },
        ] });
        assert!(matches!(
            gate.check("run_steps", &steps, false),
            Verdict::Refuse(_)
        ));
        let script = json!({ "script": "await click({ role: 'AXButton', name: 'Empty Trash' })" });
        assert!(matches!(
            gate.check("run_script", &script, false),
            Verdict::Refuse(_)
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
