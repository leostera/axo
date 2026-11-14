//! Resolve immutable, data-only Core ML source bundles. Metadata inspection never compiles a graph.
use crate::api::{ArtifactPath, Backend, Selection, Task};
use crate::catalog::{self, Artifact, Compatibility, Inspection, Resolved, Role};
use crate::service::Error;
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Deserialize)]
struct Metadata {
    sha: String,
    siblings: Vec<File>,
}
#[derive(Deserialize)]
struct File {
    rfilename: String,
    size: Option<u64>,
    #[serde(rename = "blobId")]
    blob: Option<String>,
    lfs: Option<Lfs>,
}
#[derive(Deserialize)]
struct Lfs {
    sha256: String,
    size: u64,
}
fn artifact(file: &File, role: Role) -> Result<Artifact, Error> {
    let (bytes, sha256, git_blob) = match &file.lfs {
        Some(lfs) => {
            if file.size.is_some_and(|size| size != lfs.size) {
                return Err(Error::invalid("inconsistent HF artifact size"));
            }
            (lfs.size, Some(lfs.sha256.clone()), None)
        }
        None => (
            file.size
                .ok_or_else(|| Error::unsupported("Core ML resource has no size"))?,
            None,
            file.blob.clone(),
        ),
    };
    let artifact = Artifact {
        path: ArtifactPath::parse(file.rfilename.clone())?,
        bytes,
        sha256,
        git_blob,
        role,
    };
    artifact.validate()?;
    Ok(artifact)
}
fn rejection(
    selection: &Selection,
    status: &'static str,
    reason: impl Into<String>,
    candidates: Vec<String>,
) -> Inspection {
    Inspection {
        model: selection.model.as_str().into(),
        compatibility: Compatibility {
            status,
            reasons: vec![reason.into()],
        },
        formats: vec!["mlmodel".into(), "mlpackage".into()],
        architecture: None,
        task_hints: vec![Task::Predict],
        candidates,
        resolved: None,
    }
}
fn relative(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && value.split('/').all(|part| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
}
fn package(path: &str) -> Option<&str> {
    path.find(".mlpackage/")
        .map(|position| &path[..position + ".mlpackage".len()])
}
fn model_path(package: &str, manifest: &Value) -> Result<String, Error> {
    let entries = manifest["itemInfoEntries"]
        .as_object()
        .filter(|entries| !entries.is_empty() && entries.len() <= catalog::MAX_FILES)
        .ok_or_else(|| Error::unsupported("invalid Core ML package item inventory"))?;
    for entry in entries.values() {
        if !entry["path"].as_str().is_some_and(relative) {
            return Err(Error::unsupported(
                "Core ML package paths must remain relative and traversal-free",
            ));
        }
    }
    let id = manifest["rootModelIdentifier"]
        .as_str()
        .ok_or_else(|| Error::unsupported("missing Core ML package root"))?;
    let path = entries
        .get(id)
        .and_then(|entry| entry["path"].as_str())
        .filter(|path| path.ends_with(".mlmodel"))
        .ok_or_else(|| Error::unsupported("Core ML package root must be a source .mlmodel"))?;
    Ok(format!("{package}/Data/{path}"))
}

pub async fn inspect(
    root: &Path,
    selection: &Selection,
    value: Value,
) -> Result<Inspection, Error> {
    if !Backend::CoreMl.available() {
        return Ok(rejection(
            selection,
            "unsupported",
            "Native Core ML requires macOS; inspect capabilities on a Mac host",
            vec![],
        ));
    }
    if selection.projector.is_some() || selection.model.quant().is_some() {
        return Ok(rejection(
            selection,
            "unsupported",
            "Core ML quantization belongs to its source package; GGUF quantization and projector selectors do not apply",
            vec![],
        ));
    }
    let metadata: Metadata =
        serde_json::from_value(value).map_err(|_| Error::failed("invalid HF Core ML metadata"))?;
    if !catalog::hex(&metadata.sha, 40) || metadata.siblings.len() > 20000 {
        return Err(Error::failed(
            "Core ML inspection requires an immutable revision and bounded inventory",
        ));
    }
    let files: BTreeMap<_, _> = metadata
        .siblings
        .iter()
        .map(|file| (file.rfilename.as_str(), file))
        .collect();
    if files.len() != metadata.siblings.len() {
        return Err(Error::invalid("duplicate HF artifact paths"));
    }
    let candidates: Vec<String> = files
        .keys()
        .filter_map(|path| {
            if path.ends_with(".mlpackage/Manifest.json") {
                Some(path.trim_end_matches("/Manifest.json").to_owned())
            } else if path.ends_with(".mlmodel")
                && package(path).is_none()
                && !path.contains(".mlmodelc/")
            {
                Some((*path).to_owned())
            } else {
                None
            }
        })
        .collect();
    let selected: Vec<_> = candidates
        .iter()
        .filter(|candidate| {
            selection.file.as_ref().is_none_or(|file| {
                file.as_str() == candidate.as_str()
                    || (file.as_str().ends_with(".mlmodel")
                        && package(file.as_str()) == Some(candidate.as_str()))
            })
        })
        .collect();
    if selected.len() != 1 {
        return Ok(rejection(
            selection,
            if candidates.is_empty() {
                "unsupported"
            } else {
                "ambiguous"
            },
            "Select exactly one source .mlmodel or .mlpackage with file; downloaded compiled models are not accepted",
            candidates,
        ));
    }
    let entry = selected[0];
    ArtifactPath::parse(entry.clone())?;
    let mut artifacts;
    if entry.ends_with(".mlpackage") {
        let manifest = artifact(
            files
                .get(format!("{entry}/Manifest.json").as_str())
                .unwrap(),
            Role::Resource,
        )?;
        if manifest.bytes > 1024 * 1024 {
            return Err(Error::unsupported("Core ML package manifest exceeds 1 MiB"));
        }
        let json =
            crate::transfer::json_resource(root, selection, &metadata.sha, &manifest).await?;
        let primary = model_path(entry, &json)?;
        let model = files.get(primary.as_str()).ok_or_else(|| {
            Error::unsupported("Core ML package root is missing from the pinned repository")
        })?;
        artifacts = vec![artifact(model, Role::Model)?];
        let prefix = format!("{entry}/");
        for file in files
            .values()
            .filter(|file| file.rfilename.starts_with(&prefix) && file.rfilename != primary)
        {
            if ![".json", ".bin"]
                .iter()
                .any(|suffix| file.rfilename.ends_with(suffix))
            {
                return Err(Error::unsupported(
                    "Core ML packages accept one source graph and JSON/binary resources only; custom code and nested model packages are unsupported",
                ));
            }
            artifacts.push(artifact(file, Role::Resource)?);
        }
        if !artifacts
            .iter()
            .any(|artifact| artifact.path == manifest.path)
        {
            return Err(Error::invalid("missing Core ML package manifest"));
        }
        if selection
            .file
            .as_ref()
            .is_some_and(|file| file.as_str() != entry.as_str() && file.as_str() != primary)
        {
            return Err(Error::invalid(
                "explicit Core ML file is not the package root model",
            ));
        }
    } else {
        artifacts = vec![artifact(files.get(entry.as_str()).unwrap(), Role::Model)?];
    }
    let resolved = Resolved {
        selection: selection.clone(),
        backend: Backend::CoreMl,
        revision: metadata.sha,
        architecture: None,
        task_hints: vec![Task::Predict],
        files: artifacts,
    };
    resolved.validate()?;
    let mut inspection = Inspection::from_resolved(resolved);
    inspection.formats = vec![
        if entry.ends_with(".mlpackage") {
            "mlpackage"
        } else {
            "mlmodel"
        }
        .into(),
    ];
    inspection.compatibility.reasons = vec!["Pinned source bundle found. Built-in graph operations, external resources, native features and task compatibility are checked after verified installation, before compilation; no repository code is executed".into()];
    Ok(inspection)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn package_roots_and_all_resource_paths_are_parsed_not_guessed() {
        let manifest = json!({"rootModelIdentifier":"root","itemInfoEntries":{"root":{"path":"com.apple.CoreML/model.mlmodel"},"weights":{"path":"com.apple.CoreML/weights"}}});
        assert_eq!(
            model_path("tiny.mlpackage", &manifest).unwrap(),
            "tiny.mlpackage/Data/com.apple.CoreML/model.mlmodel"
        );
        for path in [
            "../escape",
            "/etc/passwd",
            "a/../b",
            "a/%2e%2e/b",
            "https://example.com/x",
            "a\\b",
        ] {
            let mut bad = manifest.clone();
            bad["itemInfoEntries"]["weights"]["path"] = json!(path);
            assert!(model_path("tiny.mlpackage", &bad).is_err(), "{path}");
        }
        assert_eq!(
            package("variants/tiny.mlpackage/Data/model.mlmodel"),
            Some("variants/tiny.mlpackage")
        );
        assert_eq!(package("tiny.mlmodel"), None);
    }
}
