//! Axo-owned Core ML worker. Source compilation and inference are embedded, not delegated to a server.
#[cfg(target_os = "macos")]
mod native_worker;

#[cfg(target_os = "macos")]
mod apple {
    use super::native_worker;
    use serde::Deserialize;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    #[derive(Deserialize)]
    #[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
    enum Request {
        Health,
        Describe,
        Predict {
            features: Value,
            outputs: Option<Vec<String>>,
        },
    }

    pub async fn run() -> Result<(), String> {
        native_worker::watch_owner()?;
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        if args.len() == 1 && args[0] == "--capabilities" {
            let probe = axo_coreml::probe()?;
            println!(
                "{}",
                json!({
                    "name": "coreml", "available": probe["available"], "version": probe["version"],
                    "formats": ["mlmodel", "mlpackage"], "tasks": ["predict"], "inputs": ["features", "image"], "recognizedArchitectures": [],
                "tensorDtypes": ["float32", "int32"], "maxTensorElements": 4096, "maxFeatures": 32,
                    "devices": probe["devices"], "computePolicy": probe["compute_policy"], "osVersion": probe["os_version"],
                    "reason": "Stateless named-feature prediction using built-in Core ML models and reviewed flat ML Programs. No custom code, state or generation adapter. Compatibility is verified on load."
                })
            );
            return Ok(());
        }
        if args.len() != 4 || args[0] != "--model" || args[2] != "--socket" {
            return Err(
                "usage: axod-infer-coreml --model <verified-source> --socket <private-socket>"
                    .into(),
            );
        }
        let model_path = PathBuf::from(&args[1]);
        let socket = PathBuf::from(&args[3]);
        if !model_path.is_absolute() || !socket.is_absolute() {
            return Err("worker paths must be absolute".into());
        }
        let mut model = axo_coreml::Model::load(&model_path, &socket.with_extension("work"))?;
        native_worker::serve(
            &socket,
            24 * 1024 * 1024,
            |body| match serde_json::from_slice::<Request>(body) {
                Ok(Request::Health) => Ok(json!({"ready": true})),
                Ok(Request::Describe) => model.description(),
                Ok(Request::Predict { features, outputs }) => {
                    model.predict(&features, outputs.as_deref())
                }
                Err(_) => Err("invalid native prediction request".into()),
            },
        )
        .await
    }
}

fn main() {
    #[cfg(target_os = "macos")]
    {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("worker executor");
        if let Err(error) = runtime.block_on(apple::run()) {
            eprintln!("event=infer.coreml_failed reason={error}");
            std::process::exit(1);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("Core ML requires macOS");
        std::process::exit(1);
    }
}
