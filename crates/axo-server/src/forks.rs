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
use axo_protocol::{RemoteSessionSnapshot, SessionId};
use axo_relay::peers::{CopyState, PeerIndex, Place};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::core::Core;
use crate::sessions::{self, Transcript};

pub(crate) const REMOTE_METHOD: &str = "axo.remote.session.fork";

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
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct BridgeRequest {
    pub(crate) session_id: SessionId,
    destination_host_id: String,
    request_id: SessionId,
    folder: Option<PathBuf>,
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
    core: &Core,
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
    core.catalog
        .record(receipt.child)
        .map(|record| created(core, &record))
        .ok_or_else(unknown)
}

pub(crate) async fn destination_fork(
    core: Arc<Core>,
    request: Request,
) -> Result<Created, MethodError> {
    let account_id = account(&core).await?;
    let path = receipt_path(&core, ".fork-requests", request.request_id);
    if let Some(receipt) = load(&path)? {
        return retry(&core, receipt, &account_id, &request);
    }
    let place = Place::of(&request.source_host_id, &request.session_id.to_string())
        .filter(|place| place.host_id != core.host_id)
        .ok_or_else(unavailable)?;
    let live = &core.peers.access().map_err(|_| disconnected())?.live;
    let expected_account = account_id.clone();
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
    let receipt = Receipt {
        account: account_id,
        request,
        child,
    };
    if !claim(&path, &receipt).map_err(|_| unknown())? {
        let existing = load(&path)?.ok_or_else(unknown)?;
        return retry(&core, existing, &receipt.account, &receipt.request);
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
        .map_err(operation_failed)?;
        Ok(created(&core, &record))
    })
    .await
    .map_err(|_| unknown())?
}

#[derive(Deserialize, Serialize)]
struct Plan {
    account: String,
    inputs: BridgeRequest,
    fork: Request,
}

pub(crate) async fn bridge(core: Arc<Core>, inputs: BridgeRequest) -> Result<Created, MethodError> {
    let account_id = account(&core).await?;
    let live = &core.peers.access().map_err(|_| disconnected())?.live;
    let path = receipt_path(&core, ".fork-plans", inputs.request_id);
    let existing: Option<Plan> = load(&path)?;
    let destination = inputs.destination_host_id.clone();
    let local = destination == core.host_id;
    let local_source = core.catalog.record(inputs.session_id);
    let expected_owner = local_source.as_ref().map(|_| core.host_id.clone());
    if existing.is_none() && local_source.is_some_and(|source| !source.agent.is_pi()) {
        return Err(MethodError::new(
            REFUSED,
            "Fork requires a confirmed Pi source",
        ));
    }
    let expected_account = account_id.clone();
    let session = inputs.session_id;
    let new = existing.is_none();
    let (target, origin) = live
        .inspect(
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
                    Some((owner.to_owned(), at))
                } else {
                    None
                };
                Ok((target, origin))
            },
        )
        .await
        .ok_or_else(disconnected)??;
    let plan = if let Some(plan) = existing {
        plan
    } else {
        let (source_host_id, at) = origin.ok_or_else(unavailable)?;
        let plan = Plan {
            account: account_id.clone(),
            inputs: inputs.clone(),
            fork: Request {
                source_host_id,
                session_id: inputs.session_id,
                request_id: inputs.request_id,
                epoch: at.epoch,
                head: at.cursor,
                folder: inputs.folder.clone(),
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
        .map_err(|error| {
            MethodError::new(
                error.code,
                if error.message.starts_with("Outcome unknown") {
                    unknown().message
                } else {
                    error.message
                },
            )
        })?;
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
