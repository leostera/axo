//! Local inference orchestration: inspect HF metadata, pin artifacts, install, load, execute.
//! Task adapters belong to Axo; model repositories can supply data, never executable code.
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::Mutex;

pub use crate::api::Request;
use crate::api::{Input, Question, Selection, Task};
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
}
struct Active {
    infer: Infer,
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
        let mut state = self.state.try_lock().map_err(|_| Error::Busy)?;
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
                    if let Some(active) = state.active.take() {
                        active.infer.stop().await;
                    }
                    state.runtime_busy = false;
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
                    if let Some(active) = state.active.take() {
                        active.infer.stop().await;
                    }
                }
                Ok(json!({"model":selection.model,"status":"stopped"}))
            }
            Request::Install(selection) => {
                let resolved = self.resolve(&selection).await?;
                self.check_resources(&resolved).await?;
                crate::transfer::install(&self.models, &resolved).await?;
                Ok(json!({"model":selection.model,"installed":true,"source":resolved.source()}))
            }
            Request::Load(selection, task) => {
                let resolved = self.resolve(&selection).await?;
                self.prepare(&resolved, task, state).await?;
                state
                    .active
                    .as_ref()
                    .unwrap()
                    .infer
                    .json_request("GET", "/slots", &json!({}), Duration::from_secs(90))
                    .await?;
                Ok(
                    json!({"model":selection.model,"status":"loaded","task":task,"source":resolved.source()}),
                )
            }
            Request::Run(selection, input) => {
                let resolved = self.resolve(&selection).await?;
                if !input.images().is_empty() && !resolved.vision() {
                    return Err(Error::unsupported(
                        "This selection has no vision projector. Inspect the repository with ai.info and select a compatible GGUF projector; no image was sent to a text-only model.",
                    ));
                }
                input.image_urls()?;
                self.prepare(&resolved, input.task(), state).await?;
                let infer = &state.active.as_ref().unwrap().infer;
                run(infer, &resolved, input).await
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
        Ok(json!({
            "apiVersion":2,"available":available,"runtime":serde_json::from_str::<Value>(RUNTIME).expect("generated runtime inventory is JSON"),
            "formats":["gguf"],"tasks":["generate","classify","embed"],
            "inputs":{"generate":["text","image"],"classify":["json","text","image"],"embed":["text"]},
            "architectureCheck":"recognizedArchitectures comes from the pinned runtime source. Recognition is not a load guarantee: tensor versions, quantization, projectors and task heads are finally checked by the runtime.",
            "modelSource":"hf:owner/repo[:quant][@revision]","selection":"file and projector select exact GGUF artifacts when metadata is ambiguous; split models need every checksummed shard",
            "customCode":false,"privateRepositories":false,"backends":["llama.cpp"],
            "limits":{"physicalMemoryBytes":memory,"maxModelBytes":memory.saturating_mul(3)/5,"freeDiskBytes":free,
                "maxDownloadBytes":catalog::MAX_DOWNLOAD_BYTES,"maxArtifacts":catalog::MAX_FILES,"maxImages":4,"maxImageBytes":8*1024*1024,
                "maxTotalImageBytes":16*1024*1024,"maxTextBytes":32768,"contextTokens":8192,"maxOutputTokens":4096,"maxOperationMs":MAX_TIMEOUT_MS,"concurrentOperations":1},
            "unsupported":["MLX and raw safetensors/PyTorch weights need another backend", "custom decision heads need a reviewed task adapter, never automatically imported HF Python", "audio/video inputs are not exposed by these adapters"]
        }))
    }

    async fn inspect(&self, selection: &Selection) -> Result<Inspection, Error> {
        let root = self.models.clone();
        let key = selection.clone();
        if let Some(resolved) = blocking(move || catalog::cached(&root, &key)).await? {
            return Ok(Inspection::from_resolved(resolved));
        }
        catalog::inspect(
            selection,
            crate::transfer::metadata(&self.models, selection).await?,
        )
    }
    async fn resolve(&self, selection: &Selection) -> Result<Resolved, Error> {
        let info = self.inspect(selection).await?;
        info.resolved
            .ok_or_else(|| Error::unsupported(info.compatibility.reasons.join(" ")))
    }
    async fn check_resources(&self, resolved: &Resolved) -> Result<(), Error> {
        let helper = self.helper.clone();
        let bytes = resolved.download_bytes();
        blocking(move || {
            if !helper.is_file() { return Err(Error::unavailable("local inference helper missing; update Axo on this Mac")); }
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
        self.check_resources(resolved).await?;
        crate::transfer::install(&self.models, resolved).await?;
        if state
            .active
            .as_ref()
            .is_none_or(|active| active.resolved != *resolved || active.task != task)
        {
            if let Some(active) = state.active.take() {
                active.infer.stop().await;
            }
            let projector = resolved
                .files
                .iter()
                .find(|file| file.role == Role::Projector)
                .map(|file| PathBuf::from(file.path.as_str()));
            let infer = Infer::for_model(
                self.helper.clone(),
                resolved.directory(&self.models),
                self.run.clone(),
                resolved.files[0].path.as_str().into(),
                projector,
                task == Task::Embed,
            );
            state.active = Some(Active {
                infer,
                resolved: resolved.clone(),
                task,
            });
        }
        state.runtime_busy = true;
        state.active.as_ref().unwrap().infer.ensure_running().await.map_err(|_| Error::unsupported(format!("The pinned llama.cpp runtime could not load this selection (architecture: {}). Artifact metadata does not guarantee a supported tensor layout/task head; inspect this Mac's ai/infer.log. No repository code was executed.",resolved.architecture.as_deref().unwrap_or("unknown"))))
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
            let status = match active
                .infer
                .json_request("GET", "/props", &json!({}), Duration::from_secs(2))
                .await
                .ok()
                .and_then(|p| p["is_sleeping"].as_bool())
            {
                Some(true) => "sleeping",
                Some(false) => "loaded",
                None => "stopped",
            };
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

async fn run(infer: &Infer, resolved: &Resolved, input: Input) -> Result<Value, Error> {
    let model = &resolved.selection.model;
    let source = resolved.source();
    match input {
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
            .infer
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
                .infer
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
