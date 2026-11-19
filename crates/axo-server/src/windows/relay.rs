//! Adapt the Windows/Codex catalog to the same relay worker used on macOS.
//! pi/3 is the relay's existing conversation interchange format. These files are
//! projections of completed Codex messages, never a second agent or source of truth.
use super::*;
mod adapters;
mod remote;
use axo_protocol::commands::{CommandId, StopTarget};
use axo_protocol::{Event, LayoutNode, RemoteSessionSnapshot, SessionRecord, ShellId};
use axo_relay::{
    AccountLink, ClientDelivery, Eviction, HostFuture, HostIdentity, HostLink, HostLinkStore,
    ModelChoice, PendingRedemption, PiKey, RelayHost, RemoteAnswer, SessionMetadata,
    StoredMetadata, SyncCursor, SyncSession, SyncStore,
};
use std::sync::Weak;
use std::time::Duration;

#[derive(Clone)]
pub(super) struct Host {
    backend: Weak<Backend>,
    identity: HostIdentity,
    prompt_lock: Arc<Mutex<()>>,
    prompts: Arc<std::sync::atomic::AtomicUsize>,
    assets: Arc<Mutex<Option<axo_relay::assets::AssetSource>>>,
}
pub(super) struct Relay {
    pub host: Arc<Host>,
    pub credentials: Arc<super::credentials::Credentials>,
    pub endpoint: axo_relay::RelayEndpoint,
    pub control: Arc<axo_relay::RelayControl>,
    worker: Mutex<Option<axo_relay::RelayWorker>>,
    pub link_lock: Mutex<()>,
}
impl Host {
    /// Win32 and SQLite work never blocks the relay's async workers.
    fn run_blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce(Self) -> io::Result<T> + Send + 'static,
    ) -> HostFuture<'static, io::Result<T>> {
        let host = self.clone();
        Box::pin(async move {
            tokio::task::spawn_blocking(move || work(host))
                .await
                .map_err(io::Error::other)?
        })
    }

    fn backend(&self) -> io::Result<Arc<Backend>> {
        self.backend
            .upgrade()
            .ok_or_else(|| io::Error::other("Daemon is stopping"))
    }
    fn call(&self, method: &str, params: Value) -> io::Result<Value> {
        self.backend()?
            .dispatch(method, params)
            .map_err(|e| io::Error::other(e.message))
    }
    fn snapshot(&self, value: Value, at: &str) -> io::Result<RemoteSessionSnapshot> {
        let record: SessionRecord = serde_json::from_value(value)?;
        let mut result = RemoteSessionSnapshot::from_record(&record, &self.identity.host_id, at);
        result.has_agent = true;
        Ok(result)
    }
}
impl Relay {
    pub fn start(backend: &Arc<Backend>, endpoint: axo_relay::RelayEndpoint) -> io::Result<Self> {
        let id = axo_store::load_or_create_host_id(&backend.database.lock().unwrap())?;
        let host = Arc::new(Host {
            backend: Arc::downgrade(backend),
            identity: HostIdentity {
                host_id: id,
                host_generation: axo_protocol::new_uuid_v4()?,
            },
            prompt_lock: Arc::new(Mutex::new(())),
            prompts: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            assets: Arc::new(Mutex::new(None)),
        });
        let credentials = Arc::new(super::credentials::Credentials(
            backend.directory.join("credentials"),
        ));
        let worker = axo_relay::RelayWorker::start(
            axo_relay::RelayDependencies {
                host: host.clone(),
                sync: host.clone(),
                endpoint: endpoint.clone(),
                links: host.clone(),
                credentials: credentials.clone(),
                peers: None,
                assets_directory: Some(backend.directory.join("assets")),
            },
            tokio::runtime::Handle::current(),
            axo_ipc::Stop::default(),
        )?;
        let control = worker.control_handle();
        Ok(Self {
            host,
            credentials,
            endpoint,
            control,
            worker: Mutex::new(Some(worker)),
            link_lock: Mutex::new(()),
        })
    }
    pub async fn shutdown(&self) {
        let worker = self.worker.lock().unwrap().take();
        if let Some(mut worker) = worker {
            worker.shutdown().await;
        }
    }
}
impl Host {
    fn read_link(&self) -> io::Result<HostLink> {
        let b = self.backend()?;
        let stored = axo_store::load_host_link(&b.database.lock().unwrap())?;
        HostLink::new(
            stored
                .account
                .map(|s| AccountLink::parse(s.account_id, s.credential_id))
                .transpose()?,
            stored
                .pending_redemption
                .map(|s| PendingRedemption::parse(s.credential_id, s.host_generation))
                .transpose()?,
        )
        .and_then(|link| {
            let retired = stored
                .retired
                .into_iter()
                .map(|item| AccountLink::parse(item.account_id, item.credential_id))
                .collect::<io::Result<Vec<_>>>()?;
            Ok(link.with_retired(retired))
        })
    }
    fn persist_link(&self, link: &HostLink) -> io::Result<()> {
        let b = self.backend()?;
        axo_store::store_host_link(
            &b.database.lock().unwrap(),
            &axo_store::StoredHostLink {
                account: link.account().map(|s| axo_store::StoredAccountLink {
                    account_id: s.account_id().into(),
                    credential_id: s.credential_id().into(),
                }),
                pending_redemption: link.pending().map(|s| axo_store::StoredPendingRedemption {
                    credential_id: s.credential_id().into(),
                    host_generation: s.host_generation().into(),
                }),
                retired: link
                    .retired()
                    .iter()
                    .map(|s| axo_store::StoredAccountLink {
                        account_id: s.account_id().into(),
                        credential_id: s.credential_id().into(),
                    })
                    .collect(),
            },
        )
    }
}
impl Host {
    fn set_asset_source(&self, source: Option<axo_relay::assets::AssetSource>) {
        *self.assets.lock().unwrap() = source;
    }
    fn publish_relay_status(&self, status: &axo_protocol::RelayStatus) {
        if let Ok(b) = self.backend() {
            b.publish(Event::RelayStatus {
                status: status.clone(),
            });
        }
    }
    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        let Ok(b) = self.backend() else { return vec![] };
        let sessions = b
            .sessions
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let now = axo_store::unix_timestamp().max(0) as u64 * 1000;
        let mut pending = b.computer.list();
        pending.extend(
            sessions
                .iter()
                .flat_map(|s| {
                    s.runtime
                        .lock()
                        .unwrap()
                        .remote_questions
                        .values()
                        .filter(|(_, e)| e.expires_at > now)
                        .map(|(_, e)| e.clone())
                        .collect::<Vec<_>>()
                })
                .collect::<Vec<_>>(),
        );
        pending
    }
    fn resolve_elicitation(
        &self,
        id: &str,
        answer: axo_protocol::elicitation::ElicitationAnswer,
        sealed: Option<axo_protocol::elicitation::Sealed>,
        device: Option<axo_protocol::elicitation::DeviceProof>,
    ) -> Result<(), (i64, String)> {
        let missing = || {
            (
                axo_protocol::elicitation::NOT_PENDING,
                "Already answered, expired, or no longer asked".into(),
            )
        };
        let proof = device.ok_or_else(|| {
            (
                axo_protocol::elicitation::BAD_SIGNATURE,
                "Answers must be signed by your device.".into(),
            )
        })?;
        let signed = axo_seal::answer_message(id, answer, sealed.as_ref());
        if !axo_seal::verify_answer(&proof.key, &proof.signature, &signed) {
            return Err((
                axo_protocol::elicitation::BAD_SIGNATURE,
                "Invalid answer signature.".into(),
            ));
        }
        let b = self.backend().map_err(|_| missing())?;
        if b.computer.list().iter().any(|q| q.id == id) {
            return b.computer.answer(
                &b,
                id,
                answer,
                sealed.map_or(
                    axo_protocol::elicitation::Reply::Bare,
                    axo_protocol::elicitation::Reply::Sealed,
                ),
            );
        }
        if sealed.is_some() {
            return Err((-32602, "Codex approval takes no form values".into()));
        }
        let sessions = b
            .sessions
            .lock()
            .unwrap()
            .iter()
            .map(|(id, s)| (*id, s.clone()))
            .collect::<Vec<_>>();
        for (session_id, s) in sessions {
            let question = s.runtime.lock().unwrap().remote_questions.get(id).cloned();
            if let Some((request, e)) = question {
                if e.expires_at <= axo_store::unix_timestamp().max(0) as u64 * 1000 {
                    return Err(missing());
                }
                let decision = match answer {
                    axo_protocol::elicitation::ElicitationAnswer::Accept => "accept",
                    axo_protocol::elicitation::ElicitationAnswer::Decline => "decline",
                };
                self.call(
                    "axo.session.approval.respond",
                    json!({"sessionId":session_id,"requestId":request,"decision":decision}),
                )
                .map_err(|_| missing())?;
                return Ok(());
            }
        }
        Err(missing())
    }
    fn computer_status(&self) -> Value {
        self.backend()
            .map_or_else(|_| json!({"available":false}), |b| b.computer.status())
    }
    fn remote_computer(
        &self,
        request: &axo_relay::computer::ComputerParams,
        cancelled: &std::sync::atomic::AtomicBool,
    ) -> Result<Value, (i64, String)> {
        let b = self.backend().map_err(|e| (-32000, e.to_string()))?;
        let result = b.computer.call(
            &b,
            computer::Call {
                session_id: request.session_id,
                tool: request.tool.clone(),
                args: if request.args.is_null() {
                    json!({})
                } else {
                    request.args.clone()
                },
                confirm: request.confirm,
                timeout_ms: request.timeout_ms,
            },
            cancelled,
        );
        // The shared relay worker uploads inline images and projects attachments.
        Ok(result)
    }
    fn read_sync_catalog(&self) -> io::Result<Vec<SyncSession>> {
        let b = self.backend()?;
        let db = b.database.lock().unwrap();
        let rows = axo_store::coding::catalog(&db)?;
        let directory = b.directory.join("codex-transcripts");
        std::fs::create_dir_all(&directory)?;
        let mut result = Vec::new();
        for row in rows {
            let id: SessionId = serde_json::from_value(row["id"].clone())?;
            let metadata: SessionMetadata = serde_json::from_value(json!({
                "name":row["name"],"emoji":row["emoji"],"folderName":axo_protocol::folder_name(Path::new(row["folder"].as_str().unwrap_or(""))),
                "hasAgent":true,"createdAt":row["createdAt"],"lastMessageAt":row["lastMessageAt"],"archived":row["archived"]
            }))?;
            let created = row["createdAt"].as_i64().unwrap_or(0);
            let mut lines = vec![json!({"type":"session","version":3,"id":id,"timestamp":axo_relay::utc_timestamp(created * 1000),"cwd":row["folder"],"agent":"codex"}).to_string()];
            let mut cursor = 0;
            let mut parent = Value::Null;
            loop {
                let messages = axo_store::coding::messages(&db, id, cursor)?;
                for m in &messages {
                    cursor = m["sequence"].as_i64().unwrap_or(cursor);
                    let at = m["createdAt"].as_i64().unwrap_or(0) * 1000;
                    lines.push(json!({"type":"message","id":m["itemId"],"parentId":parent,"timestamp":axo_relay::utc_timestamp(at),
                        "message":{"role":m["role"],"content":[{"type":"text","text":m["text"]}],"timestamp":at}}).to_string());
                    parent = m["itemId"].clone();
                }
                if messages.len() < 200 {
                    break;
                }
            }
            let text = lines.join("\n") + "\n";
            let path = directory.join(format!("{id}.jsonl"));
            if std::fs::read(&path).ok().as_deref() != Some(text.as_bytes()) {
                let temporary = path.with_extension("tmp");
                std::fs::write(&temporary, text)?;
                std::fs::rename(temporary, &path)?;
            }
            // Runtime readers write messages while holding the runtime lock, so release DB
            // before reading runtime state (below).
            result.push(SyncSession {
                session_id: id,
                pi_session_file: Some(path),
                status: (!metadata.archived).then_some(SessionStatus::Ready),
                metadata,
                transcript_in_cloud: false,
            });
        }
        drop(db);
        for s in &mut result {
            if !s.metadata.archived {
                s.status = Some(
                    b.session(s.session_id)?
                        .runtime
                        .lock()
                        .unwrap()
                        .status
                        .unwrap_or(SessionStatus::Ready),
                );
            }
        }
        Ok(result)
    }
    fn read_stored_metadata(&self) -> io::Result<Vec<StoredMetadata>> {
        let b = self.backend()?;
        Ok(axo_store::load_sync_states(&b.database.lock().unwrap())?
            .into_iter()
            .map(|s| StoredMetadata {
                session_id: s.session_id,
                json: s.metadata_json,
                version: s.metadata_version,
            })
            .collect())
    }
    fn store_sync_cursor(&self, id: SessionId, position: u64, chain: &str) -> io::Result<()> {
        let b = self.backend()?;
        axo_store::store_sync_cursor(&b.database.lock().unwrap(), id, position, chain)
    }
    fn store_sync_metadata(&self, id: SessionId, metadata: &str, version: u64) -> io::Result<()> {
        let b = self.backend()?;
        axo_store::store_sync_metadata(&b.database.lock().unwrap(), id, metadata, version)
    }
    fn next_sync_round(&self) -> io::Result<u64> {
        let b = self.backend()?;
        axo_store::next_sync_round(&b.database.lock().unwrap())
    }
    fn subscribe_remote_events(&self) -> io::Result<String> {
        self.backend()?
            .events
            .subscribe(events::Subscriber::Relay, None, true, || Vec::new())
    }
    fn next_remote_events<'a>(
        &'a self,
        id: &'a str,
        timeout: Duration,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Vec<Event>>> + Send + 'a>>
    {
        Box::pin(async move {
            let b = self.backend()?;
            let events = b.events.next(id, timeout, 128).await?;
            Ok(events.into_iter().map(|event| (*event).clone()).collect())
        })
    }
    fn unsubscribe_remote_events(&self, id: &str) -> io::Result<()> {
        self.backend()?.unsubscribe(id)
    }
}

impl Host {
    fn remote_create_session(
        &self,
        request: rpc::CreateSession,
        at: &str,
    ) -> io::Result<RemoteSessionSnapshot> {
        let b = self.backend()?;
        let value = b.create_session(request)?;
        let id: SessionId = serde_json::from_value(value["id"].clone())?;
        b.publish_snapshot(id);
        self.snapshot(value, at)
    }
    fn remote_close_session(
        &self,
        id: SessionId,
        _: &str,
    ) -> io::Result<Option<RemoteSessionSnapshot>> {
        self.call(method::SESSION_CLOSE, json!({"sessionId":id}))?;
        Ok(None)
    }
    fn remote_rename_session(&self, id: SessionId, name: &str) -> io::Result<()> {
        self.call(method::SESSION_RENAME, json!({"sessionId":id,"name":name}))?;
        Ok(())
    }
    fn remote_create_shell(&self, id: SessionId) -> io::Result<ShellId> {
        let result = self.call("axo.shell.create", json!({"sessionId":id}))?;
        serde_json::from_value(result["shellId"].clone()).map_err(io::Error::other)
    }
    fn remote_close_shell(&self, id: SessionId, shell: ShellId) -> io::Result<()> {
        self.call(
            "axo.terminal.close",
            json!({"sessionId":id,"shellId":shell}),
        )?;
        Ok(())
    }
    fn remote_set_layout(&self, id: SessionId, layout: LayoutNode) -> io::Result<()> {
        self.backend()?.set_layout(id, layout)?;
        Ok(())
    }
    fn remote_terminal_input(
        &self,
        id: SessionId,
        shell: ShellId,
        sequence: u64,
        data: &str,
    ) -> io::Result<()> {
        self.call(
            method::TERMINAL_INPUT,
            json!({"sessionId":id,"shellId":shell,"sequence":sequence,"data":data}),
        )?;
        Ok(())
    }
    fn remote_prompt_pi(
        &self,
        id: SessionId,
        text: &str,
        command: Option<&CommandId>,
        attachments: &[axo_protocol::asset::FetchedAttachment],
        delivery: ClientDelivery,
    ) -> io::Result<()> {
        let _guard = self.prompt_lock.lock().unwrap();
        let b = self.backend()?;
        b.session(id)?;
        if let Some(c) = command {
            match axo_store::coding::command_state(&b.database.lock().unwrap(), id, c.as_str())?
                .as_deref()
            {
                Some("submitted") => return Ok(()),
                Some(_) => {
                    return Err(io::Error::other(
                        "The earlier command's outcome is unconfirmed; inspect the conversation before sending another",
                    ));
                }
                None => {}
            }
        }
        if let Some(c) = command {
            axo_store::coding::reserve_command(&b.database.lock().unwrap(), id, c.as_str())?;
        }
        self.call(
            method::SESSION_PROMPT,
            json!({"sessionId":id,"text":text,"commandId":command.map(|c| c.as_str()),"delivery":match delivery { ClientDelivery::FollowUp => "followUp", ClientDelivery::Steer => "steer", ClientDelivery::Interrupt => "interrupt" },"attachments":attachments.iter().map(|a| &a.path).collect::<Vec<_>>()}),
        )?;
        if let Some(c) = command {
            axo_store::coding::submit_command(&b.database.lock().unwrap(), id, c.as_str())?;
        }
        Ok(())
    }
    fn remote_pi_commands(&self, id: SessionId) -> io::Result<Vec<axo_protocol::PiCommandInfo>> {
        self.backend()?.session(id)?;
        Ok(vec![])
    }
    fn remote_pi_models(&self, id: SessionId) -> io::Result<Vec<axo_protocol::PiModelInfo>> {
        let result = self.call("axo.session.models", json!({"sessionId":id}))?;
        result["models"].as_array().into_iter().flatten().map(|m| serde_json::from_value(json!({"id":m["model"],"provider":"codex","name":m["displayName"],"thinkingLevels":m["supportedReasoningEfforts"].as_array().into_iter().flatten().filter_map(|e| if e["reasoningEffort"] == "none" { Some(axo_protocol::ThinkingLevel::Off) } else { serde_json::from_value::<axo_protocol::ThinkingLevel>(e["reasoningEffort"].clone()).ok() }).collect::<Vec<_>>()})).map_err(io::Error::other)).collect()
    }
    fn remote_set_pi_model(
        &self,
        id: SessionId,
        model: Option<&ModelChoice>,
        effort: Option<axo_protocol::ThinkingLevel>,
    ) -> io::Result<()> {
        let existing = self.call("axo.session.model", json!({"sessionId":id}))?;
        if model.is_some_and(|m| m.provider.as_str() != "codex") {
            return Err(invalid("Choose a Codex model"));
        }
        self.call("axo.session.model.set",json!({"sessionId":id,"model":model.map(|m| json!(m.id.as_str())).unwrap_or(existing["model"].clone()),"effort":effort.map(|e| if e == axo_protocol::ThinkingLevel::Off { "none" } else { e.as_str() })}))?;
        Ok(())
    }
    fn remote_restart_pi(&self, id: SessionId) -> io::Result<()> {
        let b = self.backend()?;
        let s = b.session(id)?;
        let _operation = s.operation.lock().unwrap();
        let old = {
            let mut r = s.runtime.lock().unwrap();
            r.generation += 1;
            r.turn = None;
            r.agent.take()
        };
        if let Some(a) = old {
            a.stop();
        }
        b.computer.cancel_session(&b, id);
        b.connect(id, &s)?;
        b.publish_snapshot(id);
        Ok(())
    }
    fn remote_stop_pi_turn(&self, id: SessionId, stop: &StopTarget) -> io::Result<bool> {
        let b = self.backend()?;
        let s = b.session(id)?;
        let _operation = s.operation.lock().unwrap();
        let (agent, turn) = {
            let r = s.runtime.lock().unwrap();
            let matches = stop
                .turn_id()
                .into_iter()
                .chain(stop.seen())
                .any(|t| r.turn_entries.contains(&t.as_str().to_owned()))
                || stop
                    .command_ids()
                    .iter()
                    .any(|c| r.remote_command.as_deref() == Some(c.as_str()));
            if !matches || r.turn.is_none() {
                return Ok(false);
            }
            (
                r.agent
                    .clone()
                    .ok_or_else(|| io::Error::other("Codex is not running"))?,
                r.turn.clone(),
            )
        };
        let thread = axo_store::coding::thread_id(&b.database.lock().unwrap(), id)?;
        b.computer.cancel_session(&b, id);
        agent.request("turn/interrupt", json!({"threadId":thread,"turnId":turn}))?;
        Ok(true)
    }
    fn remote_press_pi_key(&self, id: SessionId, key: PiKey) -> io::Result<()> {
        let b = self.backend()?;
        let s = b.session(id)?;
        let _ = s;
        // Every answer must name the exact elicitation the client reviewed. A key press
        // must not approve whichever different request happens to be pending now.
        let _ = key;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Answer the Codex permission request by its elicitation ID",
        ))
    }
    fn remote_terminal_resize(
        &self,
        id: SessionId,
        shell: ShellId,
        rows: u32,
        columns: u32,
    ) -> io::Result<()> {
        self.call(
            method::TERMINAL_RESIZE,
            json!({"sessionId":id,"shellId":shell,"rows":rows,"columns":columns}),
        )?;
        Ok(())
    }
}
