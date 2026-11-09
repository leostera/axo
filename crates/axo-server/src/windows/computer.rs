//! Windows computer use, owned by the daemon. Both MCP and relay use this gate.
use super::*;
use axo_protocol::elicitation::{Asker, Elicitation, ElicitationAction, ElicitationKind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub const CALL: &str = "axo.computer.call";
pub const STATUS: &str = "axo.computer.status";
pub const TOOLS: &str = "axo.computer.tools";
pub const SETTINGS: &str = "axo.windows.settings";
pub const SAVE_SETTINGS: &str = "axo.windows.settings.save";

#[derive(Clone, Default, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    #[serde(default)]
    pub codex_full_access: bool,
    #[serde(default)]
    pub computer_use_enabled: bool,
}

struct Question {
    elicitation: Elicitation,
    answer: mpsc::SyncSender<ElicitationAction>,
}

#[derive(Default)]
pub struct Computer {
    pub settings: Mutex<Settings>,
    generation: std::sync::atomic::AtomicU64,
    questions: Mutex<HashMap<String, Question>>,
    execution: Mutex<()>,
    inputs: axo_questions::Questions,
    forms: axo_computer_use::ComputerUse,
    input_key: std::sync::OnceLock<axo_seal::InputKey>,
    key_lock: Mutex<()>,
    sensitive: AtomicBool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Call {
    pub session_id: SessionId,
    pub tool: String,
    #[serde(default = "empty_object")]
    pub args: Value,
    #[serde(default)]
    pub confirm: bool,
    #[serde(default = "default_timeout")]
    pub timeout_ms: u64,
}
fn empty_object() -> Value {
    json!({})
}
fn default_timeout() -> u64 {
    60_000
}

fn failed(message: &str) -> Value {
    json!({"content":[{"type":"text","text":message}],"isError":true})
}

impl Computer {
    pub fn load(directory: &Path) -> io::Result<Self> {
        let settings = match std::fs::read(directory.join("windows-settings.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => Settings::default(),
            Err(e) => return Err(e),
        };
        Ok(Self {
            settings: Mutex::new(settings),
            ..Default::default()
        })
    }
    pub fn status(&self) -> Value {
        let enabled = self.settings.lock().unwrap().computer_use_enabled;
        let locked = axo_computer::screen_locked();
        json!({"available":enabled && !locked,"enabled":enabled,"accessibility":!locked,"screenRecording":!locked,"locked":locked,"platform":"windows"})
    }
    pub fn list(&self) -> Vec<Elicitation> {
        let mut result: Vec<_> = self
            .questions
            .lock()
            .unwrap()
            .values()
            .map(|q| q.elicitation.clone())
            .collect();
        result.extend(self.inputs.pending());
        result
    }
    pub fn pending(&self, session: SessionId) -> Vec<Value> {
        self.list().iter().filter(|q| q.session_id == session)
            .map(|q| json!({"id":q.id,"method":"axo.computer.confirm","params":{"message":q.message}})).collect()
    }
    pub fn resolve(&self, backend: &Backend, id: &str, action: ElicitationAction) -> bool {
        if self.inputs.pending().iter().any(|q| q.id == id) {
            if action == ElicitationAction::Cancel {
                self.inputs.cancel(backend, id);
                return true;
            }
            return false;
        }
        let question = self.questions.lock().unwrap().remove(id);
        let Some(question) = question else {
            return false;
        };
        let action = if question.elicitation.expires_at <= now() {
            ElicitationAction::Cancel
        } else {
            action
        };
        let _ = question.answer.try_send(action);
        backend.publish(Event::ElicitationResolved {
            id: id.into(),
            session_id: question.elicitation.session_id,
            action,
        });
        backend.publish_snapshot(question.elicitation.session_id);
        true
    }
    pub fn cancel_session(&self, backend: &Backend, session: SessionId) {
        for q in self.list().iter().filter(|q| q.session_id == session) {
            self.resolve(backend, &q.id, ElicitationAction::Cancel);
        }
    }
    pub fn call(&self, backend: &Backend, mut request: Call, cancelled: &AtomicBool) -> Value {
        if !request.args.is_object() || request.timeout_ms == 0 || request.timeout_ms > 300_000 {
            return failed("args must be an object and timeoutMs must be between 1 and 300000.");
        }
        if request.args.get("screenshot_out_file").is_some() {
            return failed(
                "Windows computer screenshots are returned inline; writing an arbitrary output file is not supported.",
            );
        }
        let settings = self.settings.lock().unwrap();
        if !settings.computer_use_enabled {
            return failed(
                "Computer use is disabled. Enable it in Axo Settings > General > Computer Use.",
            );
        }
        let generation = self.generation.load(Ordering::Acquire);
        drop(settings);
        if request.tool == "run_steps" {
            return self.steps(backend, request, cancelled);
        }
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
        if !READ_ONLY.contains(&request.tool.as_str()) && request.tool != "launch_app" {
            let pid = request.args["pid"]
                .as_u64()
                .and_then(|p| u32::try_from(p).ok());
            if pid.is_none()
                || request.args["window_id"].as_u64().is_none()
                || request.args["scope"] == "desktop"
            {
                return failed(
                    "Windows actions need the pid and window_id from a fresh window reading. Desktop-scope input is not available.",
                );
            }
            let image = match super::security::process_image(pid.unwrap()) {
                Ok(image) => image,
                Err(_) => {
                    return failed(
                        "The target process is gone or cannot be verified. Read the window again.",
                    );
                }
            };
            if image.file_name().is_some_and(|name| {
                ["Axo.exe", "axod.exe"]
                    .iter()
                    .any(|n| name.to_string_lossy().eq_ignore_ascii_case(n))
            }) {
                return failed(
                    "Computer tools cannot operate Axo's own interface or permission controls. The person must answer in Axo.",
                );
            }
        }
        // Definitions are the actual platform allowlist, not the complete Cua registry.
        let definitions = axo_computer::tool_definitions();
        let Some(definition) = definitions.iter().find(|t| t["name"] == request.tool) else {
            return failed(
                "This computer tool is not available on Windows. Call computer_tools to see supported tools.",
            );
        };
        if definition["inputSchema"]["properties"]
            .get("session")
            .is_some()
        {
            request.args["session"] = json!(request.session_id.to_string());
        }
        if request.tool == "request_input" {
            return self.input(backend, request, cancelled, generation);
        }
        let deadline = Instant::now() + Duration::from_millis(request.timeout_ms);
        let gate = axo_computer::gate::for_socket(&backend.directory);
        if let axo_computer::gate::Verdict::Ask(message) =
            gate.check(&request.tool, &request.args, request.confirm)
        {
            let message = message.replace("this Mac", "this PC");
            if message.chars().count() > axo_protocol::elicitation::MAX_MESSAGE_CHARS {
                return failed(
                    "The complete action is too large to show for approval. Use a smaller action.",
                );
            }
            let id = match axo_protocol::new_uuid_v4() {
                Ok(id) => id,
                Err(e) => return failed(&e.to_string()),
            };
            let created_at = now();
            let elicitation = Elicitation {
                id: id.clone(),
                session_id: request.session_id,
                kind: ElicitationKind::Confirm,
                asked_by: Asker::ComputerUse,
                message,
                input: None,
                created_at,
                expires_at: created_at + request.timeout_ms,
            };
            let (answer, receiver) = mpsc::sync_channel(1);
            {
                let mut questions = self.questions.lock().unwrap();
                if questions.len() >= axo_protocol::elicitation::MAX_PENDING {
                    return failed("Too many computer-use questions are pending.");
                }
                questions.insert(
                    id.clone(),
                    Question {
                        elicitation: elicitation.clone(),
                        answer,
                    },
                );
            }
            backend.publish(Event::ElicitationRequested { elicitation });
            backend.publish_snapshot(request.session_id);
            let action = loop {
                if cancelled.load(Ordering::Acquire)
                    || self.generation.load(Ordering::Acquire) != generation
                    || Instant::now() >= deadline
                    || !self.settings.lock().unwrap().computer_use_enabled
                {
                    self.resolve(backend, &id, ElicitationAction::Cancel);
                    break ElicitationAction::Cancel;
                }
                match receiver.recv_timeout(Duration::from_millis(50)) {
                    Ok(action) => break action,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(_) => break ElicitationAction::Cancel,
                }
            };
            if action != ElicitationAction::Accept {
                return failed("Not done: permission was declined, cancelled, or expired.");
            }
        }
        let _execution = self.execution.lock().unwrap();
        if cancelled.load(Ordering::Acquire)
            || self.generation.load(Ordering::Acquire) != generation
            || Instant::now() >= deadline
            || !self.settings.lock().unwrap().computer_use_enabled
        {
            return failed(
                "Not done: the call was cancelled, expired, or computer use was disabled.",
            );
        }
        let mut result = axo_computer::call(&request.tool, request.args);
        if self.sensitive.load(Ordering::Acquire) {
            hide_images(&mut result);
        }
        self.forms.redact(&mut result);
        gate.remember(&request.tool, &result);
        result
    }
}

fn hide_images(value: &mut Value) {
    match value {
        Value::Array(items) => {
            items.retain(|v| v["type"] != "image");
            for item in items {
                hide_images(item);
            }
        }
        Value::Object(map) => {
            for (key, value) in map.iter_mut() {
                if key.contains("screenshot") || key.contains("image") {
                    *value = Value::Null;
                } else {
                    hide_images(value);
                }
            }
        }
        _ => {}
    }
}

impl axo_questions::QuestionsHost for Backend {
    fn has_session(&self, id: SessionId) -> bool {
        self.session(id).is_ok()
    }
    fn publish(&self, event: Event) {
        self.publish(event);
    }
    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        self.computer.key(&self.directory)
    }
}

impl axo_computer_use::ComputerHost for Backend {
    fn ask_with(
        &self,
        session: SessionId,
        message: &str,
        asker: Asker,
        input: Option<axo_protocol::elicitation::InputRequest>,
        timeout: Duration,
    ) -> Result<
        (
            axo_protocol::elicitation::ElicitationOutcome,
            Option<axo_questions::Values>,
        ),
        jsonrpc_core::Error,
    > {
        self.computer
            .inputs
            .ask_with(self, session, message, asker, input, timeout)
    }
    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        self.computer.key(&self.directory)
    }
    fn agent_socket(&self) -> Option<PathBuf> {
        Some(self.directory.clone())
    }
}

impl Computer {
    fn key(&self, directory: &Path) -> Option<&axo_seal::InputKey> {
        use axo_relay::credential::HostCredentialStore;
        let _lock = self.key_lock.lock().ok()?;
        if self.input_key.get().is_none() {
            let store = super::credentials::Credentials(directory.join("credentials"));
            const ID: &str = "a5c1e7d0-5e4b-4c1f-9d3a-1f0b2c3d4e5f";
            let key = match store.load(ID) {
                Ok(bytes) => {
                    axo_seal::InputKey::from_secret_bytes(&zeroize::Zeroizing::new(bytes))?
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    let key = axo_seal::InputKey::generate();
                    store.store(ID, &key.to_secret_bytes()).ok()?;
                    key
                }
                Err(_) => return None,
            };
            let _ = self.input_key.set(key);
        }
        self.input_key.get()
    }
    pub fn answer(
        &self,
        backend: &Backend,
        id: &str,
        answer: axo_protocol::elicitation::ElicitationAnswer,
        reply: axo_protocol::elicitation::Reply,
    ) -> Result<(), (i64, String)> {
        if self.inputs.pending().iter().any(|q| q.id == id) {
            return self.inputs.resolve(backend, id, answer, reply);
        }
        if !matches!(reply, axo_protocol::elicitation::Reply::Bare) {
            return Err((-32602, "Confirmation takes no field values".into()));
        }
        if self.resolve(backend, id, answer.into()) {
            Ok(())
        } else {
            Err((
                axo_protocol::elicitation::NOT_PENDING,
                "Already answered or expired".into(),
            ))
        }
    }
    fn input(
        &self,
        backend: &Backend,
        request: Call,
        cancelled: &AtomicBool,
        generation: u64,
    ) -> Value {
        let deadline = Instant::now() + Duration::from_millis(request.timeout_ms);
        let _execution = self.execution.lock().unwrap();
        if cancelled.load(Ordering::Acquire)
            || generation != self.generation.load(Ordering::Acquire)
            || axo_computer::screen_locked()
            || Instant::now() >= deadline
        {
            return failed("Input request cancelled or computer unavailable.");
        }
        // No screenshot may expose a value after filling, including non-password codes.
        self.sensitive.store(true, Ordering::Release);
        let cancellation = axo_ipc::cancel::Cancellation::default();
        let finished = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let cancellation = &cancellation;
            let finished = &finished;
            scope.spawn(move || {
                while !finished.load(Ordering::Acquire) {
                    if cancelled.load(Ordering::Acquire)
                        || generation != self.generation.load(Ordering::Acquire)
                        || Instant::now() >= deadline
                    {
                        cancellation.cancel();
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
            });
            let host = InputHost {
                backend,
                generation,
                cancelled,
                deadline,
            };
            let result = axo_ipc::cancel::on_this_thread(cancellation.clone(), || {
                self.forms.request_input(
                    &host,
                    request.session_id,
                    None,
                    request.args,
                    deadline.saturating_duration_since(Instant::now()),
                )
            });
            finished.store(true, Ordering::Release);
            result
        })
    }
    fn steps(&self, backend: &Backend, request: Call, cancelled: &AtomicBool) -> Value {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Step {
            tool: String,
            #[serde(default = "empty_object")]
            args: Value,
            #[serde(default)]
            confirm: bool,
        }
        let Some(steps) = request.args.get("steps").and_then(Value::as_array) else {
            return failed("run_steps needs a steps array.");
        };
        if steps.is_empty() || steps.len() > 32 {
            return failed("Use 1 to 32 steps.");
        }
        let steps: Vec<Step> = match serde_json::from_value(Value::Array(steps.clone())) {
            Ok(s) => s,
            Err(_) => return failed("Each step needs tool, args and optional confirm."),
        };
        if steps
            .iter()
            .any(|s| matches!(s.tool.as_str(), "run_steps" | "run_script"))
        {
            return failed("Nested scripts are not supported.");
        }
        let deadline = Instant::now() + Duration::from_millis(request.timeout_ms);
        let generation = self.generation.load(Ordering::Acquire);
        let mut results = vec![];
        for step in steps {
            let remaining = deadline
                .saturating_duration_since(Instant::now())
                .as_millis() as u64;
            if remaining == 0
                || cancelled.load(Ordering::Acquire)
                || generation != self.generation.load(Ordering::Acquire)
            {
                return failed("Sequence cancelled, expired, or permission revoked.");
            }
            let result = self.call(
                backend,
                Call {
                    session_id: request.session_id,
                    tool: step.tool,
                    args: step.args,
                    confirm: request.confirm || step.confirm,
                    timeout_ms: remaining,
                },
                cancelled,
            );
            let failed = result["isError"] == true;
            results.push(result);
            if failed {
                return json!({"content":[{"type":"text","text":"Stopped at the first failed or declined step."}],"structuredContent":{"steps":results},"isError":true});
            }
        }
        json!({"content":[{"type":"text","text":"Steps completed."}],"structuredContent":{"steps":results},"isError":false})
    }
}

struct InputHost<'a> {
    backend: &'a Backend,
    generation: u64,
    cancelled: &'a AtomicBool,
    deadline: Instant,
}
impl axo_computer_use::ComputerHost for InputHost<'_> {
    fn input_allowed(&self) -> bool {
        !self.cancelled.load(Ordering::Acquire)
            && Instant::now() < self.deadline
            && self.generation == self.backend.computer.generation.load(Ordering::Acquire)
            && self
                .backend
                .computer
                .settings
                .lock()
                .unwrap()
                .computer_use_enabled
            && !axo_computer::screen_locked()
    }
    fn ask_with(
        &self,
        session: SessionId,
        message: &str,
        asker: Asker,
        input: Option<axo_protocol::elicitation::InputRequest>,
        timeout: Duration,
    ) -> Result<
        (
            axo_protocol::elicitation::ElicitationOutcome,
            Option<axo_questions::Values>,
        ),
        jsonrpc_core::Error,
    > {
        self.backend
            .computer
            .inputs
            .ask_with(self.backend, session, message, asker, input, timeout)
    }
    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        self.backend.computer.key(&self.backend.directory)
    }
    fn agent_socket(&self) -> Option<PathBuf> {
        Some(self.backend.directory.clone())
    }
}
fn now() -> u64 {
    axo_store::unix_timestamp().max(0) as u64 * 1000
}

impl Backend {
    pub(super) fn mcp_config(&self, session: SessionId) -> io::Result<Vec<String>> {
        let command = serde_json::to_string(&std::env::current_exe()?.to_string_lossy())?;
        let args = serde_json::to_string(&[
            "mcp",
            "--pipe",
            &self.pipe,
            "--session",
            &session.to_string(),
        ])?;
        Ok(vec![
            format!("mcp_servers.axo.command={command}"),
            format!("mcp_servers.axo.args={args}"),
            "mcp_servers.axo.tool_timeout_sec=310".into(),
        ])
    }
    pub(super) fn turn_params(&self, thread: &str, text: String) -> io::Result<Value> {
        let full = self.computer.settings.lock().unwrap().codex_full_access;
        Ok(
            json!({"threadId":thread,"input":[{"type":"text","text":text}],
            "approvalPolicy":if full {"never"} else {"on-request"},
            "sandboxPolicy":if full {json!({"type":"dangerFullAccess"})} else {json!({"type":"workspaceWrite","networkAccess":false})}}),
        )
    }
    pub(super) fn save_settings(&self, settings: Settings) -> io::Result<Value> {
        let mut current = self.computer.settings.lock().unwrap();
        let temporary = self.directory.join("windows-settings.tmp");
        std::fs::write(&temporary, serde_json::to_vec_pretty(&settings)?)?;
        std::fs::rename(&temporary, self.directory.join("windows-settings.json"))?;
        let disabled = !settings.computer_use_enabled;
        if disabled {
            self.computer.generation.fetch_add(1, Ordering::AcqRel);
        }
        *current = settings;
        drop(current);
        if disabled {
            for question in self.computer.list() {
                self.computer
                    .resolve(self, &question.id, ElicitationAction::Cancel);
            }
        }
        Ok(json!({"saved":true,"appliesTo":"next Codex turn and new connections"}))
    }
}
