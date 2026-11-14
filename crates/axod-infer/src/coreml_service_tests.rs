use super::*;

#[tokio::test]
#[cfg(target_os = "macos")]
#[ignore = "requires public HF access and the embedded Core ML helper"]
async fn real_coreml_service_resolves_installs_describes_predicts_and_retires() {
    use std::os::unix::fs::symlink;
    let root = crate::tests::run_directory();
    let helper = std::fs::canonicalize(std::env::var("AXO_TEST_COREML_HELPER").unwrap()).unwrap();
    symlink(helper, root.join("axod-infer-coreml")).unwrap();
    let models = PathBuf::from(
        std::env::var("AXO_TEST_COREML_CACHE")
            .unwrap_or_else(|_| "/tmp/axo-native-coreml-models".into()),
    );
    let service = Service::new(root.join("axod-infer"), models, root.join("ai"));
    let model = "hf:apple/coreml-FastViT-T8@b42811edaa9f7ca6d79eeada204227704484c881";
    let request = |value| Request::parse(value).unwrap();
    let info = service
        .execute(request(json!({"op":"info","model":model})), 240000)
        .await
        .unwrap();
    assert_eq!(info["info"]["compatibility"]["status"], "candidate");
    assert_eq!(info["info"]["resolved"]["backend"], "coreml");
    assert_eq!(info["info"]["resolved"]["taskHints"], json!(["predict"]));
    let loaded = service
        .execute(
            request(json!({"op":"load","model":model,"task":"predict"})),
            240000,
        )
        .await
        .unwrap();
    assert_eq!(loaded["description"]["inputs"]["image"]["type"], "image");
    assert_eq!(loaded["source"]["entrypoint"], "FastViTT8F16.mlpackage");
    assert!(
        loaded["source"]["files"]
            .as_array()
            .unwrap()
            .iter()
            .all(|file| file["sha256"].as_str().is_some_and(|sha| sha.len() == 64))
    );
    let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let run = json!({"op":"run","model":model,"task":"predict","input":{"features":{"image":{"type":"image","image":image}},"outputs":["classLabel"]}});
    let first = service.execute(request(run.clone()), 240000).await.unwrap();
    assert_eq!(first["task"], "predict");
    assert_eq!(first["outputs"]["classLabel"]["type"], "string");
    assert_eq!(first["outputs"].as_object().unwrap().len(), 1);
    let pid = match &service.state.lock().await.active.as_ref().unwrap().runtime {
        Runtime::CoreMl(process) => process.pid().unwrap(),
        _ => panic!("wrong backend"),
    };
    let again = service.execute(request(run), 240000).await.unwrap();
    assert_eq!(again["outputs"], first["outputs"]);
    match &service.state.lock().await.active.as_ref().unwrap().runtime {
        Runtime::CoreMl(process) => assert_eq!(process.pid(), Some(pid)),
        _ => panic!("wrong backend"),
    };
    let invalid = json!({"op":"run","model":model,"task":"predict","input":{"features":{},"outputs":["missing"]}});
    assert!(service.execute(request(invalid), 240000).await.is_err());
    assert!(service.state.lock().await.active.is_none());
    // SAFETY: signal zero only probes the worker that service retirement just reaped.
    assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    assert!(!root.join("ai/coreml.work").exists());
    service
        .execute(
            request(json!({"op":"load","model":model,"task":"predict"})),
            240000,
        )
        .await
        .unwrap();
    service
        .execute(request(json!({"op":"unload","model":model})), 240000)
        .await
        .unwrap();
    assert!(!root.join("ai/coreml.work").exists());
    std::fs::remove_dir_all(root).unwrap();
}
