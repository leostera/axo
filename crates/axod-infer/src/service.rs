//! Local inference orchestration: inspect HF metadata, pin artifacts, install, load, execute.
//! Task adapters belong to Axo; model repositories can supply data, never executable code.
#[cfg(test)]
#[path = "coreml_service_tests.rs"]
mod coreml_tests;
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::Mutex;

pub use crate::api::Request;
use crate::api::{Backend, Input, Question, Selection, Task};
use crate::catalog::{self, Inspection, Resolved, Role};
use crate::{Infer, blocking, http, physical_memory};

pub const MAX_TIMEOUT_MS: u64 = 240_000;
const RUNTIME: &str = include_str!(env!("AXO_INFER_CAPABILITIES"));

#[derive(Debug)]
pub enum Error {
    Invalid(String),
    Unsupported(String),
    Busy,
    Unavailable(String),
    Failed(String),
}
impl Error {
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::Unsupported(message.into())
    }
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self::Unavailable(message.into())
    }
    pub fn failed(message: impl Into<String>) -> Self {
        Self::Failed(message.into())
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(message)
            | Self::Unsupported(message)
            | Self::Unavailable(message)
            | Self::Failed(message) => f.write_str(message),
            Self::Busy => {
                f.write_str("another AI operation is running on this Mac; try after it finishes")
            }
        }
    }
}

#[derive(Default)]
struct State {
    active: Option<Active>,
    runtime_busy: bool,
    retiring: Option<Retirement>,
    #[cfg(test)]
    started: Option<std::sync::Arc<tokio::sync::Notify>>,
}
enum Retirement {
    Running(tokio::task::JoinHandle<()>),
    Failed,
}
impl State {
    fn start_retiring(&mut self, runtime: &tokio::runtime::Handle) {
        if self.retiring.is_none() {
            if let Some(active) = self.active.take() {
                self.runtime_busy = true;
                self.retiring = Some(Retirement::Running(runtime.spawn(active.runtime.stop())));
            }
        }
    }
    async fn retire(&mut self) -> Result<(), Error> {
        self.start_retiring(&tokio::runtime::Handle::current());
        let result = match self.retiring.as_mut() {
            Some(Retirement::Running(task)) => task.await,
            Some(Retirement::Failed) => {
                return Err(Error::unavailable(
                    "runtime retirement failed; restart Axo before another inference operation",
                ));
            }
            None => {
                self.runtime_busy = false;
                return Ok(());
            }
        };
        self.runtime_busy = false;
        if result.is_err() {
            self.retiring = Some(Retirement::Failed);
            return Err(Error::unavailable(
                "could not establish runtime quiescence; restart Axo",
            ));
        }
        self.retiring = None;
        Ok(())
    }
}

/// Dropping the caller's future revokes runtime ownership too. Store retirement in State so
/// cancellation cannot discard the only child handle or admit work while reaping is pending.
struct Operation<'a> {
    state: tokio::sync::MutexGuard<'a, State>,
    runtime: tokio::runtime::Handle,
}
impl std::ops::Deref for Operation<'_> {
    type Target = State;
    fn deref(&self) -> &State {
        &self.state
    }
}
impl std::ops::DerefMut for Operation<'_> {
    fn deref_mut(&mut self) -> &mut State {
        &mut self.state
    }
}
impl Drop for Operation<'_> {
    fn drop(&mut self) {
        if self.state.runtime_busy {
            self.state.start_retiring(&self.runtime);
        }
    }
}
enum Runtime {
    Llama(Infer),
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    Mlx(crate::native_process::Process),
    #[cfg(target_os = "macos")]
    CoreMl(crate::native_process::Process),
}
impl Runtime {
    async fn stop(self) {
        match self {
            Self::Llama(infer) => infer.stop().await,
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            Self::Mlx(process) => process.stop().await,
            #[cfg(target_os = "macos")]
            Self::CoreMl(process) => process.stop().await,
        }
    }
    async fn ensure_running(&mut self) -> Result<(), Error> {
        match self {
            Self::Llama(infer) => infer.ensure_running().await.map_err(|_| Error::unsupported("The pinned llama.cpp runtime could not load this selection; inspect ai/infer.log. No repository code was executed.")),
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            Self::Mlx(process) => process.ensure_running().await,
            #[cfg(target_os = "macos")]
            Self::CoreMl(process) => process.ensure_running().await,
        }
    }
    async fn status(&self) -> &'static str {
        match self {
            Self::Llama(infer) => match infer
                .json_request("GET", "/props", &json!({}), Duration::from_secs(2))
                .await
                .ok()
                .and_then(|p| p["is_sleeping"].as_bool())
            {
                Some(true) => "sleeping",
                Some(false) => "loaded",
                None => "stopped",
            },
            #[cfg(target_os = "macos")]
            Self::CoreMl(process) => {
                if process.loaded().await {
                    "loaded"
                } else {
                    "stopped"
                }
            }
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            Self::Mlx(process) => {
                if process.loaded().await {
                    "loaded"
                } else {
                    "stopped"
                }
            }
        }
    }
    #[cfg(test)]
    fn llama(&self) -> Option<&Infer> {
        match self {
            Self::Llama(infer) => Some(infer),
            #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
            Self::Mlx(_) => None,
            #[cfg(target_os = "macos")]
            Self::CoreMl(_) => None,
        }
    }
}
struct Active {
    runtime: Runtime,
    resolved: Resolved,
    task: Task,
}

pub struct Service {
    helper: PathBuf,
    models: PathBuf,
    run: PathBuf,
    state: Mutex<State>,
}
impl Service {
    pub fn new(helper: PathBuf, models: PathBuf, run: PathBuf) -> Self {
        Self {
            helper,
            models,
            run,
            state: Mutex::new(State::default()),
        }
    }
    fn coreml_helper(&self) -> PathBuf {
        self.helper.with_file_name("axod-infer-coreml")
    }
    fn mlx_helper(&self) -> PathBuf {
        self.helper.with_file_name("axod-infer-mlx")
    }
    fn mlx_metal(&self) -> PathBuf {
        let directory = self.helper.parent().unwrap_or(Path::new(""));
        if directory.file_name().is_some_and(|name| name == "Helpers") {
            directory
                .parent()
                .unwrap()
                .join("Resources/MLX/mlx.metallib")
        } else {
            directory.join("mlx.metallib")
        }
    }

    pub fn beside_current_exe(home: &Path, run: &Path) -> Self {
        let helper = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|parent| parent.join("axod-infer")))
            .unwrap_or_default();
        Self::new(
            helper,
            home.join("Library/Application Support/Axo/models"),
            run.join("ai"),
        )
    }

    pub async fn execute(&self, request: Request, timeout_ms: u64) -> Result<Value, Error> {
        if !(1..=MAX_TIMEOUT_MS).contains(&timeout_ms) {
            return Err(Error::invalid("invalid AI deadline"));
        }
        let mut state = Operation {
            state: self.state.try_lock().map_err(|_| Error::Busy)?,
            runtime: tokio::runtime::Handle::current(),
        };
        let result = tokio::time::timeout(
            Duration::from_millis(timeout_ms),
            self.perform(request, &mut state),
        )
        .await;
        match result {
            Ok(Ok(value)) => {
                state.runtime_busy = false;
                Ok(value)
            }
            result => {
                // Dropping a client HTTP socket does not prove the backend stopped computing.
                // Retire only a process we actually started using, never another model's judge.
                if state.runtime_busy {
                    state.retire().await?;
                }
                match result {
                    Ok(Err(error)) => Err(error),
                    _ => Err(Error::failed(
                        "AI operation timed out; partial model downloads will resume on another call",
                    )),
                }
            }
        }
    }

    async fn perform(&self, request: Request, state: &mut State) -> Result<Value, Error> {
        if state.retiring.is_some() || state.runtime_busy {
            state.retire().await?;
        }
        match request {
            Request::Capabilities => self.capabilities().await,
            Request::List => self.list(state).await,
            Request::Info(selection) => {
                let info = self.inspect(&selection).await?;
                let installed = if let Some(resolved) = &info.resolved {
                    let root = self.models.clone();
                    let resolved = resolved.clone();
                    blocking(move || resolved.installed(&root)).await
                } else {
                    false
                };
                Ok(json!({"info":info,"installed":installed}))
            }
            Request::Unload(selection) => {
                if state
                    .active
                    .as_ref()
                    .is_some_and(|active| active.resolved.selection == selection)
                {
                    state.retire().await?;
                }
                Ok(json!({"model":selection.model,"status":"stopped"}))
            }
            Request::Install(selection) => {
                let resolved = self.resolve(&selection).await?;
                self.check_resources(&resolved).await?;
                let resolved = crate::transfer::install(&self.models, &resolved).await?;
                Ok(json!({"model":selection.model,"installed":true,"source":resolved.source()}))
            }
            Request::Load(selection, task) => {
                let resolved = self.resolve(&selection).await?;
                self.prepare(&resolved, task, state).await?;
                let active = state.active.as_ref().unwrap();
                if let Runtime::Llama(infer) = &active.runtime {
                    infer
                        .json_request("GET", "/slots", &json!({}), Duration::from_secs(90))
                        .await?;
                }
                let mut reply = json!({"model":selection.model,"status":"loaded","task":task,"source":active.resolved.source()});
                #[cfg(target_os = "macos")]
                if let Runtime::CoreMl(process) = &active.runtime {
                    reply["description"] = process
                        .request(&json!({"op":"describe"}), Duration::from_secs(5))
                        .await?;
                }
                if serde_json::to_vec(&reply).map_or(true, |bytes| bytes.len() > 63 * 1024) {
                    return Err(Error::unsupported(
                        "model feature description exceeds the relay budget",
                    ));
                }
                Ok(reply)
            }
            Request::Run(selection, input) => {
                let resolved = self.resolve(&selection).await?;
                if !input.images().is_empty() && !resolved.vision() {
                    return Err(Error::unsupported(
                        "This backend/selection has no supported image adapter. GGUF vision needs a compatible projector; the initial MLX adapter is text-only. No image was sent to a text-only model.",
                    ));
                }
                input.image_urls()?;
                self.prepare(&resolved, input.task(), state).await?;
                #[cfg(test)]
                if let Some(started) = &state.started {
                    started.notify_one();
                }
                let active = state.active.as_ref().unwrap();
                match &active.runtime {
                    Runtime::Llama(infer) => run(infer, &active.resolved, input).await,
                    #[cfg(target_os = "macos")]
                    Runtime::CoreMl(process) => {
                        let Input::Predict(prediction) = input else {
                            return Err(Error::unsupported(
                                "Core ML exposes named-feature predict, not chat or schema-conditioned classification",
                            ));
                        };
                        let outputs = process
                            .request(&prediction.native_request()?, Duration::from_secs(180))
                            .await?;
                        let outputs = prediction.validate_outputs(outputs)?;
                        let reply = json!({"model":selection.model,"task":"predict","outputs":outputs,"source":active.resolved.source()});
                        if serde_json::to_vec(&reply).map_or(true, |bytes| bytes.len() > 63 * 1024)
                        {
                            return Err(Error::unsupported(
                                "prediction exceeds the relay response budget; select fewer named features with input.outputs",
                            ));
                        }
                        Ok(reply)
                    }
                    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
                    Runtime::Mlx(process) => {
                        let Input::Generate {
                            text, max_tokens, ..
                        } = input
                        else {
                            return Err(Error::unsupported(
                                "this MLX adapter supports native text generation only",
                            ));
                        };
                        let result = process
                            .request(
                                &json!({"op":"generate","text":text,"maxTokens":max_tokens}),
                                Duration::from_secs(180),
                            )
                            .await?;
                        let text = result["text"]
                            .as_str()
                            .filter(|text| text.len() <= 1024 * 1024)
                            .ok_or_else(|| Error::failed("invalid native generated text"))?;
                        let finish = result["finishReason"]
                            .as_str()
                            .filter(|reason| matches!(*reason, "stop" | "length"))
                            .ok_or_else(|| Error::failed("invalid native finish reason"))?;
                        Ok(
                            json!({"model":selection.model,"task":"generate","text":text,"finishReason":finish,"source":active.resolved.source()}),
                        )
                    }
                }
            }
        }
    }

    async fn capabilities(&self) -> Result<Value, Error> {
        let helper = self.helper.clone();
        let root = self.models.clone();
        let (available, memory, free) = blocking(move || {
            let free = crate::free_disk(if root.exists() {
                &root
            } else {
                root.ancestors()
                    .find(|p| p.exists())
                    .unwrap_or(Path::new("/"))
            });
            (helper.is_file(), physical_memory(), free)
        })
        .await;
        let mlx_fallback = json!({"name":"mlx","available":false,"formats":["safetensors"],"tasks":["generate"],"recognizedArchitectures":[],
            "reason":"Native MLX needs Apple Silicon, its Axo worker and its packaged Metal resource"});
        let native = if Backend::Mlx.available()
            && self.mlx_helper().is_file()
            && self.mlx_metal().is_file()
        {
            let mut command = tokio::process::Command::new(self.mlx_helper());
            command
                .arg("--capabilities")
                .arg("--metallib")
                .arg(self.mlx_metal());
            probe_native(command, mlx_fallback).await
        } else {
            mlx_fallback
        };
        let coreml_fallback = json!({"name":"coreml","available":false,"formats":["mlmodel","mlpackage"],"tasks":["predict"],"recognizedArchitectures":[],
            "reason":"Core ML requires macOS and its embedded Axo worker; update Axo on the target Mac"});
        let coreml = if Backend::CoreMl.available() && self.coreml_helper().is_file() {
            let mut command = tokio::process::Command::new(self.coreml_helper());
            command.arg("--capabilities");
            probe_native(command, coreml_fallback).await
        } else {
            coreml_fallback
        };
        let mlx_available = native["available"] == true;
        let coreml_available = coreml["available"] == true;
        let legacy: Value =
            serde_json::from_str(RUNTIME).expect("generated runtime inventory is JSON");
        let llama = json!({
            "name":"llama.cpp", "available":available, "commit":legacy["commit"], "build":legacy["build"],
            "recognizedArchitectures":legacy["recognizedArchitectures"], "formats":["gguf"],
            "tasks":["generate","classify","embed"], "inputs":["text","image","json"], "contextTokens":8192, "kvCache":true,
            "reason":"Task heads, quantization and projectors are validated by the pinned runtime when loaded."
        });
        let mut formats = vec!["gguf"];
        let mut backends = vec!["llama.cpp"];
        if mlx_available {
            formats.extend(["safetensors", "mlx"]);
            backends.push("mlx");
        }
        if coreml_available {
            formats.extend(["coreml", "mlmodel", "mlpackage"]);
            backends.push("coreml");
        }
        Ok(json!({
            "apiVersion":4,"available":available || mlx_available || coreml_available,"runtime":legacy,
            "formats":formats,"tasks":["generate","classify","embed","predict"],"runtimes":[llama,native,coreml],
            "inputs":{"generate":["text","image"],"classify":["json","text","image"],"embed":["text"],"predict":["features","image"]},
            "architectureCheck":"recognizedArchitectures comes from the pinned runtime source. Recognition is not a load guarantee: tensor versions, quantization, projectors and task heads are finally checked by the runtime.",
            "modelSource":"hf:owner/repo[:quant][@revision]","selection":"backend disambiguates runtimes; file selects a model shard or Core ML package; GGUF projector/quant selectors do not apply to native bundles",
            "customCode":false,"privateRepositories":false,"backends":backends,
            "limits":{"physicalMemoryBytes":memory,"maxModelBytes":memory.saturating_mul(3)/5,"freeDiskBytes":free,
                "maxDownloadBytes":catalog::MAX_DOWNLOAD_BYTES,"maxArtifacts":catalog::MAX_FILES,"maxImages":4,"maxImageBytes":8*1024*1024,
                "maxTotalImageBytes":16*1024*1024,"maxTextBytes":32768,"contextTokens":8192,"maxOutputTokens":4096,"maxOperationMs":MAX_TIMEOUT_MS,"concurrentOperations":1},
            "unsupported":["Core ML supports bounded stateless named-feature predict, not generation, mutable state, custom classes/layers/operators, linked models or downloaded compiled binaries", "MLX currently implements dense Qwen2/Qwen3 text generation, not arbitrary safetensors architectures, embeddings or vision", "custom decision heads need a reviewed task adapter, never automatically imported HF Python", "audio/video inputs are not exposed by these adapters"]
        }))
    }

    async fn inspect(&self, selection: &Selection) -> Result<Inspection, Error> {
        let root = self.models.clone();
        let key = selection.clone();
        if let Some(resolved) = blocking(move || catalog::cached(&root, &key)).await? {
            return Ok(Inspection::from_resolved(resolved));
        }
        catalog::inspect_repository(
            &self.models,
            selection,
            crate::transfer::metadata(&self.models, selection).await?,
        )
        .await
    }
    async fn resolve(&self, selection: &Selection) -> Result<Resolved, Error> {
        let info = self.inspect(selection).await?;
        info.resolved
            .ok_or_else(|| Error::unsupported(info.compatibility.reasons.join(" ")))
    }
    async fn check_resources(&self, resolved: &Resolved) -> Result<(), Error> {
        let helper = match resolved.backend {
            Backend::Mlx => self.mlx_helper(),
            Backend::CoreMl => self.coreml_helper(),
            Backend::Llama => self.helper.clone(),
        };
        let metal = self.mlx_metal();
        let backend = resolved.backend;
        let bytes = resolved.download_bytes();
        let models = self.models.clone();
        blocking(move || {
            if !backend.available() { return Err(Error::unavailable("selected native backend is not compiled for this host platform")); }
            if !helper.is_file() || (backend == Backend::Mlx && !metal.is_file()) { return Err(Error::unavailable("local inference helper or Metal resource missing; update Axo on this Mac")); }
            if backend == Backend::CoreMl {
                let disk = models.ancestors().find(|path| path.exists()).unwrap_or(Path::new("/"));
                if crate::free_disk(disk) < bytes.saturating_mul(3).saturating_add(512 * 1024 * 1024) {
                    return Err(Error::unavailable("Core ML needs room for verified sources, compilation/staging copies and a 512 MiB disk reserve"));
                }
            }
            if bytes > physical_memory().saturating_mul(3)/5 { return Err(Error::unavailable("selected artifacts exceed this host's 60% RAM admission budget; choose a smaller quantization/model or a larger host")); }
            Ok(())
        }).await
    }
    async fn prepare(
        &self,
        resolved: &Resolved,
        task: Task,
        state: &mut State,
    ) -> Result<(), Error> {
        if resolved.backend == Backend::Mlx && task != Task::Generate {
            return Err(Error::unsupported(
                "this native MLX architecture adapter implements text generation only; embeddings and decision heads need their own native adapters",
            ));
        }
        if (resolved.backend == Backend::CoreMl) != (task == Task::Predict) {
            return Err(Error::unsupported(
                "named-feature predict currently requires Core ML; Core ML requires task: predict rather than a text/decision adapter",
            ));
        }
        self.check_resources(resolved).await?;
        let installed = crate::transfer::install(&self.models, resolved).await?;
        let resolved = &installed;
        if state
            .active
            .as_ref()
            .is_none_or(|active| active.resolved != *resolved || active.task != task)
        {
            state.retire().await?;
            let projector = resolved
                .files
                .iter()
                .find(|file| file.role == Role::Projector)
                .map(|file| PathBuf::from(file.path.as_str()));
            let runtime = match resolved.backend {
                Backend::CoreMl => {
                    #[cfg(target_os = "macos")]
                    {
                        Runtime::CoreMl(crate::native_process::Process::new(
                            self.coreml_helper(),
                            crate::native_process::Kind::CoreMl,
                            resolved.directory(&self.models).join(resolved.entrypoint()),
                            self.run.clone(),
                        ))
                    }
                    #[cfg(not(target_os = "macos"))]
                    {
                        return Err(Error::unavailable("native Core ML requires macOS"));
                    }
                }
                Backend::Llama => Runtime::Llama(Infer::for_model(
                    self.helper.clone(),
                    resolved.directory(&self.models),
                    self.run.clone(),
                    resolved.files[0].path.as_str().into(),
                    projector,
                    task == Task::Embed,
                )),
                Backend::Mlx => {
                    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
                    {
                        Runtime::Mlx(crate::native_process::Process::new(
                            self.mlx_helper(),
                            crate::native_process::Kind::Mlx {
                                metal: self.mlx_metal(),
                            },
                            resolved.directory(&self.models).join(
                                Path::new(resolved.files[0].path.as_str())
                                    .parent()
                                    .unwrap_or(Path::new("")),
                            ),
                            self.run.clone(),
                        ))
                    }
                    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
                    {
                        return Err(Error::unavailable(
                            "native MLX is not compiled for this platform",
                        ));
                    }
                }
            };
            state.active = Some(Active {
                runtime,
                resolved: resolved.clone(),
                task,
            });
        }
        state.runtime_busy = true;
        state
            .active
            .as_mut()
            .unwrap()
            .runtime
            .ensure_running()
            .await
    }
    async fn list(&self, state: &State) -> Result<Value, Error> {
        let root = self.models.clone();
        let mut entries = blocking(move || {
            let directory = root.join("hf");
            let folders = match std::fs::read_dir(directory) { Ok(entries) => entries, Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()), Err(_) => return Err(Error::failed("could not list model cache")) };
            let mut entries = Vec::new();
            for (index, folder) in folders.take(1025).enumerate() {
                if index == 1024 { return Err(Error::failed("model cache has too many entries to inventory safely")); }
                if entries.len() == 256 { return Err(Error::failed("model cache exceeds the 256-model inventory limit")); }
                let folder = folder.map_err(|_| Error::failed("could not list model directory"))?;
                let manifest = folder.path().join("resolved.json");
                if !manifest.is_file() { continue; }
                let mut bytes = Vec::new();
                std::fs::File::open(manifest).map_err(|_| Error::failed("could not open model cache"))?.take(256*1024+1).read_to_end(&mut bytes).map_err(|_| Error::failed("could not read model cache"))?;
                if bytes.len() > 256*1024 { return Err(Error::failed("model cache manifest is too large")); }
                let resolved: Resolved = serde_json::from_slice(&bytes).map_err(|_| Error::invalid("invalid model cache manifest"))?;
                resolved.validate()?;
                if resolved.manifest(&root).parent() != Some(folder.path().as_path()) { return Err(Error::invalid("model manifest path does not match its selection")); }
                entries.push(json!({"model":resolved.selection.model,"selection":resolved.selection,"installed":resolved.installed(&root),"status":"stopped","source":resolved.source(),"downloadBytes":resolved.download_bytes()}));
            }
            Ok::<_, Error>(entries)
        }).await?;
        if let Some(active) = &state.active {
            let status = active.runtime.status().await;
            for entry in &mut entries {
                if entry["selection"] == serde_json::to_value(&active.resolved.selection).unwrap() {
                    entry["status"] = json!(status);
                }
            }
        }
        entries.sort_by(|a, b| a["model"].as_str().cmp(&b["model"].as_str()));
        Ok(json!({"models":entries}))
    }
}

async fn probe_native(mut command: tokio::process::Command, fallback: Value) -> Value {
    let output = tokio::time::timeout(
        Duration::from_secs(3),
        command
            .env_remove("AXO_INFER_LIFELINE_STDIN")
            .kill_on_drop(true)
            .output(),
    )
    .await;
    if let Ok(Ok(output)) = output {
        if output.status.success() && output.stdout.len() <= 65536 {
            if let Ok(value) = serde_json::from_slice::<Value>(&output.stdout) {
                if value["name"] == fallback["name"] && value["available"].is_boolean() {
                    return value;
                }
            }
        }
    }
    fallback
}

async fn run(infer: &Infer, resolved: &Resolved, input: Input) -> Result<Value, Error> {
    let model = &resolved.selection.model;
    let source = resolved.source();
    match input {
        Input::Predict(_) => Err(Error::unsupported(
            "llama.cpp has no named-feature predict adapter",
        )),
        Input::Generate {
            text,
            images,
            max_tokens,
        } => {
            let mut content = vec![json!({"type":"text","text":text})];
            for image in images {
                if let crate::api::Image::Data(url) = image {
                    content.push(json!({"type":"image_url","image_url":{"url":url}}));
                }
            }
            let reply = infer.json_request("POST", "/v1/chat/completions", &json!({"messages":[{"role":"user","content":content}],"max_tokens":max_tokens,"stream":false}),Duration::from_secs(180)).await?;
            let text = reply["choices"][0]["message"]["content"]
                .as_str()
                .ok_or_else(|| Error::failed("runtime returned no generated text"))?;
            let finish = reply["choices"][0]["finish_reason"]
                .as_str()
                .filter(|reason| matches!(*reason, "stop" | "length"))
                .ok_or_else(|| Error::failed("runtime returned no supported finish reason"))?;
            Ok(
                json!({"model":model,"task":"generate","text":text,"finishReason":finish,"source":source}),
            )
        }
        Input::Embed { text } => {
            let reply = infer
                .json_request(
                    "POST",
                    "/v1/embeddings",
                    &json!({"input":text,"encoding_format":"float"}),
                    Duration::from_secs(180),
                )
                .await?;
            let embedding = reply["data"][0]["embedding"]
                .as_array()
                .filter(|values| {
                    !values.is_empty()
                        && values.len() <= 65536
                        && values
                            .iter()
                            .all(|n| n.as_f64().is_some_and(f64::is_finite))
                })
                .ok_or_else(|| Error::failed("runtime returned an invalid embedding"))?;
            Ok(json!({"model":model,"task":"embed","embedding":embedding,"source":source}))
        }
        Input::Classify {
            state,
            images,
            questions,
        } => {
            let images: Vec<_> = images
                .into_iter()
                .filter_map(|image| {
                    if let crate::api::Image::Data(url) = image {
                        Some(url)
                    } else {
                        None
                    }
                })
                .collect();
            let reply = infer
                .json_request(
                    "POST",
                    "/v1/systemone",
                    &json!({"state":state,"images":images,"questions":questions}),
                    Duration::from_secs(180),
                )
                .await?;
            let answers = answers(&reply["answers"], &questions)?;
            Ok(json!({"model":model,"task":"classify","answers":answers,"source":source}))
        }
    }
}
fn probability(value: &Value) -> bool {
    value.as_f64().is_some_and(|p| (0.0..=1.0).contains(&p))
}
fn distribution(value: &Value, keys: impl Iterator<Item = String>) -> bool {
    let keys: Vec<_> = keys.collect();
    value.as_object().is_some_and(|ps| {
        ps.len() == keys.len()
            && keys.iter().all(|key| probability(&ps[key]))
            && (ps.values().filter_map(Value::as_f64).sum::<f64>() - 1.0).abs() < 0.001
    })
}
fn answers(value: &Value, questions: &BTreeMap<String, Question>) -> Result<Value, Error> {
    let answers = value
        .as_object()
        .filter(|answers| answers.len() == questions.len())
        .ok_or_else(|| Error::failed("runtime returned invalid classifier answers"))?;
    for (id, question) in questions {
        let answer = answers
            .get(id)
            .ok_or_else(|| Error::failed("runtime omitted a classifier answer"))?;
        let valid = match question {
            Question::Noul { .. } => answer["type"] == "noul" && probability(&answer["noul"]),
            Question::Choice { criteria, .. } => {
                answer["type"] == "choice"
                    && answer["choice"]
                        .as_str()
                        .is_some_and(|id| criteria.contains_key(id))
                    && distribution(&answer["probabilities"], criteria.keys().cloned())
            }
            Question::Score { criteria, .. } => {
                answer["type"] == "score"
                    && answer["score"].as_f64().is_some_and(|score| {
                        score.is_finite() && score >= 0.0 && score <= (criteria.len() - 1) as f64
                    })
                    && distribution(
                        &answer["probabilities"],
                        (0..criteria.len()).map(|n| n.to_string()),
                    )
            }
        };
        if !valid
            || answer
                .get("confidence")
                .is_some_and(|confidence| !probability(confidence))
        {
            return Err(Error::failed("runtime returned invalid classifier values"));
        }
    }
    Ok(Value::Object(answers.clone()))
}

impl Infer {
    async fn json_request(
        &self,
        method: &str,
        path: &str,
        request: &Value,
        timeout: Duration,
    ) -> Result<Value, Error> {
        let body =
            serde_json::to_vec(request).map_err(|_| Error::invalid("invalid model input"))?;
        let reply = http(&self.socket(), method, path, &body, timeout)
            .await
            .map_err(|_| Error::failed("local runtime did not answer"))?;
        if reply.status != 200 {
            return Err(Error::unsupported(format!(
                "runtime rejected the selected model/task/input (HTTP {}); check ai.info, task, projector and context length. Models with specialized heads cannot be used as generic chat models.",
                reply.status
            )));
        }
        serde_json::from_slice(&reply.body)
            .map_err(|_| Error::failed("runtime returned invalid JSON"))
    }
    pub(super) async fn stop(&self) {
        let child = self.lock_children().side_car.take();
        if let Some(mut side_car) = child {
            // SAFETY: this unreaped pid is our guard; SIGTERM runs its model-killing trap.
            unsafe {
                libc::kill(side_car.child.id() as i32, libc::SIGTERM);
            }
            let _ = side_car.child.wait().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ModelRef;
    #[tokio::test]
    async fn capabilities_and_inventory_are_model_independent_and_do_not_install() {
        let root = crate::tests::run_directory();
        let service = Service::new(root.join("absent"), root.join("models"), root.join("run"));
        let capabilities = service.execute(Request::Capabilities, 1000).await.unwrap();
        assert_eq!(capabilities["formats"], json!(["gguf"]));
        assert!(
            capabilities["runtime"]["recognizedArchitectures"]
                .as_array()
                .unwrap()
                .contains(&json!("clef"))
        );
        assert_eq!(
            service.execute(Request::List, 1000).await.unwrap(),
            json!({"models":[]})
        );
        assert!(!root.join("models").exists());
        let _held = service.state.lock().await;
        assert!(matches!(
            service.execute(Request::List, 1000).await,
            Err(Error::Busy)
        ));
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    #[ignore = "requires public HF access and the packaged native MLX worker"]
    async fn real_mlx_service_installs_runs_reuses_retires_and_recovers() {
        use std::os::unix::fs::symlink;
        let root = crate::tests::run_directory();
        let helper = std::fs::canonicalize(std::env::var("AXO_TEST_MLX_HELPER").unwrap()).unwrap();
        let metal = std::fs::canonicalize(std::env::var("AXO_TEST_MLX_METALLIB").unwrap()).unwrap();
        symlink(helper, root.join("axod-infer-mlx")).unwrap();
        symlink(metal, root.join("mlx.metallib")).unwrap();
        let models = PathBuf::from(
            std::env::var("AXO_TEST_MLX_CACHE")
                .unwrap_or_else(|_| "/tmp/axo-native-mlx-models".into()),
        );
        let service = Service::new(root.join("axod-infer"), models, root.join("run"));
        let model = "hf:mlx-community/Qwen3-0.6B-4bit@73e3e38d981303bc594367cd910ea6eb48349da8";
        let request = |value| Request::parse(value).unwrap();
        let info = service
            .execute(request(json!({"op":"info","model":model})), 240000)
            .await
            .unwrap();
        assert_eq!(info["info"]["compatibility"]["status"], "candidate");
        assert_eq!(info["info"]["resolved"]["backend"], "mlx");
        let first = service.execute(request(json!({"op":"run","model":model,"input":"What is 2 + 2? Answer briefly.","maxTokens":32})), 240000).await.unwrap();
        assert_eq!(first["source"]["backend"], "mlx");
        assert!(first["text"].as_str().is_some_and(|text| !text.is_empty()));
        assert!(
            first["source"]["files"]
                .as_array()
                .unwrap()
                .iter()
                .all(|file| file["sha256"].as_str().is_some_and(|hash| hash.len() == 64))
        );
        let native_pid = |state: &State| match &state.active.as_ref().unwrap().runtime {
            Runtime::Mlx(process) => process.pid().unwrap(),
            _ => panic!("expected native residency"),
        };
        let pid = native_pid(&*service.state.lock().await);
        service
            .execute(
                request(json!({"op":"run","model":model,"input":"Say hello.","maxTokens":8})),
                240000,
            )
            .await
            .unwrap();
        assert_eq!(native_pid(&*service.state.lock().await), pid);
        assert!(
            service
                .execute(
                    request(json!({"op":"load","model":model,"task":"embed"})),
                    240000
                )
                .await
                .is_err()
        );
        assert_eq!(
            native_pid(&*service.state.lock().await),
            pid,
            "unsupported task must not unload the resident"
        );
        let expired = service.execute(request(json!({"op":"run","model":model,"input":"Count every integer from 1 to 1000, writing every number individually.","maxTokens":4096})), 100).await;
        assert!(
            expired.is_err(),
            "long native generation should hit this short deadline"
        );
        assert!(
            service.state.lock().await.active.is_none(),
            "native worker must be reaped before admission reopens"
        );
        let recovered = service
            .execute(
                request(json!({"op":"run","model":model,"input":"Say hello.","maxTokens":8})),
                240000,
            )
            .await
            .unwrap();
        assert!(!recovered["text"].as_str().unwrap().is_empty());
        assert_ne!(native_pid(&*service.state.lock().await), pid);
        let started = std::sync::Arc::new(tokio::sync::Notify::new());
        service.state.lock().await.started = Some(started.clone());
        let mut pending = Box::pin(service.execute(request(json!({"op":"run","model":model,"input":"Count every integer from 1 to 1000 individually.","maxTokens":4096})), 240000));
        tokio::select! {
            biased;
            _ = started.notified() => {},
            outcome = &mut pending => panic!("request completed before cancellation boundary: {outcome:?}"),
        }
        drop(pending);
        assert!(
            service.state.lock().await.retiring.is_some(),
            "dropping a future must retain cleanup ownership"
        );
        service.execute(Request::List, 10000).await.unwrap();
        assert!(service.state.lock().await.active.is_none());
        service.state.lock().await.started = None;
        service
            .execute(
                request(json!({"op":"run","model":model,"input":"Say hello.","maxTokens":8})),
                240000,
            )
            .await
            .unwrap();
        service
            .execute(request(json!({"op":"unload","model":model})), 240000)
            .await
            .unwrap();
        assert!(service.state.lock().await.active.is_none());
        // Owner disappearance must end a fully initialized native worker without cooperative
        // model cancellation or a shell descendant. Closing this pipe models owner death.
        let selection: Selection = serde_json::from_value(json!({"model":model})).unwrap();
        let resolved = catalog::cached(&service.models, &selection)
            .unwrap()
            .unwrap();
        let socket = root.join("run/owner-eof.sock");
        struct ChildGuard(std::process::Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut child = ChildGuard(
            std::process::Command::new(root.join("axod-infer-mlx"))
                .arg("--model")
                .arg(resolved.directory(&service.models))
                .arg("--metallib")
                .arg(root.join("mlx.metallib"))
                .arg("--socket")
                .arg(&socket)
                .env("AXO_INFER_LIFELINE_STDIN", "1")
                .env("TOKENIZERS_PARALLELISM", "false")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap(),
        );
        let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
        while !socket.exists() {
            assert!(
                child.0.try_wait().unwrap().is_none(),
                "owner-watch worker failed before initialization"
            );
            assert!(
                tokio::time::Instant::now() < deadline,
                "owner-watch worker startup timed out"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        drop(child.0.stdin.take());
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "native worker outlived its owner"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn failed_retirement_never_reopens_inference_admission() {
        let root = crate::tests::run_directory();
        let service = Service::new(root.join("helper"), root.join("models"), root.join("run"));
        service.state.lock().await.retiring = Some(Retirement::Running(tokio::spawn(async {
            panic!("injected cleanup failure")
        })));
        for _ in 0..2 {
            assert!(service.execute(Request::List, 10000).await.is_err());
            assert!(matches!(
                service.state.lock().await.retiring,
                Some(Retirement::Failed)
            ));
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    const FAKE: &str = r#"#!/usr/bin/python3
import json, socket, sys
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[sys.argv.index('--host') + 1])
server.listen(8)
while True:
    client, _ = server.accept()
    try:
        raw = b''
        while b'\r\n\r\n' not in raw:
            part = client.recv(65536)
            if not part: break
            raw += part
        if b'\r\n\r\n' not in raw:
            client.close()
            continue
        head, body = raw.split(b'\r\n\r\n', 1)
        length = int(next(line.split(b':',1)[1] for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:')))
        while len(body) < length: body += client.recv(65536)
        path = head.split(b' ')[1]
        request = json.loads(body or b'{}')
        reply = {'is_sleeping':False}
        if path == b'/v1/chat/completions':
            assert request['messages'][0]['content'][0]['type'] == 'text'
            reply = {'choices':[{'message':{'content':'generated'},'finish_reason':'stop'}]}
        elif path == b'/v1/embeddings':
            assert '--embeddings' in sys.argv
            reply = {'data':[{'embedding':[0.25,-0.5]}]}
        elif path == b'/v1/systemone':
            assert request['images'][0].startswith('data:image/png;base64,')
            reply = {'answers':{'q':{'type':'noul','noul':0.9}}}
        payload = json.dumps(reply).encode()
        client.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(payload)).encode()+b'\r\nConnection: close\r\n\r\n'+payload)
    except OSError:
        pass
    client.close()
"#;

    #[tokio::test]
    async fn arbitrary_cached_models_execute_all_adapters_and_switch_safely() {
        use std::os::unix::fs::PermissionsExt;
        let root = crate::tests::run_directory();
        let helper = root.join("helper");
        std::fs::write(&helper, FAKE).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
        let service = Service::new(helper, root.join("models"), root.join("run"));
        for model in ["hf:any/one", "hf:another/two"] {
            let selection = Selection {
                backend: None,
                model: ModelRef::parse(model.into()).unwrap(),
                file: None,
                projector: None,
            };
            let metadata = json!({"sha":"a".repeat(40),"siblings":[
                {"rfilename":"model.gguf","size":8,"lfs":{"sha256":"b".repeat(64),"size":8}},
                {"rfilename":"mmproj.gguf","size":8,"lfs":{"sha256":"c".repeat(64),"size":8}}
            ]});
            let resolved = catalog::inspect(&selection, metadata)
                .unwrap()
                .resolved
                .unwrap();
            let directory = resolved.directory(&service.models);
            std::fs::create_dir_all(&directory).unwrap();
            for file in &resolved.files {
                std::fs::write(directory.join(file.path.as_str()), b"fixture!").unwrap();
            }
            std::fs::write(
                resolved.manifest(&service.models),
                serde_json::to_vec(&resolved).unwrap(),
            )
            .unwrap();
        }
        let request = |value| Request::parse(value).unwrap();
        let first = service
            .execute(
                request(json!({"op":"run","model":"hf:any/one","input":"hello"})),
                10000,
            )
            .await
            .unwrap();
        assert_eq!(first["text"], "generated");
        let pid = service
            .state
            .lock()
            .await
            .active
            .as_ref()
            .unwrap()
            .runtime
            .llama()
            .unwrap()
            .lock_children()
            .side_car
            .as_ref()
            .unwrap()
            .child
            .id();
        service
            .execute(
                request(json!({"op":"run","model":"hf:any/one","input":"again"})),
                10000,
            )
            .await
            .unwrap();
        assert_eq!(
            service
                .state
                .lock()
                .await
                .active
                .as_ref()
                .unwrap()
                .runtime
                .llama()
                .unwrap()
                .lock_children()
                .side_car
                .as_ref()
                .unwrap()
                .child
                .id(),
            pid
        );
        let embedded = service
            .execute(
                request(
                    json!({"op":"run","model":"hf:another/two","task":"embed","input":"hello"}),
                ),
                10000,
            )
            .await
            .unwrap();
        assert_eq!(embedded["embedding"], json!([0.25, -0.5]));
        // SAFETY: signal 0 only checks this test's reaped guard pid.
        assert_ne!(
            unsafe { libc::kill(pid as i32, 0) },
            0,
            "switching retires the old process"
        );
        service
            .execute(request(json!({"op":"unload","model":"hf:any/one"})), 1000)
            .await
            .unwrap();
        assert!(
            service.state.lock().await.active.is_some(),
            "unloading another selection must not touch the current model"
        );
        let classified = service.execute(request(json!({"op":"run","model":"hf:any/one","task":"classify","input":{"state":"inspect","images":["data:image/png;base64,aGk="],"questions":{"q":{"type":"noul","instructions":"image?"}}}})),10000).await.unwrap();
        assert_eq!(classified["answers"]["q"]["noul"], 0.9);
        service
            .execute(request(json!({"op":"unload","model":"hf:any/one"})), 5000)
            .await
            .unwrap();
        assert!(service.state.lock().await.active.is_none());
        assert_eq!(
            service.execute(Request::List, 1000).await.unwrap()["models"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(
            !root.join("infer.sock").exists(),
            "safety judge's socket is separate"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn malformed_answers_are_not_successful_inference() {
        let questions = BTreeMap::from([(
            "q".into(),
            Question::Noul {
                instructions: "safe?".into(),
            },
        )]);
        assert!(answers(&json!({"q":{"type":"noul","noul":0.8}}), &questions).is_ok());
        assert!(answers(&json!({"q":{"type":"noul","noul":2}}), &questions).is_err());
        assert!(answers(&json!({}), &questions).is_err());
        assert!(ModelRef::parse("hf:mlx-community/clef-omni-4bit".into()).is_ok());
    }
}
