//! Account-authorized Pi-to-Codex fork on the Windows destination.
use super::*;
use axo_agent::{AgentKind, PiForkHistory};
use axo_relay::peers::{CopyState, Place};
use serde::Serialize;

pub(super) const PLAN: &str = "axo.remote.session.fork.plan";
pub(super) const CREATE: &str = "axo.remote.session.fork";

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    target: Target,
    source_host_id: String,
    session_id: SessionId,
    epoch: u64,
    head: u64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Target {
    host_id: String,
    host_generation: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    #[serde(flatten)]
    snapshot: Snapshot,
    request_id: SessionId,
    folder: Option<PathBuf>,
    agent: Option<AgentKind>,
}

struct Confirmed {
    agent: AgentKind,
    history: PiForkHistory,
}

#[derive(Clone, Copy)]
enum Failure {
    Invalid,
    StaleHost,
    Disconnected,
    Snapshot,
    Folder,
    Harness,
    Conflict,
    InProgress,
    Unknown,
}

impl Failure {
    fn wire(self) -> Value {
        let (code, message) = match self {
            Self::Invalid => (-32602, "Invalid fork params"),
            Self::StaleHost => (-32002, "Stale host"),
            Self::Disconnected => (-32003, "The paired account is unavailable"),
            Self::Snapshot => (-32004, "The confirmed source snapshot is unavailable"),
            Self::Folder => (-32602, "Choose a destination folder"),
            Self::Harness => (-32004, "The selected harness cannot import this source"),
            Self::Conflict => (-32602, "requestId already used for another fork"),
            Self::InProgress => (
                -32004,
                "Another fork is in progress; retry with the same requestId",
            ),
            Self::Unknown => (
                -32004,
                "Fork outcome unknown; retry with the same requestId",
            ),
        };
        let mut error = json!({"code":code,"message":message});
        if matches!(self, Self::Harness) {
            error["data"] = json!({"kind":"forkHarnessUnavailable","created":false});
        }
        error
    }
}

fn unknown(error: io::Error) -> Failure {
    log::warn!("event=windows.fork_failed error_kind={:?}", error.kind());
    Failure::Unknown
}

pub(super) fn answer(host: &Host, id: Value, method: &str, params: Value) -> Value {
    let result = if method == PLAN {
        serde_json::from_value(params)
            .map_err(|_| Failure::Invalid)
            .and_then(|snapshot| host.plan(snapshot))
    } else {
        serde_json::from_value(params)
            .map_err(|_| Failure::Invalid)
            .and_then(|request| host.fork(request))
    };
    match result {
        Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
        Err(error) => json!({"jsonrpc":"2.0","id":id,"error":error.wire()}),
    }
}

impl Host {
    fn account_for(&self, request: &Snapshot) -> Result<String, Failure> {
        if request.target.host_id != self.identity.host_id
            || request.target.host_generation != self.identity.host_generation
        {
            return Err(Failure::StaleHost);
        }
        self.read_link()
            .map_err(unknown)?
            .account()
            .map(|account| account.account_id().to_owned())
            .ok_or(Failure::Disconnected)
    }

    fn confirmed(&self, request: &Snapshot, account: &str) -> Result<Confirmed, Failure> {
        let place = Place::of(&request.source_host_id, &request.session_id.to_string())
            .filter(|place| place.host_id != self.identity.host_id)
            .ok_or(Failure::Snapshot)?;
        let expected = CopyState {
            epoch: request.epoch,
            cursor: request.head,
        };
        if expected.epoch == 0 {
            return Err(Failure::Snapshot);
        }
        let account = account.to_owned();
        let (agent, lines) = tokio::runtime::Handle::current()
            .block_on(self.peers.inspect(false, move |connected, index, mirror| {
                if connected != account {
                    return Err(Failure::Disconnected);
                }
                let hosts = index
                    .hosts
                    .iter()
                    .filter(|entry| entry["hostId"] == place.host_id)
                    .count();
                if hosts != 1 {
                    return Err(Failure::Snapshot);
                }
                let mut sessions = index.sessions.iter().filter(|entry| {
                    entry["hostId"] == place.host_id && entry["sessionId"] == place.session_id
                });
                let entry = sessions.next().ok_or(Failure::Snapshot)?;
                if sessions.next().is_some()
                    || entry["epoch"].as_u64() != Some(expected.epoch)
                    || entry["head"].as_u64() != Some(expected.cursor)
                {
                    return Err(Failure::Snapshot);
                }
                let agent = serde_json::from_value(entry["metadata"]["agent"].clone())
                    .map_err(|_| Failure::Snapshot)?;
                let lines = mirror
                    .snapshot(&place, expected)
                    .map_err(|_| Failure::Snapshot)?;
                Ok((agent, lines))
            }))
            .ok_or(Failure::Disconnected)??;
        let history = PiForkHistory::parse(lines).map_err(|_| Failure::Snapshot)?;
        Ok(Confirmed { agent, history })
    }

    fn plan(&self, request: Snapshot) -> Result<Value, Failure> {
        let account = self.account_for(&request)?;
        let source = self.confirmed(&request, &account)?;
        let backend = self.backend().map_err(unknown)?;
        let decision = if source.agent == AgentKind::Pi
            && backend.fork_codex
            && fork_import::converter().is_some()
        {
            json!({"kind":"choose","agents":[AgentKind::Codex]})
        } else {
            json!({"kind":"unavailable"})
        };
        Ok(json!({"sourceAgent":source.agent,"historyFormat":"pi/3","decision":decision}))
    }

    fn fork(&self, request: Request) -> Result<Value, Failure> {
        let backend = self.backend().map_err(unknown)?;
        let account = self.account_for(&request.snapshot)?;
        let key = json!({"account":account,"request":request}).to_string();
        if let Some(reply) = prior(&backend, request.request_id, &key)? {
            return Ok(reply);
        }
        let _permit = self.fork_lock.try_lock().map_err(|_| Failure::InProgress)?;
        if let Some(reply) = prior(&backend, request.request_id, &key)? {
            return Ok(reply);
        }
        let source = self.confirmed(&request.snapshot, &account)?;
        let selected = request.agent.unwrap_or(source.agent);
        if source.agent != AgentKind::Pi || selected != AgentKind::Codex || !backend.fork_codex {
            return Err(Failure::Harness);
        }
        let converter = fork_import::converter().ok_or(Failure::Harness)?;
        let runtime = tokio::runtime::Handle::current();
        if !runtime.block_on(agents::import_supported(&backend.codex)) {
            return Err(Failure::Harness);
        }
        let folder = canonical_directory(
            request
                .folder
                .as_deref()
                .unwrap_or_else(|| Path::new(source.history.source_folder())),
        )
        .map_err(|_| Failure::Folder)?;
        // Link and creation share a lock at the commit boundary. A prepared fork cannot become
        // visible in a different account; the generation is stable for the life of this daemon.
        if self.account_for(&request.snapshot)? != account {
            return Err(Failure::Disconnected);
        }
        if !axo_store::coding::claim_fork(
            &backend.database.lock().unwrap(),
            request.request_id,
            &key,
        )
        .map_err(unknown)?
        {
            return prior(&backend, request.request_id, &key)?.ok_or(Failure::Unknown);
        }
        let child = SessionId::new_v4().map_err(unknown)?;
        let imported = runtime
            .block_on(fork_import::convert(
                &converter,
                &backend.directory.join("imported-codex"),
                child,
                &folder,
                &request.snapshot.source_host_id,
                &self.identity.host_id,
                source.history,
            ))
            .map_err(unknown)?;
        let child_id = child.to_string();
        let agent =
            Codex::spawn_for_import(&backend.codex, &folder, &[], |_| {}).map_err(unknown)?;
        let mut params = backend.codex_parameters(&folder);
        fork_import::resume_params(&mut params, &child_id, &imported.path);
        let result = agent.request("thread/resume", params).map_err(unknown)?;
        fork_import::verify_resume(&result, &child_id, &folder, &imported.path).map_err(unknown)?;
        drop(agent);
        let relay = backend
            .relay
            .lock()
            .unwrap()
            .clone()
            .ok_or(Failure::Disconnected)?;
        let _link = relay.link_lock.lock().unwrap();
        if self.account_for(&request.snapshot)? != account {
            return Err(Failure::Disconnected);
        }
        let name = "Forked Codex session";
        let reply = json!({"session":RemoteSessionSnapshot {
            host_id:self.identity.host_id.clone(),session_id:child, folder_name:axo_protocol::folder_name(&folder),
            name:name.into(),emoji:None,status:SessionStatus::Ready,has_agent:true,shells:vec![],layout:None,
            updated_at:axo_relay::current_timestamp(),last_message_at:None,created_at:None,pi:codex_runtime_model(&result),
        }});
        {
            let mut db = backend.database.lock().unwrap();
            let transaction = db
                .transaction()
                .map_err(io::Error::other)
                .map_err(unknown)?;
            axo_store::coding::insert_session(&transaction, child, &folder, name, None)
                .map_err(unknown)?;
            axo_store::coding::set_thread_id(&transaction, child, &child_id).map_err(unknown)?;
            axo_store::coding::set_conversation_path(&transaction, child, &imported.path)
                .map_err(unknown)?;
            for (index, message) in imported.messages.iter().enumerate() {
                axo_store::coding::save_message(
                    &transaction,
                    child,
                    &format!("fork-{index}"),
                    message.role,
                    &message.text,
                )
                .map_err(unknown)?;
            }
            axo_store::coding::complete_fork(
                &transaction,
                request.request_id,
                child,
                &imported.path,
                &reply.to_string(),
            )
            .map_err(unknown)?;
            transaction
                .commit()
                .map_err(io::Error::other)
                .map_err(unknown)?;
        }
        backend.publish_snapshot(child);
        log::info!("event=windows.fork_completed source_agent=pi destination_agent=codex");
        Ok(reply)
    }
}

fn prior(backend: &Backend, id: SessionId, key: &str) -> Result<Option<Value>, Failure> {
    let Some((expected, reply)) =
        axo_store::coding::fork_receipt(&backend.database.lock().unwrap(), id).map_err(unknown)?
    else {
        return Ok(None);
    };
    if expected != key {
        return Err(Failure::Conflict);
    }
    let reply = reply.ok_or(Failure::Unknown)?;
    serde_json::from_str(&reply)
        .map(Some)
        .map_err(|_| Failure::Unknown)
}
