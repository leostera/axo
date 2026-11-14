//! HF metadata resolves immutable, checksummed GGUF artifacts. Discovery stays with the HF app.
//! Repository metadata is evidence for a load attempt, not a proof of architecture support.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::api::{ArtifactPath, Backend, Selection, Task};
use crate::service::Error;

pub const MAX_FILES: usize = 128;
pub const MAX_DOWNLOAD_BYTES: u64 = 64 * 1024 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Model,
    Projector,
    Resource,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Artifact {
    pub path: ArtifactPath,
    pub bytes: u64,
    pub sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_blob: Option<String>,
    pub role: Role,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Resolved {
    pub selection: Selection,
    #[serde(default)]
    pub backend: Backend,
    pub revision: String,
    pub architecture: Option<String>,
    pub task_hints: Vec<Task>,
    pub files: Vec<Artifact>,
}
impl Resolved {
    pub fn validate(&self) -> Result<(), Error> {
        if !hex(&self.revision, 40)
            || self.files.is_empty()
            || self.files.len() > MAX_FILES
            || self.files[0].role != Role::Model
            || (self.backend != Backend::CoreMl && self.files[0].sha256.is_none())
            || self
                .selection
                .backend
                .is_some_and(|backend| backend != self.backend)
            || (self.backend == Backend::Llama
                && self
                    .files
                    .iter()
                    .any(|file| !file.path.as_str().to_ascii_lowercase().ends_with(".gguf")))
            || (self.backend == Backend::Mlx
                && !self.files[0].path.as_str().ends_with(".safetensors"))
            || (self.backend == Backend::CoreMl
                && !self.files[0].path.as_str().ends_with(".mlmodel"))
            || self.files.iter().any(|file| file.validate().is_err())
            || self
                .files
                .iter()
                .filter(|file| file.role == Role::Projector)
                .count()
                > 1
            || self.download_bytes() > MAX_DOWNLOAD_BYTES
        {
            return Err(Error::invalid("invalid resolved artifact manifest"));
        }
        let mut paths = std::collections::HashSet::new();
        if self
            .files
            .iter()
            .any(|file| !paths.insert(file.path.as_str()))
        {
            return Err(Error::invalid("duplicate artifact path"));
        }
        if self.selection.file.as_ref().is_some_and(|file| {
            file != &self.files[0].path
                && !(self.backend == Backend::CoreMl && file.as_str() == self.entrypoint())
        }) {
            return Err(Error::invalid(
                "manifest does not match its explicit model artifact",
            ));
        }
        match self.backend {
            Backend::CoreMl => {
                if self.selection.projector.is_some()
                    || self.selection.model.quant().is_some()
                    || self.files.iter().any(|file| file.role == Role::Projector)
                    || self.task_hints != [Task::Predict]
                    || self.files[0].bytes > 256 * 1024 * 1024
                    || self
                        .files
                        .iter()
                        .filter(|file| file.role == Role::Model)
                        .count()
                        != 1
                    || self
                        .files
                        .iter()
                        .filter(|file| file.path.as_str().ends_with(".mlmodel"))
                        .count()
                        != 1
                {
                    return Err(Error::invalid(
                        "Core ML requires one bounded source graph and the predict task",
                    ));
                }
                let entry = self.entrypoint();
                if entry.ends_with(".mlpackage") {
                    let prefix = format!("{entry}/");
                    if self.files.iter().any(|file| {
                        !file.path.as_str().starts_with(&prefix)
                            || (file.role == Role::Resource
                                && ![".json", ".bin"]
                                    .iter()
                                    .any(|suffix| file.path.as_str().ends_with(suffix)))
                    }) || !self.files.iter().any(|file| {
                        file.path.as_str() == format!("{entry}/Manifest.json")
                            && file.bytes <= 1024 * 1024
                    }) {
                        return Err(Error::invalid(
                            "Core ML package resources must remain in one verified data-only bundle",
                        ));
                    }
                } else if self.files.len() != 1 {
                    return Err(Error::invalid(
                        "standalone Core ML sources cannot reference external resources",
                    ));
                }
            }
            Backend::Llama => {
                if self.files.iter().any(|file| file.role == Role::Resource) {
                    return Err(Error::invalid(
                        "GGUF manifests cannot contain native MLX resources",
                    ));
                }
            }
            Backend::Mlx => {
                let prefix = Path::new(self.files[0].path.as_str())
                    .parent()
                    .unwrap_or(Path::new(""));
                if self.selection.projector.is_some()
                    || self.selection.model.quant().is_some()
                    || self.task_hints != [Task::Generate]
                    || self.files.iter().any(|file| {
                        Path::new(file.path.as_str())
                            .parent()
                            .unwrap_or(Path::new(""))
                            != prefix
                            || match file.role {
                                Role::Model => {
                                    !file.path.as_str().ends_with(".safetensors")
                                        || file.sha256.is_none()
                                }
                                Role::Resource => !file.path.as_str().ends_with(".json"),
                                Role::Projector => true,
                            }
                    })
                    || ["config.json", "tokenizer.json"].iter().any(|name| {
                        !self.files.iter().any(|file| {
                            file.role == Role::Resource
                                && Path::new(file.path.as_str()) == prefix.join(name)
                        })
                    })
                {
                    return Err(Error::invalid(
                        "MLX manifests require one local weight/config/tokenizer bundle, without GGUF projectors or quantization selectors",
                    ));
                }
            }
        }
        Ok(())
    }
    pub fn download_bytes(&self) -> u64 {
        self.files
            .iter()
            .fold(0_u64, |total, file| total.saturating_add(file.bytes))
    }
    pub fn entrypoint(&self) -> &str {
        let path = self.files[0].path.as_str();
        if self.backend == Backend::CoreMl {
            if let Some(position) = path.find(".mlpackage/") {
                return &path[..position + ".mlpackage".len()];
            }
        }
        path
    }
    pub fn vision(&self) -> bool {
        self.backend == Backend::CoreMl
            || (self.backend == Backend::Llama
                && self.files.iter().any(|file| file.role == Role::Projector))
    }
    pub fn source(&self) -> Value {
        let mut source = json!({"backend":self.backend,"repo":self.selection.model.repo(),"revision":self.revision,"file":self.files[0].path,"sha256":self.files[0].sha256,"files":self.files});
        if self.backend == Backend::CoreMl {
            source["entrypoint"] = json!(self.entrypoint());
        }
        if let Some(blob) = &self.files[0].git_blob {
            source["gitBlob"] = json!(blob);
        }
        source
    }
    pub fn directory(&self, root: &Path) -> PathBuf {
        root.join("hf")
            .join(selection_key(&self.selection))
            .join(&self.revision)
    }
    pub fn installed(&self, root: &Path) -> bool {
        let directory = self.directory(root);
        self.files.iter().all(|file| {
            std::fs::metadata(directory.join(file.path.as_str()))
                .is_ok_and(|meta| meta.is_file() && meta.len() == file.bytes)
        })
    }
    pub fn manifest(&self, root: &Path) -> PathBuf {
        root.join("hf")
            .join(selection_key(&self.selection))
            .join("resolved.json")
    }
}
impl Artifact {
    pub fn validate(&self) -> Result<(), Error> {
        if self.bytes == 0
            || (self.sha256.is_none() && self.git_blob.is_none())
            || self.sha256.as_ref().is_some_and(|hash| !hex(hash, 64))
            || self.git_blob.as_ref().is_some_and(|hash| !hex(hash, 40))
        {
            return Err(Error::invalid(
                "artifact requires a size and valid SHA-256 or Git blob SHA-1",
            ));
        }
        Ok(())
    }
}
pub(crate) fn hex(value: &str, len: usize) -> bool {
    value.len() == len
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn selection_key(selection: &Selection) -> String {
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(selection).expect("selection serializes"))
    )
}

pub fn cached(root: &Path, selection: &Selection) -> Result<Option<Resolved>, Error> {
    use std::io::Read;
    let path = root
        .join("hf")
        .join(selection_key(selection))
        .join("resolved.json");
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Error::failed("could not read cached model manifest")),
    };
    let mut bytes = Vec::new();
    file.take(256 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::failed("could not read model manifest"))?;
    if bytes.len() > 256 * 1024 {
        return Err(Error::invalid("model manifest is too large"));
    }
    let resolved: Resolved = serde_json::from_slice(&bytes)
        .map_err(|_| Error::invalid("invalid cached model manifest"))?;
    resolved.validate()?;
    if resolved.selection != *selection {
        return Err(Error::invalid(
            "cached manifest does not match model selection",
        ));
    }
    Ok(Some(resolved))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Inspection {
    pub model: String,
    pub compatibility: Compatibility,
    pub formats: Vec<String>,
    pub architecture: Option<String>,
    pub task_hints: Vec<Task>,
    pub candidates: Vec<String>,
    pub resolved: Option<Resolved>,
}
#[derive(Debug, Serialize)]
pub struct Compatibility {
    pub status: &'static str,
    pub reasons: Vec<String>,
}
impl Inspection {
    pub fn from_resolved(resolved: Resolved) -> Self {
        let format = match resolved.backend {
            Backend::Llama => "gguf",
            Backend::Mlx => "mlx",
            Backend::CoreMl => "coreml",
        };
        Self { model: resolved.selection.model.as_str().into(), compatibility: Compatibility { status: "candidate", reasons: vec!["Pinned artifacts are available; architecture, task and memory compatibility must still be tested by loading the native runtime".into()] }, formats: vec![format.into()], architecture: resolved.architecture.clone(), task_hints: resolved.task_hints.clone(), candidates: resolved.files.iter().map(|file| file.path.as_str().into()).collect(), resolved: Some(resolved) }
    }
}

pub async fn inspect_repository(
    root: &Path,
    selection: &Selection,
    value: Value,
) -> Result<Inspection, Error> {
    let paths: Vec<_> = value["siblings"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|file| file["rfilename"].as_str())
        .collect();
    let coreml = paths.iter().any(|path| {
        path.ends_with(".mlpackage/Manifest.json")
            || (path.ends_with(".mlmodel") && !path.contains(".mlmodelc/"))
    });
    let gguf = paths
        .iter()
        .any(|path| path.to_ascii_lowercase().ends_with(".gguf"));
    let mlx = paths.iter().any(|path| path.ends_with(".safetensors"));
    let selected = selection.backend.or_else(|| {
        selection.file.as_ref().and_then(|file| {
            let path = file.as_str();
            if path.ends_with(".mlmodel") || path.ends_with(".mlpackage") {
                Some(Backend::CoreMl)
            } else if path.to_ascii_lowercase().ends_with(".gguf") {
                Some(Backend::Llama)
            } else if path.ends_with(".safetensors") {
                Some(Backend::Mlx)
            } else {
                None
            }
        })
    });
    if selected == Some(Backend::CoreMl) || (selected.is_none() && coreml && !gguf && !mlx) {
        return crate::coreml_catalog::inspect(root, selection, value).await;
    }
    if selected.is_none() && coreml && (gguf || mlx) {
        return Ok(Inspection {model: selection.model.as_str().into(), compatibility: Compatibility {status: "ambiguous", reasons: vec!["Multiple native model formats exist; select backend or an explicit model file instead of guessing".into()]}, formats: [gguf.then_some("gguf"), mlx.then_some("safetensors"), Some("coreml")].into_iter().flatten().map(str::to_owned).collect(), architecture: None, task_hints: vec![Task::Generate, Task::Predict], candidates: vec![], resolved: None});
    }
    crate::mlx_catalog::inspect(root, selection, value).await
}

#[derive(Deserialize)]
struct Metadata {
    sha: String,
    #[serde(default)]
    siblings: Vec<Sibling>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    library_name: Option<String>,
    #[serde(default)]
    config: Value,
    #[serde(default)]
    gguf: Value,
}
#[derive(Deserialize)]
struct Sibling {
    rfilename: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    lfs: Option<Lfs>,
}
#[derive(Deserialize)]
struct Lfs {
    sha256: String,
    size: u64,
}

/// Resolve solely from metadata; never execute repository code or download weights here.
pub fn inspect(selection: &Selection, metadata: Value) -> Result<Inspection, Error> {
    let metadata: Metadata = serde_json::from_value(metadata)
        .map_err(|_| Error::failed("HF returned invalid model metadata"))?;
    if !hex(&metadata.sha, 40) || metadata.siblings.len() > 20_000 {
        return Err(Error::failed(
            "HF metadata has no immutable revision or too many files",
        ));
    }
    let architecture = metadata.gguf["architecture"]
        .as_str()
        .or_else(|| metadata.config["model_type"].as_str())
        .filter(|name| name.len() <= 128)
        .map(str::to_owned);
    let decision = metadata
        .tags
        .iter()
        .any(|tag| matches!(tag.as_str(), "decision-model" | "systemone" | "clef"));
    let embedding = metadata.tags.iter().any(|tag| {
        matches!(
            tag.as_str(),
            "sentence-transformers" | "feature-extraction" | "text-embeddings-inference"
        )
    });
    let task_hints = vec![if decision {
        Task::Classify
    } else if embedding {
        Task::Embed
    } else {
        Task::Generate
    }];
    let mut formats = Vec::new();
    if metadata
        .siblings
        .iter()
        .any(|file| file.rfilename.to_ascii_lowercase().ends_with(".gguf"))
    {
        formats.push("gguf".into());
    }
    if metadata.library_name.as_deref() == Some("mlx")
        || metadata.tags.iter().any(|tag| tag == "mlx")
    {
        formats.push("mlx".into());
    }
    if metadata
        .siblings
        .iter()
        .any(|file| file.rfilename.ends_with(".safetensors"))
    {
        formats.push("safetensors".into());
    }
    let mut artifacts = BTreeMap::new();
    let mut candidates = Vec::new();
    for file in metadata.siblings {
        if !file.rfilename.to_ascii_lowercase().ends_with(".gguf") {
            continue;
        }
        let path = ArtifactPath::parse(file.rfilename)?;
        candidates.push(path.as_str().to_owned());
        if let Some(lfs) = file.lfs.filter(|lfs| {
            hex(&lfs.sha256, 64) && lfs.size > 0 && file.size.is_none_or(|size| size == lfs.size)
        }) {
            let role = if projector(path.as_str()) {
                Role::Projector
            } else {
                Role::Model
            };
            artifacts.insert(
                path.as_str().to_owned(),
                Artifact {
                    path,
                    bytes: lfs.size,
                    sha256: Some(lfs.sha256),
                    git_blob: None,
                    role,
                },
            );
        }
    }
    candidates.sort();
    let rejection = |status, reason: String| Inspection {
        model: selection.model.as_str().into(),
        compatibility: Compatibility {
            status,
            reasons: vec![reason],
        },
        formats: formats.clone(),
        architecture: architecture.clone(),
        task_hints: task_hints.clone(),
        candidates: candidates.clone(),
        resolved: None,
    };
    if !formats.iter().any(|format| format == "gguf") {
        let reason = if formats.iter().any(|format| format == "mlx") {
            "This repository contains MLX weights, not GGUF. This host currently has a llama.cpp backend, not MLX. Models with custom decision heads also need a reviewed task adapter; repository Python is never executed automatically."
        } else {
            "No GGUF artifacts found. This host's llama.cpp backend cannot load raw safetensors/PyTorch weights or execute custom repository code."
        };
        return Ok(rejection("unsupported", reason.into()));
    }
    let models: Vec<_> = artifacts
        .values()
        .filter(|file| {
            file.role == Role::Model
                && split(file.path.as_str()).is_none_or(|(_, index, _)| index == 1)
        })
        .collect();
    let main = if let Some(file) = &selection.file {
        models
            .iter()
            .copied()
            .find(|candidate| candidate.path == *file)
    } else {
        let quant = selection.model.quant();
        let filtered: Vec<_> = models
            .iter()
            .copied()
            .filter(|file| quant.is_none_or(|quant| matches_quant(file.path.as_str(), quant)))
            .collect();
        let best = filtered.iter().map(|file| rank(file.path.as_str())).min();
        let preferred: Vec<_> = filtered
            .into_iter()
            .filter(|file| Some(rank(file.path.as_str())) == best)
            .collect();
        if preferred.len() == 1 {
            preferred.first().copied()
        } else {
            None
        }
    };
    let Some(main) = main else {
        return Ok(rejection("ambiguous", "No unique checksummed model artifact matches. Specify file (the first shard for split models), and optionally projector; candidates lists the repository's GGUF files.".into()));
    };
    if selection
        .model
        .quant()
        .is_some_and(|quant| !matches_quant(main.path.as_str(), quant))
    {
        return Ok(rejection(
            "unsupported",
            "The explicit file conflicts with the reference's quantization selector".into(),
        ));
    }
    let mut files = vec![main.clone()];
    if let Some((prefix, _, total)) = split(main.path.as_str()) {
        if total > MAX_FILES {
            return Ok(rejection(
                "unsupported",
                "Split model has too many shards".into(),
            ));
        }
        for index in 2..=total {
            let name = format!("{prefix}-{index:05}-of-{total:05}.gguf");
            let Some(file) = artifacts.get(&name).filter(|file| file.role == Role::Model) else {
                return Ok(rejection(
                    "unsupported",
                    "Split model is missing a shard or its checksum".into(),
                ));
            };
            files.push(file.clone());
        }
    }
    let projectors: Vec<_> = artifacts
        .values()
        .filter(|file| file.role == Role::Projector)
        .collect();
    let mmproj = if let Some(file) = &selection.projector {
        let Some(projector) = projectors
            .iter()
            .copied()
            .find(|candidate| candidate.path == *file)
        else {
            return Ok(rejection(
                "unsupported",
                "Selected projector is absent or has no SHA-256".into(),
            ));
        };
        Some(projector)
    } else if projectors.len() == 1 {
        projectors.first().copied()
    } else if projectors.len() > 1 {
        // Prefer one Q8_0 projector only when the repository unambiguously provides that variant.
        let q8: Vec<_> = projectors
            .iter()
            .copied()
            .filter(|file| quantization(file.path.as_str()).as_deref() == Some("Q8_0"))
            .collect();
        if q8.len() == 1 {
            q8.first().copied()
        } else {
            return Ok(rejection(
                "ambiguous",
                "Multiple vision projectors found; specify projector explicitly".into(),
            ));
        }
    } else {
        None
    };
    if let Some(projector) = mmproj {
        files.push(projector.clone());
    }
    let resolved = Resolved {
        selection: selection.clone(),
        backend: Backend::Llama,
        revision: metadata.sha,
        architecture,
        task_hints,
        files,
    };
    resolved.validate()?;
    Ok(Inspection::from_resolved(resolved))
}
fn projector(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap().to_ascii_lowercase();
    name.contains("mmproj")
}
fn quantization(path: &str) -> Option<String> {
    let name = path.to_ascii_uppercase();
    [
        "IQ1_S", "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ3_XXS", "IQ3_S", "IQ4_XS", "IQ4_NL", "Q2_K",
        "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_K_S", "Q4_K_M", "Q4_0", "Q4_1", "Q5_K_S", "Q5_K_M",
        "Q5_0", "Q5_1", "Q6_K", "Q8_0", "BF16", "F16", "F32",
    ]
    .iter()
    .find(|quant| name.contains(**quant))
    .map(|quant| (*quant).into())
}
fn matches_quant(path: &str, quant: &str) -> bool {
    let path = path.to_ascii_uppercase();
    let quant = quant.to_ascii_uppercase();
    path.match_indices(&quant).any(|(index, _)| {
        (index == 0 || b"-_/.".contains(&path.as_bytes()[index - 1]))
            && (index + quant.len() == path.len()
                || b"-/.".contains(&path.as_bytes()[index + quant.len()]))
    })
}
fn rank(path: &str) -> usize {
    match quantization(path).as_deref() {
        Some("Q4_K_M") => 0,
        Some("Q8_0") => 1,
        Some("Q4_0") => 2,
        Some("F16") => 3,
        Some("BF16") => 4,
        _ => 5,
    }
}
fn split(path: &str) -> Option<(&str, usize, usize)> {
    let (prefix, suffix) = path.strip_suffix(".gguf")?.rsplit_once('-')?;
    if suffix.len() != 5 {
        return None;
    }
    let total = suffix.parse().ok()?;
    let (prefix, of) = prefix.rsplit_once('-')?;
    if of != "of" {
        return None;
    }
    let (prefix, index) = prefix.rsplit_once('-')?;
    if index.len() != 5 {
        return None;
    }
    let index = index.parse().ok()?;
    if index == 0 || total == 0 || index > total {
        return None;
    }
    Some((prefix, index, total))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ModelRef;
    fn selection(model: &str) -> Selection {
        Selection {
            backend: None,
            model: ModelRef::parse(model.into()).unwrap(),
            file: None,
            projector: None,
        }
    }
    fn file(name: &str) -> Value {
        json!({"rfilename":name,"size":100,"lfs":{"sha256":"a".repeat(64),"size":100}})
    }
    #[test]
    fn arbitrary_gguf_models_resolve_without_a_model_allowlist() {
        for model in ["hf:anyone/new-model", "hf:ggml-org/Clef-Flash-GGUF"] {
            let info = inspect(&selection(model), json!({"sha":"b".repeat(40),"siblings":[file("model-Q8_0.gguf"),file("model-Q4_K_M.gguf"),file("mmproj-Q8_0.gguf")]})).unwrap();
            assert_eq!(info.compatibility.status, "candidate");
            let resolved = info.resolved.unwrap();
            assert_eq!(resolved.files[0].path.as_str(), "model-Q4_K_M.gguf");
            assert!(resolved.vision());
        }
    }
    #[test]
    fn mlx_is_explained_not_rejected_as_the_wrong_model_name() {
        let info = inspect(&selection("hf:mlx-community/clef-omni-4bit"), json!({"sha":"b".repeat(40),"library_name":"mlx","siblings":[{"rfilename":"model.safetensors"}],"tags":["decision-model"]})).unwrap();
        assert_eq!(info.compatibility.status, "unsupported");
        assert!(info.compatibility.reasons[0].contains("not MLX"));
        assert_eq!(info.task_hints, vec![Task::Classify]);
        let future = inspect(
            &selection("hf:org/future:NEW_QUANT"),
            json!({"sha":"b".repeat(40),"siblings":[file("model-NEW_QUANT.gguf")]}),
        )
        .unwrap();
        assert!(
            future.resolved.is_some(),
            "quantization selection is not another allowlist"
        );
    }
    #[test]
    fn shards_missing_hashes_and_ambiguous_artifacts_do_not_silently_load_something_else() {
        let metadata = |files| json!({"sha":"b".repeat(40),"siblings":files});
        assert_eq!(
            inspect(
                &selection("hf:o/r"),
                metadata(vec![file("a-Q8_0.gguf"), file("b-Q8_0.gguf")])
            )
            .unwrap()
            .compatibility
            .status,
            "ambiguous"
        );
        assert_eq!(
            inspect(
                &selection("hf:o/r"),
                metadata(vec![file("m-Q8_0-00001-of-00002.gguf")])
            )
            .unwrap()
            .compatibility
            .status,
            "unsupported"
        );
        let info = inspect(
            &selection("hf:o/r"),
            metadata(vec![
                file("m-Q8_0-00001-of-00002.gguf"),
                file("m-Q8_0-00002-of-00002.gguf"),
            ]),
        )
        .unwrap();
        assert_eq!(info.resolved.unwrap().files.len(), 2);
        assert!(inspect(&selection("hf:o/r"), metadata(vec![file("../bad.gguf")])).is_err());
    }
}
