//! Resolve data-only MLX bundles. File containers are evidence, not architecture/head support.
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::api::{ArtifactPath, Backend, Selection, Task};
use crate::catalog::{self, Artifact, Compatibility, Inspection, Resolved, Role};
use crate::service::Error;

#[derive(Deserialize)]
struct Metadata {
    sha: String,
    siblings: Vec<File>,
    #[serde(default)]
    tags: Vec<String>,
}
#[derive(Deserialize)]
struct File {
    rfilename: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default, rename = "blobId")]
    blob: Option<String>,
    #[serde(default)]
    lfs: Option<Lfs>,
}
#[derive(Deserialize)]
struct Lfs {
    sha256: String,
    size: u64,
}

fn artifact(file: &File, role: Role) -> Result<Artifact, Error> {
    let (bytes, sha256, git_blob) = if let Some(lfs) = &file.lfs {
        if file.size.is_some_and(|size| size != lfs.size) {
            return Err(Error::invalid("inconsistent HF artifact size"));
        }
        (lfs.size, Some(lfs.sha256.clone()), None)
    } else {
        (
            file.size
                .ok_or_else(|| Error::unsupported("HF artifact has no size"))?,
            None,
            file.blob.clone(),
        )
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
fn join(prefix: &str, name: &str) -> String {
    if prefix.is_empty() {
        name.into()
    } else {
        format!("{prefix}/{name}")
    }
}
fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(prefix, _)| prefix)
}

fn rejection(selection: &Selection, status: &'static str, reason: impl Into<String>) -> Inspection {
    Inspection {
        model: selection.model.as_str().into(),
        compatibility: Compatibility {
            status,
            reasons: vec![reason.into()],
        },
        formats: vec!["safetensors".into(), "mlx".into()],
        architecture: None,
        task_hints: vec![Task::Generate],
        candidates: vec![],
        resolved: None,
    }
}

/// Only small configuration/index documents are fetched here. Weights stay untouched until
/// installation. Explicit backend selectors never silently fall back to another runtime.
pub async fn inspect(
    root: &Path,
    selection: &Selection,
    value: Value,
) -> Result<Inspection, Error> {
    let has_gguf = value["siblings"].as_array().is_some_and(|files| {
        files.iter().any(|file| {
            file["rfilename"]
                .as_str()
                .is_some_and(|p| p.to_ascii_lowercase().ends_with(".gguf"))
        })
    });
    let has_safetensors = value["siblings"].as_array().is_some_and(|files| {
        files.iter().any(|file| {
            file["rfilename"]
                .as_str()
                .is_some_and(|p| p.ends_with(".safetensors"))
        })
    });
    if selection.backend == Some(Backend::Llama)
        || (!has_safetensors && selection.backend != Some(Backend::Mlx))
    {
        return catalog::inspect(selection, value);
    }
    if has_gguf
        && selection.backend.is_none()
        && !selection
            .file
            .as_ref()
            .is_some_and(|file| file.as_str().ends_with(".safetensors"))
    {
        // An explicit GGUF file is already an unambiguous backend choice.
        if selection
            .file
            .as_ref()
            .is_some_and(|file| file.as_str().to_ascii_lowercase().ends_with(".gguf"))
        {
            return catalog::inspect(selection, value);
        }
        return Ok(rejection(
            selection,
            "ambiguous",
            "Both GGUF and safetensors bundles exist; select backend explicitly instead of guessing",
        ));
    }
    if !Backend::Mlx.available() {
        return Ok(rejection(
            selection,
            "unsupported",
            "Native MLX is available only on macOS with Apple Silicon",
        ));
    }
    let metadata: Metadata =
        serde_json::from_value(value).map_err(|_| Error::failed("invalid HF bundle metadata"))?;
    if !catalog::hex(&metadata.sha, 40) || metadata.siblings.len() > 20000 {
        return Err(Error::failed(
            "MLX metadata requires an immutable revision and bounded inventory",
        ));
    }
    if selection.projector.is_some() || selection.model.quant().is_some() {
        return Ok(rejection(
            selection,
            "unsupported",
            "MLX quantization is defined by the verified bundle configuration; GGUF quantization/projector selectors do not apply",
        ));
    }
    if metadata
        .tags
        .iter()
        .any(|tag| matches!(tag.as_str(), "decision-model" | "systemone" | "clef"))
    {
        return Ok(rejection(
            selection,
            "unsupported",
            "This model requires a native decision-head adapter. The initial MLX backend implements dense causal generation, not custom decision heads; no repository code is executed",
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
    let prefixes: Vec<_> = files
        .keys()
        .filter(|path| path.rsplit('/').next() == Some("config.json"))
        .map(|path| parent(path))
        .filter(|prefix| files.contains_key(join(prefix, "tokenizer.json").as_str()))
        .filter(|prefix| {
            selection
                .file
                .as_ref()
                .is_none_or(|file| parent(file.as_str()) == *prefix)
        })
        .collect();
    if prefixes.len() != 1 {
        return Ok(rejection(
            selection,
            "ambiguous",
            "No unique MLX config/tokenizer bundle exists; select file from exactly one bundle",
        ));
    }
    let prefix = prefixes[0];
    let get = |name: &str, role| -> Result<Artifact, Error> {
        artifact(
            files
                .get(join(prefix, name).as_str())
                .ok_or_else(|| Error::unsupported(format!("missing MLX resource: {name}")))?,
            role,
        )
    };
    let config_file = get("config.json", Role::Resource)?;
    let config =
        crate::transfer::json_resource(root, selection, &metadata.sha, &config_file).await?;
    let architecture = match config_compatibility(&config) {
        Ok(architecture) => architecture,
        Err(reason) => return Ok(rejection(selection, "unsupported", reason)),
    };
    let weight_files: Vec<_> = files
        .values()
        .filter(|file| {
            parent(&file.rfilename) == prefix && file.rfilename.ends_with(".safetensors")
        })
        .copied()
        .collect();
    if weight_files.is_empty() || weight_files.len() > catalog::MAX_FILES - 3 {
        return Ok(rejection(
            selection,
            "unsupported",
            "MLX bundle has no weights or too many shards",
        ));
    }
    let indexes: Vec<_> = files
        .values()
        .filter(|file| {
            parent(&file.rfilename) == prefix && file.rfilename.ends_with(".safetensors.index.json")
        })
        .copied()
        .collect();
    if indexes.len() > 1 {
        return Ok(rejection(
            selection,
            "ambiguous",
            "Multiple safetensors indexes in one directory are not a unique model bundle",
        ));
    }
    let mut resources = vec![config_file, get("tokenizer.json", Role::Resource)?];
    if resources[1].bytes > 32 * 1024 * 1024 {
        return Ok(rejection(
            selection,
            "unsupported",
            "Tokenizer exceeds the native 32 MiB admission limit",
        ));
    }
    if let Some(index) = indexes.first() {
        let index_file = artifact(index, Role::Resource)?;
        let index =
            crate::transfer::json_resource(root, selection, &metadata.sha, &index_file).await?;
        validate_index(&index, &weight_files, prefix)?;
        resources.push(index_file);
    } else if weight_files.len() != 1 {
        return Ok(rejection(
            selection,
            "ambiguous",
            "Multiple weight files require one complete safetensors shard index; unrelated adapters must not be silently loaded",
        ));
    }
    let mut artifacts: Vec<_> = weight_files
        .iter()
        .map(|file| artifact(file, Role::Model))
        .collect::<Result<_, _>>()?;
    if artifacts.iter().any(|file| file.sha256.is_none()) {
        return Ok(rejection(
            selection,
            "unsupported",
            "Native weight shards require advertised SHA-256 integrity metadata",
        ));
    }
    artifacts.sort_by(|a, b| a.path.as_str().cmp(b.path.as_str()));
    if selection
        .file
        .as_ref()
        .is_some_and(|file| file != &artifacts[0].path)
    {
        return Ok(rejection(
            selection,
            "unsupported",
            "file must identify the first model shard in the selected MLX bundle",
        ));
    }
    artifacts.extend(resources);
    let resolved = Resolved {
        selection: selection.clone(),
        backend: Backend::Mlx,
        revision: metadata.sha,
        architecture: Some(architecture),
        task_hints: vec![Task::Generate],
        files: artifacts,
    };
    resolved.validate()?;
    Ok(Inspection::from_resolved(resolved))
}

fn config_compatibility(config: &Value) -> Result<String, String> {
    let architecture = config["model_type"]
        .as_str()
        .ok_or("config.json has no model_type")?;
    let expected = match architecture {
        "qwen2" => "Qwen2ForCausalLM",
        "qwen3" => "Qwen3ForCausalLM",
        _ => {
            return Err(format!(
                "Native MLX architecture {architecture} is not implemented; tensor containers alone do not supply a model/head implementation"
            ));
        }
    };
    if config
        .get("architectures")
        .is_some_and(|value| value != &serde_json::json!([expected]))
    {
        return Err("This architecture uses a different output head; native causal generation cannot substitute for it".into());
    }
    if config
        .get("rope_scaling")
        .is_some_and(|value| !value.is_null())
        || config["use_sliding_window"] == true
    {
        return Err(
            "This MLX adapter does not yet implement RoPE scaling or sliding-window attention"
                .into(),
        );
    }
    if config.get("quantization").is_some()
        && config.get("quantization_config").is_some()
        && config["quantization"] != config["quantization_config"]
    {
        return Err("The bundle contains conflicting quantization configurations".into());
    }
    if let Some(q) = config
        .get("quantization")
        .or_else(|| config.get("quantization_config"))
        .filter(|q| !q.is_null())
    {
        if !q.is_object()
            || q.get("quant_method")
                .is_some_and(|method| method != "affine")
            || q.get("mode").is_some_and(|mode| mode != "affine")
            || !matches!(q["bits"].as_u64(), Some(2 | 4 | 8))
            || !matches!(q["group_size"].as_u64(), Some(32 | 64 | 128))
            || q.as_object()
                .is_some_and(|q| q.values().any(Value::is_object))
        {
            return Err("Only supported uniform MLX affine quantization is implemented, not GPTQ/AWQ/custom packing or per-module overrides".into());
        }
    }
    Ok(architecture.into())
}
fn validate_index(index: &Value, weights: &[&File], prefix: &str) -> Result<(), Error> {
    let mapping = index["weight_map"]
        .as_object()
        .filter(|map| !map.is_empty() && map.len() <= 20000)
        .ok_or_else(|| Error::unsupported("invalid or oversized safetensors weight index"))?;
    let mut required = BTreeSet::new();
    for value in mapping.values() {
        let name = value
            .as_str()
            .ok_or_else(|| Error::invalid("invalid weight index path"))?;
        let parsed = ArtifactPath::parse(name.into())?;
        if name.contains('/') || !parsed.as_str().ends_with(".safetensors") {
            return Err(Error::invalid(
                "weight indexes may refer only to local sibling safetensors shards",
            ));
        }
        required.insert(join(prefix, name));
    }
    let present: BTreeSet<_> = weights.iter().map(|file| file.rfilename.clone()).collect();
    if required != present {
        return Err(Error::unsupported(
            "shard index does not exactly identify the bundle's weight files",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn compatibility_is_architecture_and_head_based_not_repo_based() {
        for architecture in ["qwen2", "qwen3"] {
            assert!(config_compatibility(&json!({"model_type":architecture})).is_ok());
        }
        for config in [
            json!({"model_type":"qwen3_omni_moe"}),
            json!({"model_type":"qwen3","architectures":["JinaForRanking"]}),
            json!({"model_type":"qwen3","quantization":{"quant_method":"gptq","bits":4,"group_size":64}}),
            json!({"model_type":"qwen3","quantization":{"bits":4,"group_size":64,"layer":{"bits":8}}}),
        ] {
            assert!(config_compatibility(&config).is_err());
        }
    }
    #[test]
    fn shard_indexes_cannot_traverse_or_silently_include_another_head() {
        let file = File {
            rfilename: "model.safetensors".into(),
            size: None,
            blob: None,
            lfs: None,
        };
        assert!(
            validate_index(
                &json!({"weight_map":{"w":"model.safetensors"}}),
                &[&file],
                ""
            )
            .is_ok()
        );
        for name in [
            "../model.safetensors",
            "sub/model.safetensors",
            "head.safetensors",
            "code.py",
        ] {
            assert!(validate_index(&json!({"weight_map":{"w":name}}), &[&file], "").is_err());
        }
    }
}
