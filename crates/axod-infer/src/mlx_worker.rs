//! Axo-owned, killable inference worker embedding MLX directly. No runtime installers,
//! networking, Python, model plugins or shared safety-judge state.
#[cfg(target_os = "macos")]
mod native_worker;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod apple {
    use std::path::{Path, PathBuf};

    use super::native_worker;
    use axo_mlx::{Model, Runtime};
    use serde::Deserialize;
    use serde_json::{Value, json};
    use tokenizers::Tokenizer;

    const MAX_REQUEST: u64 = 65536;
    const MAX_CONTEXT: usize = 4096;

    #[derive(Deserialize)]
    #[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
    enum Request {
        Health,
        Generate {
            text: String,
            #[serde(rename = "maxTokens")]
            max_tokens: usize,
        },
    }

    struct Generator<'runtime> {
        model: Model<'runtime>,
        tokenizer: Tokenizer,
        architecture: String,
        context: usize,
        eos: Vec<u32>,
    }

    impl<'runtime> Generator<'runtime> {
        fn load(runtime: &'runtime Runtime, directory: &Path) -> Result<Self, String> {
            let tokenizer_path = directory.join("tokenizer.json");
            if std::fs::metadata(&tokenizer_path)
                .map_err(|e| e.to_string())?
                .len()
                > 32 * 1024 * 1024
            {
                return Err("tokenizer.json exceeds the 32 MiB admission limit".into());
            }
            let tokenizer = Tokenizer::from_file(tokenizer_path).map_err(|e| e.to_string())?;
            let model = runtime.load(directory)?;
            let description = model.description()?;
            let architecture = description["model_type"]
                .as_str()
                .ok_or("missing native architecture")?
                .to_owned();
            let context = description["max_input_tokens"]
                .as_u64()
                .ok_or("missing context limit")? as usize;
            // These reviewed architecture adapters use the Qwen message protocol, not arbitrary
            // repository templates or tokenizer Python. Missing protocol tokens are unsupported.
            for token in ["<|im_start|>", "<|im_end|>"] {
                if tokenizer.token_to_id(token).is_none() {
                    return Err(
                        "tokenizer does not implement the reviewed Qwen message protocol".into(),
                    );
                }
            }
            let mut eos: Vec<u32> = ["<|im_end|>", "<|endoftext|>"]
                .iter()
                .filter_map(|token| tokenizer.token_to_id(token))
                .collect();
            let config_path = directory.join("config.json");
            if std::fs::metadata(&config_path)
                .map_err(|e| e.to_string())?
                .len()
                > 1024 * 1024
            {
                return Err("model configuration exceeds 1 MiB".into());
            }
            let config: Value =
                serde_json::from_slice(&std::fs::read(config_path).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            if let Some(value) = config.get("eos_token_id").filter(|value| !value.is_null()) {
                let ids = if let Some(ids) = value.as_array() {
                    ids.clone()
                } else {
                    vec![value.clone()]
                };
                if ids.len() > 16 {
                    return Err("too many model EOS token IDs".into());
                }
                for id in ids {
                    let id = id
                        .as_u64()
                        .filter(|id| {
                            description["vocab_size"]
                                .as_u64()
                                .is_some_and(|vocab| *id < vocab)
                        })
                        .and_then(|id| u32::try_from(id).ok())
                        .ok_or("model EOS token is outside the vocabulary")?;
                    if !eos.contains(&id) {
                        eos.push(id);
                    }
                }
            }
            Ok(Self {
                model,
                tokenizer,
                architecture,
                context: context.min(MAX_CONTEXT),
                eos,
            })
        }

        fn generate(&mut self, text: String, max_tokens: usize) -> Result<Value, String> {
            if text.is_empty() || text.len() > 32768 || !(1..=4096).contains(&max_tokens) {
                return Err(
                    "generation requires 1..32768 UTF-8 input bytes and 1..4096 output tokens"
                        .into(),
                );
            }
            let mut prompt = format!("<|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n");
            // Qwen3's non-thinking generation prefix. This is an explicit native task adapter,
            // not a claim that any checkpoint's custom chat template is supported.
            if self.architecture == "qwen3" {
                prompt.push_str("<think>\n\n</think>\n\n");
            }
            let mut tokens = self
                .tokenizer
                .encode(prompt, false)
                .map_err(|e| e.to_string())?
                .get_ids()
                .to_vec();
            if tokens.is_empty() || tokens.len() >= self.context {
                return Err("input exceeds this model's native context budget".into());
            }
            let mut generated = Vec::new();
            let mut finish_reason = "length";
            for _ in 0..max_tokens {
                if tokens.len() >= self.context {
                    break;
                }
                let prediction = self.model.predict(&json!({"input_ids":{"type":"tensor","dtype":"int32","shape":[1,tokens.len()],"data":tokens}}))?;
                let next = prediction["next_token"]["value"]
                    .as_u64()
                    .and_then(|n| u32::try_from(n).ok())
                    .ok_or("invalid native token result")?;
                if self.eos.contains(&next) {
                    finish_reason = "stop";
                    break;
                }
                tokens.push(next);
                generated.push(next);
            }
            let text = self
                .tokenizer
                .decode(&generated, true)
                .map_err(|e| e.to_string())?;
            if text.len() > 1024 * 1024 {
                return Err("generated text exceeds the response budget".into());
            }
            Ok(json!({"text":text,"finishReason":finish_reason}))
        }
    }

    fn arguments() -> Result<(PathBuf, PathBuf, PathBuf), String> {
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        if args.len() != 6
            || args[0] != "--model"
            || args[2] != "--metallib"
            || args[4] != "--socket"
        {
            return Err("usage: axod-infer-mlx --model <verified-directory> --metallib <packaged-resource> --socket <private-socket>".into());
        }
        let (model, metal, socket) = (
            PathBuf::from(&args[1]),
            PathBuf::from(&args[3]),
            PathBuf::from(&args[5]),
        );
        if !model.is_absolute() || !metal.is_absolute() || !socket.is_absolute() {
            return Err("worker paths must be absolute".into());
        }
        Ok((model, metal, socket))
    }

    pub async fn run() -> Result<(), String> {
        native_worker::watch_owner()?;
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        if args.first().is_some_and(|arg| arg == "--capabilities") {
            let metal = if args.len() == 3 && args[1] == "--metallib" {
                PathBuf::from(&args[2])
            } else if args.len() == 1 {
                let executable = std::env::current_exe().map_err(|e| e.to_string())?;
                let directory = executable
                    .parent()
                    .ok_or("native worker has no directory")?;
                if directory.file_name().is_some_and(|name| name == "Helpers") {
                    directory
                        .parent()
                        .ok_or("native worker has no bundle root")?
                        .join("Resources/MLX/mlx.metallib")
                } else {
                    directory.join("mlx.metallib")
                }
            } else {
                return Err("invalid capability query arguments".into());
            };
            let build = axo_mlx::build_info();
            let probe = Runtime::new(&metal);
            let available = probe.is_ok();
            let reason = match probe {
                Ok(_) => "Dense Qwen2/Qwen3 causal generation with a reviewed native tokenizer adapter; architecture recognition is not a load guarantee.".to_owned(),
                Err(error) => format!("Native MLX device/resource initialization failed: {}", error.chars().take(900).collect::<String>()),
            };
            println!(
                "{}",
                json!({
                    "name":build.name, "available":available, "version":build.version,
                    "commit":build.commit, "formats":["safetensors"], "tasks":["generate"],
                    "recognizedArchitectures":["qwen2","qwen3"], "inputs":["text"],
                    "contextTokens":4096, "kvCache":false,
                    "reason":reason
                })
            );
            return Ok(());
        }
        let (model, metal, socket) = arguments()?;
        let runtime = Runtime::new(&metal)?;
        let mut generator = Generator::load(&runtime, &model)?;
        native_worker::serve(&socket, MAX_REQUEST, |body| {
            match serde_json::from_slice::<Request>(body) {
                Ok(Request::Health) => Ok(json!({"ready": true})),
                Ok(Request::Generate { text, max_tokens }) => generator.generate(text, max_tokens),
                Err(_) => Err("invalid native generation request".into()),
            }
        })
        .await
    }
}

fn main() {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("worker executor");
        if let Err(error) = runtime.block_on(apple::run()) {
            eprintln!("event=infer.mlx_failed reason={error}");
            std::process::exit(1);
        }
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        eprintln!("native MLX requires macOS on Apple Silicon");
        std::process::exit(1);
    }
}
