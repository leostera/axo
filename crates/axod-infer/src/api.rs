//! Parsed inference operations: model names select HF artifacts, never code or runtime flags.
use std::collections::BTreeMap;

use axo_protocol::asset::Attachment;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};

use crate::service::Error;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ModelRef(String);
impl ModelRef {
    pub fn parse(value: String) -> Result<Self, Error> {
        let source = value
            .strip_prefix("hf:")
            .ok_or_else(|| Error::invalid("model must be hf:owner/repo[:quant][@revision]"))?;
        if source.len() > 256 {
            return Err(Error::invalid("model reference is too long"));
        }
        let (repository, revision) = source.split_once('@').unwrap_or((source, "main"));
        let (repo, quant) = repository.split_once(':').unwrap_or((repository, ""));
        let parts: Vec<_> = repo.split('/').collect();
        if parts.len() != 2
            || parts.iter().any(|part| !component(part))
            || !component(revision)
            || (!quant.is_empty() && !component(quant))
        {
            return Err(Error::invalid(
                "invalid Hugging Face repository, quantization or revision",
            ));
        }
        Ok(Self(value))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn repo(&self) -> &str {
        self.0[3..]
            .split('@')
            .next()
            .unwrap()
            .split(':')
            .next()
            .unwrap()
    }
    pub fn revision(&self) -> &str {
        self.0
            .split_once('@')
            .map_or("main", |(_, revision)| revision)
    }
    pub fn quant(&self) -> Option<&str> {
        self.0
            .split('@')
            .next()
            .unwrap()
            .split_once(':')
            .and_then(|(_, rest)| rest.split_once(':').map(|(_, quant)| quant))
    }
}
impl<'de> Deserialize<'de> for ModelRef {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}
fn component(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ArtifactPath(String);
impl ArtifactPath {
    pub fn parse(value: String) -> Result<Self, Error> {
        if value.len() > 512
            || !value.to_ascii_lowercase().ends_with(".gguf")
            || value.split('/').any(|part| !component(part))
        {
            return Err(Error::invalid(
                "artifact paths must be relative GGUF paths without traversal",
            ));
        }
        Ok(Self(value))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl<'de> Deserialize<'de> for ArtifactPath {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    pub model: ModelRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<ArtifactPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projector: Option<ArtifactPath>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Task {
    Generate,
    Classify,
    Embed,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(untagged)]
pub enum Image {
    Data(String),
    Asset(Attachment),
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum Question {
    Noul {
        instructions: String,
    },
    Choice {
        instructions: String,
        criteria: BTreeMap<String, Option<String>>,
    },
    Score {
        instructions: String,
        criteria: Vec<String>,
    },
}

#[derive(Debug)]
pub enum Input {
    Generate {
        text: String,
        images: Vec<Image>,
        max_tokens: u32,
    },
    Classify {
        state: Value,
        images: Vec<Image>,
        questions: BTreeMap<String, Question>,
    },
    Embed {
        text: String,
    },
}
impl Input {
    pub fn task(&self) -> Task {
        match self {
            Self::Generate { .. } => Task::Generate,
            Self::Classify { .. } => Task::Classify,
            Self::Embed { .. } => Task::Embed,
        }
    }
    pub fn images(&self) -> &[Image] {
        match self {
            Self::Generate { images, .. } | Self::Classify { images, .. } => images,
            _ => &[],
        }
    }
    pub fn replace_assets(&mut self, urls: &BTreeMap<String, String>) -> Result<(), Error> {
        let images = match self {
            Self::Generate { images, .. } | Self::Classify { images, .. } => images,
            _ => return Ok(()),
        };
        for image in images {
            if let Image::Asset(attachment) = image {
                *image = Image::Data(
                    urls.get(&attachment.asset.to_string())
                        .ok_or_else(|| Error::invalid("image asset was not resolved"))?
                        .clone(),
                );
            }
        }
        Ok(())
    }
    pub fn image_urls(&self) -> Result<Vec<&str>, Error> {
        self.images()
            .iter()
            .map(|image| match image {
                Image::Data(data) => Ok(data.as_str()),
                _ => Err(Error::invalid(
                    "image assets must be fetched before inference",
                )),
            })
            .collect()
    }
}

#[derive(Debug)]
pub enum Request {
    Capabilities,
    List,
    Info(Selection),
    Install(Selection),
    Load(Selection, Task),
    Unload(Selection),
    Run(Selection, Input),
}
impl Request {
    pub fn parse(value: Value) -> Result<Self, Error> {
        let object = value
            .as_object()
            .ok_or_else(|| Error::invalid("ai request must be an object"))?;
        let op = object
            .get("op")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::invalid("ai request needs an operation"))?;
        let allowed: &[&str] = match op {
            "capabilities" | "list" => &["op"],
            "info" | "install" | "unload" => &["op", "model", "file", "projector"],
            "load" => &["op", "model", "file", "projector", "task"],
            "run" => &[
                "op",
                "model",
                "file",
                "projector",
                "task",
                "input",
                "maxTokens",
            ],
            _ => return Err(Error::invalid("unknown ai operation")),
        };
        if object.keys().any(|key| !allowed.contains(&key.as_str())) {
            return Err(Error::invalid("unknown ai request field"));
        }
        if op == "capabilities" {
            return Ok(Self::Capabilities);
        }
        if op == "list" {
            return Ok(Self::List);
        }
        let selection: Selection = serde_json::from_value(json!({"model":value["model"], "file":value.get("file"), "projector":value.get("projector")}))
            .map_err(|error| Error::invalid(format!("invalid model selection: {error}")))?;
        let task: Task =
            serde_json::from_value(value.get("task").cloned().unwrap_or(json!("generate")))
                .map_err(|_| Error::invalid("task must be generate, classify or embed"))?;
        Ok(match op {
            "info" => Self::Info(selection),
            "install" => Self::Install(selection),
            "load" => Self::Load(selection, task),
            "unload" => Self::Unload(selection),
            "run" => Self::Run(
                selection,
                parse_input(task, &value["input"], value.get("maxTokens"))?,
            ),
            _ => unreachable!(),
        })
    }
    pub fn input_mut(&mut self) -> Option<&mut Input> {
        match self {
            Self::Run(_, input) => Some(input),
            _ => None,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TextInput {
    text: String,
    #[serde(default)]
    images: Vec<Image>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClassifyInput {
    state: Value,
    #[serde(default)]
    images: Vec<Image>,
    questions: BTreeMap<String, Question>,
}
fn parse_input(task: Task, value: &Value, tokens: Option<&Value>) -> Result<Input, Error> {
    let input = match task {
        Task::Generate | Task::Embed => {
            let value = if value.is_string() {
                json!({"text":value})
            } else {
                value.clone()
            };
            let input: TextInput = serde_json::from_value(value)
                .map_err(|_| Error::invalid("input must be text or {text, images?}"))?;
            if input.text.is_empty() || input.text.len() > 32768 {
                return Err(Error::invalid("input text must be 1 to 32768 UTF-8 bytes"));
            }
            if task == Task::Embed {
                if !input.images.is_empty() || tokens.is_some() {
                    return Err(Error::invalid(
                        "text embeddings do not accept images or maxTokens",
                    ));
                }
                Input::Embed { text: input.text }
            } else {
                let max = tokens
                    .map_or(Some(512), Value::as_u64)
                    .filter(|max| (1..=4096).contains(max))
                    .ok_or_else(|| Error::invalid("maxTokens must be 1 to 4096"))?;
                Input::Generate {
                    text: input.text,
                    images: input.images,
                    max_tokens: max as u32,
                }
            }
        }
        Task::Classify => {
            if tokens.is_some() {
                return Err(Error::invalid("classify does not accept maxTokens"));
            }
            let input: ClassifyInput = serde_json::from_value(value.clone()).map_err(|_| {
                Error::invalid("classify input needs state, questions and optional images")
            })?;
            if serde_json::to_vec(&input.state).map_or(true, |state| state.len() > 32768)
                || input.questions.is_empty()
                || input.questions.len() > 16
            {
                return Err(Error::invalid(
                    "classify accepts state up to 32768 bytes and 1 to 16 questions",
                ));
            }
            for (id, question) in &input.questions {
                if !component(id) || id.len() > 64 {
                    return Err(Error::invalid("invalid question id"));
                }
                let (Question::Noul { instructions }
                | Question::Choice { instructions, .. }
                | Question::Score { instructions, .. }) = question;
                if instructions.is_empty() || instructions.len() > 4096 {
                    return Err(Error::invalid(
                        "question instructions must be 1 to 4096 bytes",
                    ));
                }
                match question {
                    Question::Choice { criteria, .. }
                        if !(2..=32).contains(&criteria.len())
                            || criteria.iter().any(|(id, text)| {
                                !component(id)
                                    || id.len() > 64
                                    || text.as_ref().is_some_and(|s| s.len() > 4096)
                            }) =>
                    {
                        return Err(Error::invalid("choice needs 2 to 32 named criteria"));
                    }
                    Question::Score { criteria, .. }
                        if !(2..=10).contains(&criteria.len())
                            || criteria.iter().any(|s| s.is_empty() || s.len() > 4096) =>
                    {
                        return Err(Error::invalid("score needs 2 to 10 descriptions"));
                    }
                    _ => {}
                }
            }
            Input::Classify {
                state: input.state,
                images: input.images,
                questions: input.questions,
            }
        }
    };
    if input.images().len() > 4 {
        return Err(Error::invalid("at most four images per request"));
    }
    let mut bytes = 0;
    for image in input.images() {
        match image {
            Image::Data(data) => {
                let (prefix, content) = data.split_once(',').ok_or_else(|| {
                    Error::invalid("images must be base64 data URLs or image attachments")
                })?;
                if !matches!(
                    prefix,
                    "data:image/png;base64" | "data:image/jpeg;base64" | "data:image/webp;base64"
                ) || content.len() > 12 * 1024 * 1024
                    || content.is_empty()
                    || content.len() % 4 != 0
                    || !content
                        .trim_end_matches('=')
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
                    || content.len() - content.trim_end_matches('=').len() > 2
                {
                    return Err(Error::invalid(
                        "images must be PNG/JPEG/WebP base64 data URLs, at most 8 MiB decoded",
                    ));
                }
                let decoded =
                    content.len() / 4 * 3 - (content.len() - content.trim_end_matches('=').len());
                if decoded > 8 * 1024 * 1024 {
                    return Err(Error::invalid("an image exceeds 8 MiB decoded"));
                }
                bytes += decoded;
            }
            Image::Asset(asset) => {
                if !matches!(
                    asset.mime_type.as_str(),
                    "image/png" | "image/jpeg" | "image/webp"
                ) || asset.size == 0
                    || asset.size > 8 * 1024 * 1024
                {
                    return Err(Error::invalid(
                        "image attachments must be PNG/JPEG/WebP, at most 8 MiB",
                    ));
                }
                bytes += asset.size as usize;
            }
        }
    }
    if bytes > 16 * 1024 * 1024 {
        return Err(Error::invalid("images exceed the 16 MiB input budget"));
    }
    Ok(input)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn references_are_generic_not_executable_paths() {
        for name in [
            "hf:ggml-org/gemma-3-270m-it-GGUF",
            "hf:ggml-org/Clef-Flash-GGUF:Q4_K_M",
            "hf:mlx-community/clef-omni-4bit@abc123",
        ] {
            assert!(ModelRef::parse(name.into()).is_ok());
        }
        for name in [
            "https://example.com/m.gguf",
            "hf:../repo",
            "hf:org/repo?x=1",
            "hf:org/repo@../../etc",
            "hf:org/repo;cmd",
        ] {
            assert!(ModelRef::parse(name.into()).is_err());
        }
        let model = ModelRef::parse("hf:org/repo:Q8_0@abc".into()).unwrap();
        assert_eq!(
            (model.repo(), model.quant(), model.revision()),
            ("org/repo", Some("Q8_0"), "abc")
        );
    }
    #[test]
    fn all_tasks_parse_but_invalid_fields_are_rejected_before_effects() {
        for (task, input) in [
            ("generate", json!("hello")),
            ("embed", json!({"text":"hello"})),
            (
                "classify",
                json!({"state":"x","questions":{"q":{"type":"noul","instructions":"safe?"}}}),
            ),
        ] {
            assert!(
                Request::parse(json!({"op":"run","model":"hf:any/repo","task":task,"input":input}))
                    .is_ok()
            );
        }
        for value in [
            json!({"op":"info","model":"hf:org/repo","url":"https://evil"}),
            json!({"op":"run","model":"hf:org/repo","input":"x","maxTokens":0}),
            json!({"op":"run","model":"hf:org/repo","input":{"text":"x","images":["file:///etc/passwd"]}}),
        ] {
            assert!(Request::parse(value).is_err());
        }
    }
}
