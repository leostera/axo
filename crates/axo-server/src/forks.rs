//! Cross-host forks use only a confirmed account listing and the destination's committed copy.
//!
//! Local `axo.session.fork` with `destinationHostId` resolves `sessionId` into an account-owned
//! source and published epoch/head. The relay call adds the destination `target`; the explicit
//! local destination form omits it. Both cross-host forms return `{session: RemoteSession}`.
//! Only protocol 3 exposes the local source's published index (on its own HostDO route).

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::{INVALID_PARAMS, NOT_CONNECTED, NOT_FOUND, REFUSED};
use axo_protocol::{RemoteSessionSnapshot, SessionId, agent::AgentKind};
use axo_relay::peers::{CopyState, PeerIndex, Place};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::core::Core;
use crate::sessions::{self, Transcript};

pub(crate) const REMOTE_METHOD: &str = "axo.remote.session.fork";
pub(crate) const REMOTE_PLAN: &str = "axo.remote.session.fork.plan";

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SnapshotRequest {
    pub(crate) source_host_id: String,
    pub(crate) session_id: SessionId,
    pub(crate) epoch: u64,
    pub(crate) head: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct BridgePlanRequest {
    session_id: SessionId,
    destination_host_id: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HarnessPlan {
    source_agent: AgentKind,
    history_format: String,
    decision: HarnessDecision,
}

impl HarnessPlan {
    fn validate(self) -> Result<Self, MethodError> {
        let valid = match &self.decision {
            HarnessDecision::Keep { agent } => *agent == self.source_agent,
            HarnessDecision::Choose { agents } => {
                let distinct: std::collections::HashSet<_> = agents.iter().collect();
                !agents.is_empty()
                    && distinct.len() == agents.len()
                    && !distinct.contains(&self.source_agent)
            }
            HarnessDecision::Unavailable => true,
        };
        if !valid || self.history_format.trim().is_empty() {
            return Err(unavailable());
        }
        Ok(self)
    }
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum HarnessDecision {
    Keep { agent: AgentKind },
    Choose { agents: Vec<AgentKind> },
    Unavailable,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    pub(crate) source_host_id: String,
    pub(crate) session_id: SessionId,
    pub(crate) epoch: u64,
    pub(crate) head: u64,
    pub(crate) request_id: SessionId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) folder: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) agent: Option<AgentKind>,
}

impl Request {
    fn snapshot(&self) -> SnapshotRequest {
        SnapshotRequest {
            source_host_id: self.source_host_id.clone(),
            session_id: self.session_id,
            epoch: self.epoch,
            head: self.head,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct BridgeRequest {
    pub(crate) session_id: SessionId,
    destination_host_id: String,
    request_id: SessionId,
    folder: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent: Option<AgentKind>,
}

#[derive(Deserialize, Serialize)]
pub(crate) struct Created {
    session: RemoteSessionSnapshot,
}

fn unavailable() -> MethodError {
    MethodError::new(NOT_FOUND, "The confirmed source snapshot is unavailable")
}

fn disconnected() -> MethodError {
    MethodError::new(NOT_CONNECTED, "The paired account is unavailable")
}

fn unknown() -> MethodError {
    MethodError::new(
        NOT_FOUND,
        "Fork outcome unknown; retry with the same requestId",
    )
}

fn operation_failed(error: io::Error) -> MethodError {
    log::warn!("event=session.fork_failed error_kind={:?}", error.kind());
    MethodError::new(REFUSED, "Could not fork the Session")
}

async fn account(core: &Core) -> Result<String, MethodError> {
    core.store
        .call(|db| axo_store::load_host_link(db))
        .await
        .map_err(operation_failed)?
        .account
        .map(|link| link.account_id)
        .ok_or_else(disconnected)
}

fn unique<'a>(mut matches: impl Iterator<Item = &'a Value>) -> Option<&'a Value> {
    let first = matches.next()?;
    matches.next().is_none().then_some(first)
}

fn source<'a>(
    index: &'a PeerIndex,
    session: SessionId,
    owner: Option<&str>,
) -> Result<(&'a Value, CopyState), MethodError> {
    let id = session.to_string();
    let entry = unique(index.sessions.iter().filter(|entry| {
        entry["sessionId"].as_str() == Some(&id)
            && owner.is_none_or(|owner| entry["hostId"].as_str() == Some(owner))
    }))
    .ok_or_else(unavailable)?;
    if entry["metadata"]["agent"].as_str() != Some("pi") {
        return Err(MethodError::new(
            REFUSED,
            "Fork requires a confirmed Pi source",
        ));
    }
    Ok((
        entry,
        CopyState {
            epoch: entry["epoch"]
                .as_u64()
                .filter(|epoch| *epoch > 0)
                .ok_or_else(unavailable)?,
            cursor: entry["head"].as_u64().ok_or_else(unavailable)?,
        },
    ))
}

fn host<'a>(index: &'a PeerIndex, id: &str) -> Option<&'a Value> {
    unique(
        index
            .hosts
            .iter()
            .filter(|host| host["hostId"].as_str() == Some(id)),
    )
}

#[derive(Deserialize, Serialize)]
struct Receipt<T> {
    account: String,
    request: T,
    child: SessionId,
}

fn receipt_path(core: &Core, lane: &str, id: SessionId) -> PathBuf {
    core.pi_directories
        .transcripts
        .join(lane)
        .join(id.to_string())
}

fn load<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Option<T>, MethodError> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| unknown()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(unknown()),
    }
}

/// Publish a fully written claim without replacing a concurrent winner. Once claimed, not even
/// a crash between reserving and starting Pi permits the same request to create a second child.
fn claim(path: &Path, value: &impl Serialize) -> io::Result<bool> {
    let folder = path.parent().expect("receipt has a parent");
    fs::create_dir_all(folder)?;
    let temporary = folder.join(axo_protocol::new_uuid_v4()?);
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let result = (|| {
        serde_json::to_writer(&mut out, value).map_err(io::Error::other)?;
        out.sync_all()?;
        match fs::hard_link(&temporary, path) {
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
            Err(error) => Err(error),
            Ok(()) => {
                File::open(folder)?.sync_all()?;
                File::open(folder.parent().expect("receipt directory has a parent"))?.sync_all()?;
                Ok(true)
            }
        }
    })();
    let _ = fs::remove_file(temporary);
    result
}

fn created(core: &Core, record: &axo_protocol::SessionRecord) -> Created {
    Created {
        session: RemoteSessionSnapshot::from_record(
            record,
            &core.host_id,
            &axo_relay::current_timestamp(),
        ),
    }
}

fn retry(
    completed: &Path,
    receipt: Receipt<Request>,
    account: &str,
    request: &Request,
) -> Result<Created, MethodError> {
    if receipt.account != account || &receipt.request != request {
        return Err(MethodError::new(
            INVALID_PARAMS,
            "requestId already used for another fork",
        ));
    }
    let result: Created = load(completed)?.ok_or_else(unknown)?;
    if result.session.session_id != receipt.child {
        return Err(unknown());
    }
    Ok(result)
}

struct Snapshot {
    lines: Vec<String>,
    header: Value,
}

async fn confirmed_snapshot(
    core: &Core,
    account_id: &str,
    request: SnapshotRequest,
) -> Result<Snapshot, MethodError> {
    let place = Place::of(&request.source_host_id, &request.session_id.to_string())
        .filter(|place| place.host_id != core.host_id)
        .ok_or_else(unavailable)?;
    let live = &core.peers.access().map_err(|_| disconnected())?.live;
    let expected_account = account_id.to_owned();
    let id = request.session_id;
    let requested = CopyState {
        epoch: request.epoch,
        cursor: request.head,
    };
    let lines = live
        .inspect(false, move |connected, index, mirror| {
            if connected != expected_account {
                return Err(disconnected());
            }
            host(index, &place.host_id).ok_or_else(unavailable)?;
            let (_, at) = source(index, id, Some(&place.host_id))?;
            if at != requested {
                return Err(unavailable());
            }
            mirror.snapshot(&place, at).map_err(|_| unavailable())
        })
        .await
        .ok_or_else(disconnected)??;
    let header = header(&lines)?;
    if account(core).await? != account_id {
        return Err(disconnected());
    }
    Ok(Snapshot { lines, header })
}

// This is the compatibility policy, not the generic installed-agent catalog. No
// other Unix adapter can yet import a Pi v3 history and its hidden provenance.
fn pi_import_available(core: &Core) -> bool {
    axo_agent::pi::check_launch_paths(&core.settings().agent_command).is_ok()
}

pub(crate) async fn destination_plan(
    core: Arc<Core>,
    request: SnapshotRequest,
) -> Result<HarnessPlan, MethodError> {
    let account_id = account(&core).await?;
    confirmed_snapshot(&core, &account_id, request).await?;
    Ok(HarnessPlan {
        source_agent: AgentKind::Pi,
        history_format: "pi/3".into(),
        decision: if pi_import_available(&core) {
            HarnessDecision::Keep {
                agent: AgentKind::Pi,
            }
        } else {
            HarnessDecision::Unavailable
        },
    })
}

fn harness_unavailable() -> MethodError {
    MethodError::new(
        REFUSED,
        "This host has no compatible runnable harness for the requested fork",
    )
    .with_data(json!({"kind": "forkHarnessUnavailable", "created": false}))
}

pub(crate) async fn destination_fork(
    core: Arc<Core>,
    request: Request,
) -> Result<Created, MethodError> {
    let account_id = account(&core).await?;
    let path = receipt_path(&core, ".fork-requests", request.request_id);
    let completed = receipt_path(&core, ".fork-completed", request.request_id);
    if let Some(receipt) = load(&path)? {
        return retry(&completed, receipt, &account_id, &request);
    }
    let Snapshot { lines, header } =
        confirmed_snapshot(&core, &account_id, request.snapshot()).await?;
    let source_cwd = header["cwd"].as_str().ok_or_else(unavailable)?;
    let folder = destination_folder(
        request
            .folder
            .as_deref()
            .unwrap_or_else(|| Path::new(source_cwd)),
    )?;
    let child = SessionId::new_v4().map_err(operation_failed)?;
    let contents = transcript(
        lines,
        header,
        child,
        &folder,
        &request.source_host_id,
        &core.host_id,
    )?;
    if account(&core).await? != account_id {
        return Err(disconnected());
    }
    if request.agent.is_some_and(|agent| agent != AgentKind::Pi) || !pi_import_available(&core) {
        // Another invocation with this same ID may have claimed while we verified the copy.
        if let Some(receipt) = load(&path)? {
            return retry(&completed, receipt, &account_id, &request);
        }
        return Err(harness_unavailable());
    }
    let receipt = Receipt {
        account: account_id,
        request,
        child,
    };
    if !claim(&path, &receipt).map_err(|_| unknown())? {
        let existing = load(&path)?.ok_or_else(unknown)?;
        return retry(&completed, existing, &receipt.account, &receipt.request);
    }
    // Losing an RPC reply does not cancel creation after the durable claim.
    tokio::spawn(async move {
        let record = sessions::create_in(
            &core,
            folder,
            Transcript::PeerFork {
                id: child,
                contents,
            },
            None,
            axo_agent::AgentKind::Pi,
        )
        .await
        .map_err(|error| {
            operation_failed(error);
            unknown()
        })?;
        let response = created(&core, &record);
        if !claim(&completed, &response).map_err(|_| unknown())? {
            return Err(unknown());
        }
        Ok(response)
    })
    .await
    .map_err(|_| unknown())?
}

#[derive(Deserialize, Serialize)]
struct Plan {
    account: String,
    inputs: BridgeRequest,
    #[serde(default)]
    target: Option<Value>,
    fork: Request,
}

async fn resolve_bridge(
    core: &Core,
    account_id: &str,
    session: SessionId,
    destination: String,
    new: bool,
) -> Result<(Option<Value>, Option<SnapshotRequest>), MethodError> {
    let live = &core.peers.access().map_err(|_| disconnected())?.live;
    let local = destination == core.host_id;
    let local_source = core.catalog.record(session);
    let expected_owner = local_source.as_ref().map(|_| core.host_id.clone());
    if new && local_source.is_some_and(|source| !source.agent.is_pi()) {
        return Err(MethodError::new(
            REFUSED,
            "Fork requires a confirmed Pi source",
        ));
    }
    let expected_account = account_id.to_owned();
    live.inspect(
        new && expected_owner.is_some(),
        move |connected, index, _| {
            if connected != expected_account {
                return Err(disconnected());
            }
            let target = if local {
                None
            } else {
                let peer = host(index, &destination)
                    .filter(|host| host["online"].as_bool() == Some(true))
                    .ok_or_else(|| MethodError::new(-32005, "Host offline; nothing sent"))?;
                let generation = peer["hostGeneration"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                    .ok_or_else(disconnected)?;
                Some(json!({"hostId": destination, "hostGeneration": generation}))
            };
            let origin = if new {
                let (entry, at) = source(index, session, expected_owner.as_deref())?;
                let owner = entry["hostId"].as_str().ok_or_else(unavailable)?;
                if owner == destination {
                    return Err(MethodError::new(INVALID_PARAMS, "Choose a different host"));
                }
                if expected_owner.as_deref() != Some(owner) {
                    host(index, owner).ok_or_else(unavailable)?;
                }
                Some(SnapshotRequest {
                    source_host_id: owner.to_owned(),
                    session_id: session,
                    epoch: at.epoch,
                    head: at.cursor,
                })
            } else {
                None
            };
            Ok((target, origin))
        },
    )
    .await
    .ok_or_else(disconnected)?
}

fn forwarded_error(error: axo_relay::peers::PeerCommandError) -> MethodError {
    let mut forwarded = MethodError::new(error.code, error.message);
    forwarded.data = error.data;
    forwarded
}

pub(crate) async fn bridge_plan(
    core: Arc<Core>,
    inputs: BridgePlanRequest,
) -> Result<HarnessPlan, MethodError> {
    let account_id = account(&core).await?;
    let (target, snapshot) = resolve_bridge(
        &core,
        &account_id,
        inputs.session_id,
        inputs.destination_host_id.clone(),
        true,
    )
    .await?;
    let snapshot = snapshot.ok_or_else(unavailable)?;
    let Some(target) = target else {
        return destination_plan(core, snapshot).await;
    };
    let mut params = serde_json::to_value(snapshot).map_err(|_| unavailable())?;
    params["target"] = target;
    let live = &core.peers.access().map_err(|_| disconnected())?.live;
    let result = live
        .account_command(
            account_id,
            &inputs.destination_host_id,
            REMOTE_PLAN,
            params,
            Duration::from_secs(10),
        )
        .await
        .map_err(forwarded_error)?;
    serde_json::from_value::<HarnessPlan>(result)
        .map_err(|_| unavailable())?
        .validate()
}

pub(crate) async fn bridge(core: Arc<Core>, inputs: BridgeRequest) -> Result<Created, MethodError> {
    let account_id = account(&core).await?;
    let live = &core.peers.access().map_err(|_| disconnected())?.live;
    let path = receipt_path(&core, ".fork-plans", inputs.request_id);
    let existing: Option<Plan> = load(&path)?;
    let (target, origin) = resolve_bridge(
        &core,
        &account_id,
        inputs.session_id,
        inputs.destination_host_id.clone(),
        existing.is_none(),
    )
    .await?;
    let plan = if let Some(plan) = existing {
        plan
    } else {
        let snapshot = origin.ok_or_else(unavailable)?;
        let plan = Plan {
            account: account_id.clone(),
            inputs: inputs.clone(),
            target: target.clone(),
            fork: Request {
                source_host_id: snapshot.source_host_id,
                session_id: snapshot.session_id,
                request_id: inputs.request_id,
                epoch: snapshot.epoch,
                head: snapshot.head,
                folder: inputs.folder.clone(),
                agent: inputs.agent,
            },
        };
        if claim(&path, &plan).map_err(|_| unknown())? {
            plan
        } else {
            load(&path)?.ok_or_else(unknown)?
        }
    };
    if plan.account != account_id || plan.inputs != inputs {
        return Err(MethodError::new(
            INVALID_PARAMS,
            "requestId already used for another fork",
        ));
    }
    if account(&core).await? != account_id {
        return Err(disconnected());
    }
    // Do not send an uncertain operation to a new installation with no receipt.
    // Old on-disk outbound plans lacking a generation cannot be retried safely.
    if plan.target != target {
        return Err(unknown());
    }
    let Some(target) = target else {
        return destination_fork(core, plan.fork).await;
    };
    let mut params = serde_json::to_value(&plan.fork).map_err(|_| unknown())?;
    params["target"] = target;
    let result = live
        .account_command(
            account_id,
            &inputs.destination_host_id,
            REMOTE_METHOD,
            params,
            Duration::from_secs(35),
        )
        .await
        .map_err(forwarded_error)?;
    let created: Created = serde_json::from_value(result).map_err(|_| unknown())?;
    if created.session.host_id != inputs.destination_host_id
        || created.session.session_id == inputs.session_id
    {
        return Err(unknown());
    }
    Ok(created)
}

fn destination_folder(folder: &Path) -> Result<PathBuf, MethodError> {
    let choose = || MethodError::new(INVALID_PARAMS, "Choose a destination folder");
    if !folder.is_absolute() {
        return Err(choose());
    }
    let canonical = folder.canonicalize().map_err(|_| choose())?;
    if !canonical.is_dir() || canonical.to_str().is_none() {
        return Err(choose());
    }
    Ok(canonical)
}

fn header(lines: &[String]) -> Result<Value, MethodError> {
    let header: Value =
        serde_json::from_str(lines.first().ok_or_else(unavailable)?).map_err(|_| unavailable())?;
    if header["type"] != "session"
        || header["version"].as_u64() != Some(3)
        || header["id"].as_str().is_none_or(str::is_empty)
        || !header["cwd"]
            .as_str()
            .is_some_and(|cwd| Path::new(cwd).is_absolute())
    {
        return Err(unavailable());
    }
    Ok(header)
}

fn transcript(
    lines: Vec<String>,
    mut header: Value,
    child: SessionId,
    folder: &Path,
    from: &str,
    to: &str,
) -> Result<Vec<u8>, MethodError> {
    let content = format!(
        "This conversation was forked from host {from}, working directory {:?}, to host {to}, working directory {:?}. Earlier tool outputs are historical observations of the source host, not observations of the destination. Project files were not copied. Verify destination state before acting.",
        header["cwd"].as_str().expect("parsed header"),
        folder
    );
    header["id"] = json!(child);
    header["cwd"] = json!(folder);
    let mut output = Vec::new();
    writeln!(output, "{header}").map_err(operation_failed)?;
    let mut parent = Value::Null;
    for line in lines.into_iter().skip(1) {
        let mut entry: Value = serde_json::from_str(&line).map_err(|_| unavailable())?;
        if entry["id"].as_str().is_none_or(str::is_empty) {
            return Err(unavailable());
        }
        parent = entry["id"].clone();
        if entry["type"] == "custom" && entry["customType"] == "axo.command.queued" {
            // Keep the entry ID for descendants, but do not carry a runnable prompt or its data.
            entry["customType"] = json!("axo.fork.discarded_queue");
            entry.as_object_mut().expect("custom entry").remove("data");
            writeln!(output, "{entry}").map_err(operation_failed)?;
        } else {
            writeln!(output, "{line}").map_err(operation_failed)?;
        }
    }
    writeln!(output, "{}", json!({
        "type": "custom_message", "customType": "axo_host_fork", "id": axo_protocol::new_uuid_v4().map_err(operation_failed)?,
        "parentId": parent, "timestamp": axo_relay::current_timestamp(), "content": content, "display": false,
    })).map_err(operation_failed)?;
    Ok(output)
}
