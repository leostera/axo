//! HF metadata resolves immutable, checksummed GGUF artifacts. Discovery stays with the HF app.
//! Repository metadata is evidence for a load attempt, not a proof of architecture support.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::api::{ArtifactPath, Selection, Task};
use crate::service::Error;

pub const MAX_FILES: usize = 128;
pub const MAX_DOWNLOAD_BYTES: u64 = 64 * 1024 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Model,
    Projector,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Artifact {
    pub path: ArtifactPath,
    pub bytes: u64,
    pub sha256: String,
    pub role: Role,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Resolved {
    pub selection: Selection,
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
            || self
                .files
                .iter()
                .any(|file| !hex(&file.sha256, 64) || file.bytes == 0)
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
        Ok(())
    }
    pub fn download_bytes(&self) -> u64 {
        self.files
            .iter()
            .fold(0_u64, |total, file| total.saturating_add(file.bytes))
    }
    pub fn vision(&self) -> bool {
        self.files.iter().any(|file| file.role == Role::Projector)
    }
    pub fn source(&self) -> Value {
        json!({"repo":self.selection.model.repo(),"revision":self.revision,"file":self.files[0].path,"sha256":self.files[0].sha256,"files":self.files})
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
fn hex(value: &str, len: usize) -> bool {
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
        Self { model: resolved.selection.model.as_str().into(), compatibility: Compatibility { status: "candidate", reasons: vec!["GGUF artifacts are available; architecture, task and memory compatibility must still be tested by loading the pinned runtime".into()] }, formats: vec!["gguf".into()], architecture: resolved.architecture.clone(), task_hints: resolved.task_hints.clone(), candidates: resolved.files.iter().map(|file| file.path.as_str().into()).collect(), resolved: Some(resolved) }
    }
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
                    sha256: lfs.sha256,
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
