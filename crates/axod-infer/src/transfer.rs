//! Cancellable HTTPS transfers. Only HF API/resolve URLs constructed from parsed references.
//! curl is the lifeline guard's direct child; no repository code or shell download scripts run.
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use axo_pty::exit::WatchedChild;
use serde_json::Value;
use sha1::Sha1;
use sha2::{Digest, Sha256};

use crate::api::Selection;
use crate::catalog::{Artifact, Resolved};
use crate::service::Error;
use crate::{blocking, free_disk, lifeline, try_lock};

struct Transfer {
    child: Option<WatchedChild>,
    temporary: Option<PathBuf>,
}
impl Transfer {
    async fn wait(&mut self) -> Result<bool, Error> {
        self.child
            .as_mut()
            .expect("transfer owns its child")
            .wait()
            .await
            .map(|status| status.success())
            .map_err(|_| Error::failed("could not wait for HF transfer"))
    }
}
impl Drop for Transfer {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if !child.exit().has_exited() {
                // SAFETY: the unreaped child is our own lifeline guard; its trap stops curl.
                unsafe {
                    libc::kill(child.id() as i32, libc::SIGTERM);
                }
            }
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = child.wait().await;
                });
            }
        }
        if let Some(directory) = &self.temporary {
            let _ = std::fs::remove_dir_all(directory);
        }
    }
}

pub async fn metadata(root: &Path, selection: &Selection) -> Result<Value, Error> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let directory = root.join(format!(
        ".metadata-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let prepare = directory.clone();
    let (body, status, log) = blocking(move || {
        std::fs::create_dir_all(prepare.parent().unwrap())
            .map_err(|_| Error::failed("could not create metadata directory"))?;
        std::fs::create_dir(&prepare)
            .map_err(|_| Error::failed("could not create temporary metadata directory"))?;
        Ok::<_, Error>((
            prepare.join("body.json"),
            File::create(prepare.join("status"))
                .map_err(|_| Error::failed("could not create metadata status file"))?,
            File::create(prepare.join("log"))
                .map_err(|_| Error::failed("could not create metadata log"))?,
        ))
    })
    .await?;
    let url = format!(
        "https://huggingface.co/api/models/{}/revision/{}?blobs=true",
        selection.model.repo(),
        selection.model.revision()
    );
    let mut command = lifeline()
        .map_err(|_| Error::failed("could not create transfer lifeline"))?
        .guarded(Path::new("/usr/bin/curl"), None)
        .map_err(|_| Error::failed("could not prepare metadata transfer"))?;
    command
        .args([
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "-fL",
            "--connect-timeout",
            "15",
            "--max-time",
            "30",
            "--max-filesize",
            "4194304",
            "--silent",
            "--show-error",
            "--write-out",
            "%{http_code}",
            "-o",
        ])
        .arg(&body)
        .arg(url)
        .stdout(status)
        .stderr(log);
    let child = command
        .spawn()
        .map_err(|_| Error::failed("could not start HF metadata transfer"))?;
    let mut transfer = Transfer {
        child: Some(
            WatchedChild::new(child)
                .map_err(|_| Error::failed("could not watch metadata transfer"))?,
        ),
        temporary: Some(directory.clone()),
    };
    let success = transfer.wait().await?;
    let result = blocking(move || {
        let status = std::fs::read_to_string(directory.join("status")).unwrap_or_default();
        if !success {
            return Err(match status.as_str() {
                "401" | "403" => Error::unsupported("HF requires authentication or license acceptance for this repository. This runtime currently fetches public ungated artifacts only; it does not borrow the HF MCP connection's credentials."),
                "404" => Error::invalid("HF repository or revision not found (or private without authentication)"),
                _ => Error::failed("HF metadata request failed or exceeded its 4 MiB / 30 second limit"),
            });
        }
        let mut bytes = Vec::new();
        File::open(body).map_err(|_| Error::failed("could not read HF metadata"))?.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes).map_err(|_| Error::failed("could not read HF metadata"))?;
        if bytes.len() > 4 * 1024 * 1024 { return Err(Error::failed("HF metadata exceeds 4 MiB")); }
        serde_json::from_slice(&bytes).map_err(|_| Error::failed("HF returned invalid JSON"))
    }).await;
    drop(transfer);
    result
}

/// Fetch only a small, integrity-pinned JSON resource. Never used for weights.
pub async fn json_resource(
    root: &Path,
    selection: &Selection,
    revision: &str,
    artifact: &Artifact,
) -> Result<Value, Error> {
    artifact.validate()?;
    if !crate::catalog::hex(revision, 40)
        || artifact.bytes > 4 * 1024 * 1024
        || !artifact.path.as_str().ends_with(".json")
    {
        return Err(Error::invalid(
            "JSON resource requires an immutable revision and at most 4 MiB",
        ));
    }
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let directory = root.join(format!(
        ".resource-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let output = directory.join(format!("{}.part", artifact.path.as_str()));
    let prepare = output.clone();
    let log_path = directory.join("log");
    let log = blocking(move || {
        std::fs::create_dir_all(prepare.parent().unwrap())
            .map_err(|_| Error::failed("could not create JSON resource directory"))?;
        File::create(log_path).map_err(|_| Error::failed("could not create resource log"))
    })
    .await?;
    let url = format!(
        "https://huggingface.co/{}/resolve/{}/{}",
        selection.model.repo(),
        revision,
        artifact.path.as_str()
    );
    let mut command = lifeline()
        .map_err(|_| Error::failed("could not create resource lifeline"))?
        .guarded(Path::new("/usr/bin/curl"), None)
        .map_err(|_| Error::failed("could not prepare resource transfer"))?;
    command
        .args([
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "-fL",
            "--connect-timeout",
            "15",
            "--max-time",
            "30",
            "--max-filesize",
            &artifact.bytes.to_string(),
            "--silent",
            "--show-error",
            "-o",
        ])
        .arg(output)
        .arg(url)
        .stderr(log);
    let child = command
        .spawn()
        .map_err(|_| Error::failed("could not start JSON resource transfer"))?;
    let mut transfer = Transfer {
        child: Some(
            WatchedChild::new(child)
                .map_err(|_| Error::failed("could not watch resource transfer"))?,
        ),
        temporary: Some(directory.clone()),
    };
    if !transfer.wait().await? {
        return Err(Error::failed(
            "pinned JSON resource request failed or exceeded its limit",
        ));
    }
    let artifact = artifact.clone();
    let result = blocking(move || {
        finalize(&directory, &artifact)?;
        let mut bytes = Vec::new();
        File::open(directory.join(artifact.path.as_str()))
            .map_err(|_| Error::failed("could not open verified JSON resource"))?
            .take(4 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::failed("could not read verified JSON resource"))?;
        if bytes.len() > 4 * 1024 * 1024 {
            return Err(Error::invalid("JSON resource exceeds 4 MiB"));
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::invalid("resource is not valid JSON"))
    })
    .await;
    drop(transfer);
    result
}

pub async fn install(root: &Path, resolved: &Resolved) -> Result<Resolved, Error> {
    resolved.validate()?;
    let directory = resolved.directory(root);
    let manifest = resolved.manifest(root);
    let plan = resolved.clone();
    let prepare = directory.clone();
    let lock = blocking(move || {
        std::fs::create_dir_all(&prepare)
            .map_err(|_| Error::failed("could not create model directory"))?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(prepare.parent().unwrap().join(".download.lock"))
            .map_err(|_| Error::failed("could not open model download lock"))?;
        if !try_lock(&lock) {
            return Err(Error::Busy);
        }
        let missing = plan
            .files
            .iter()
            .filter(|file| !artifact_installed(&prepare, file))
            .fold(0_u64, |total, file| total.saturating_add(file.bytes));
        if missing > 0 && free_disk(&prepare) < missing.saturating_add(512 * 1024 * 1024) {
            return Err(Error::unavailable(
                "not enough free disk for the selected artifacts and 512 MiB reserve",
            ));
        }
        let temporary = manifest.with_extension("part");
        std::fs::write(
            &temporary,
            serde_json::to_vec(&plan).expect("resolved manifest serializes"),
        )
        .map_err(|_| Error::failed("could not cache model manifest"))?;
        std::fs::rename(temporary, manifest)
            .map_err(|_| Error::failed("could not publish model manifest"))?;
        Ok(lock)
    })
    .await?;
    let mut completed = resolved.clone();
    for artifact in &mut completed.files {
        let check = directory.clone();
        let file = artifact.clone();
        if blocking(move || artifact_installed(&check, &file)).await {
            continue;
        }
        let output = directory.join(format!("{}.part", artifact.path.as_str()));
        let parent = output.parent().unwrap().to_owned();
        let log_path = directory.join("download.log");
        let log = blocking(move || {
            std::fs::create_dir_all(parent)
                .map_err(|_| Error::failed("could not create artifact directory"))?;
            File::create(log_path).map_err(|_| Error::failed("could not create download log"))
        })
        .await?;
        let url = format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            resolved.selection.model.repo(),
            resolved.revision,
            artifact.path.as_str()
        );
        let mut command = lifeline()
            .map_err(|_| Error::failed("could not create transfer lifeline"))?
            .guarded(Path::new("/usr/bin/curl"), Some(&lock))
            .map_err(|_| Error::failed("could not prepare artifact transfer"))?;
        command
            .args([
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "-fL",
                "--retry",
                "2",
                "--connect-timeout",
                "20",
                "--max-time",
                "230",
                "--silent",
                "--show-error",
                "-C",
                "-",
                "--max-filesize",
                &artifact.bytes.to_string(),
                "-o",
            ])
            .arg(output)
            .arg(url)
            .stderr(log);
        let child = command
            .spawn()
            .map_err(|_| Error::failed("could not start model download"))?;
        let mut transfer = Transfer {
            child: Some(
                WatchedChild::new(child)
                    .map_err(|_| Error::failed("could not watch model download"))?,
            ),
            temporary: None,
        };
        if !transfer.wait().await? {
            return Err(Error::failed(
                "model transfer failed; partial files are retained for resume. Check the model directory's download.log and HF access/license requirements.",
            ));
        }
        let file = artifact.clone();
        let destination = directory.clone();
        // Keep a lock clone inside the blocking hash job, even if the caller's deadline expires.
        let hashing_lock = lock
            .try_clone()
            .map_err(|_| Error::failed("could not retain verification lock"))?;
        let sha256 = blocking(move || {
            let result = finalize(&destination, &file);
            drop(hashing_lock);
            result
        })
        .await?;
        artifact.sha256 = Some(sha256);
    }
    // Git-object integrity pins downloads before publication. Persist their computed SHA-256
    // as well, so completed receipts never confuse an unknown digest with a verified one.
    let final_manifest = completed.manifest(root);
    let final_plan = completed.clone();
    let commit_lock = lock
        .try_clone()
        .map_err(|_| Error::failed("could not retain manifest lock"))?;
    blocking(move || {
        let temporary = final_manifest.with_extension("part");
        std::fs::write(
            &temporary,
            serde_json::to_vec(&final_plan).expect("verified manifest serializes"),
        )
        .map_err(|_| Error::failed("could not save completed artifact checksums"))?;
        std::fs::rename(temporary, final_manifest)
            .map_err(|_| Error::failed("could not publish completed manifest"))?;
        drop(commit_lock);
        Ok::<_, Error>(())
    })
    .await?;
    Ok(completed)
}
fn artifact_installed(directory: &Path, artifact: &Artifact) -> bool {
    artifact.sha256.is_some()
        && std::fs::metadata(directory.join(artifact.path.as_str()))
            .is_ok_and(|file| file.is_file() && file.len() == artifact.bytes)
}
fn finalize(directory: &Path, artifact: &Artifact) -> Result<String, Error> {
    let target = directory.join(artifact.path.as_str());
    let partial = directory.join(format!("{}.part", artifact.path.as_str()));
    artifact.validate()?;
    let mut input = File::open(&partial)
        .map_err(|_| Error::failed("could not open partial artifact"))?
        .take(artifact.bytes.saturating_add(1));
    let mut sha = Sha256::new();
    let mut git = artifact.git_blob.as_ref().map(|_| {
        let mut hash = Sha1::new();
        hash.update(format!("blob {}\0", artifact.bytes).as_bytes());
        hash
    });
    let mut buffer = [0; 65_536];
    let mut bytes = 0_u64;
    loop {
        let count = input
            .read(&mut buffer)
            .map_err(|_| Error::failed("could not verify artifact"))?;
        if count == 0 {
            break;
        }
        bytes += count as u64;
        sha.update(&buffer[..count]);
        if let Some(hash) = &mut git {
            hash.update(&buffer[..count]);
        }
    }
    let actual_sha256 = format!("{:x}", sha.finalize());
    let sha_matches = artifact
        .sha256
        .as_ref()
        .is_none_or(|expected| actual_sha256 == *expected);
    let git_matches = git
        .zip(artifact.git_blob.as_ref())
        .is_none_or(|(hash, expected)| format!("{:x}", hash.finalize()) == *expected);
    if bytes != artifact.bytes || !sha_matches || !git_matches {
        let _ = std::fs::remove_file(partial);
        return Err(Error::failed(
            "artifact size/checksum mismatch; the invalid partial was discarded, retry to download again",
        ));
    }
    std::fs::rename(partial, target)
        .map_err(|_| Error::failed("could not publish verified artifact"))?;
    Ok(actual_sha256)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ArtifactPath;
    use crate::catalog::Role;
    #[test]
    fn git_resources_are_bound_to_object_identity_and_record_sha256() {
        let root = crate::tests::run_directory();
        let data = b"{\"model_type\":\"qwen3\"}";
        let mut git = Sha1::new();
        git.update(format!("blob {}\0", data.len()));
        git.update(data);
        let mut artifact = Artifact {
            path: ArtifactPath::parse("config.json".into()).unwrap(),
            bytes: data.len() as u64,
            sha256: None,
            git_blob: Some(format!("{:x}", git.finalize())),
            role: Role::Resource,
        };
        std::fs::write(root.join("config.json.part"), data).unwrap();
        assert_eq!(
            finalize(&root, &artifact).unwrap(),
            format!("{:x}", Sha256::digest(data))
        );
        artifact.git_blob = Some("0".repeat(40));
        std::fs::write(root.join("config.json.part"), data).unwrap();
        assert!(finalize(&root, &artifact).is_err());
        assert_eq!(std::fs::read(root.join("config.json")).unwrap(), data);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_verified_complete_artifacts_are_published() {
        let root = crate::tests::run_directory();
        let data = b"model fixture";
        let mut artifact = Artifact {
            path: ArtifactPath::parse("model.gguf".into()).unwrap(),
            bytes: data.len() as u64,
            sha256: Some(format!("{:x}", Sha256::digest(data))),
            git_blob: None,
            role: Role::Model,
        };
        std::fs::write(root.join("model.gguf.part"), data).unwrap();
        finalize(&root, &artifact).unwrap();
        assert!(artifact_installed(&root, &artifact));
        artifact.sha256 = Some("0".repeat(64));
        std::fs::write(root.join("model.gguf.part"), data).unwrap();
        assert!(finalize(&root, &artifact).is_err());
        assert_eq!(std::fs::read(root.join("model.gguf")).unwrap(), data);
        assert!(!root.join("model.gguf.part").exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
