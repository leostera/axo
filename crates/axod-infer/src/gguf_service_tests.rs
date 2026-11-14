//! Manual packaged-runtime acceptance test: real verified weights, never model code.
use super::*;
use std::os::unix::net::UnixStream;

const MODEL: &str =
    "hf:bartowski/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M@41ba88dbac95fed2528c92514c131d73eb5a174b";

#[tokio::test]
#[ignore = "requires public HF access, a packaged llama.cpp helper, and a driver for CUDA builds"]
async fn real_gguf_service_installs_runs_reuses_and_retires() {
    let root = crate::tests::run_directory();
    let helper = std::fs::canonicalize(std::env::var("AXO_TEST_GGUF_HELPER").unwrap()).unwrap();
    let cache = PathBuf::from(
        std::env::var("AXO_TEST_GGUF_CACHE")
            .unwrap_or_else(|_| "/tmp/axo-linux-gguf-models".into()),
    );
    let service = Service::new(helper, cache, root.join("run"));
    let request = |value| Request::parse(value).unwrap();
    let runtime: Value = serde_json::from_str(RUNTIME).unwrap();
    let info = service
        .execute(request(json!({"op":"info","model":MODEL})), MAX_TIMEOUT_MS)
        .await
        .unwrap();
    assert_eq!(info["info"]["compatibility"]["status"], "candidate");
    let first = service.execute(request(json!({"op":"run","model":MODEL,"input":"Say hello in one short sentence.","maxTokens":32})), MAX_TIMEOUT_MS).await.unwrap();
    assert_eq!(first["source"]["backend"], "llama.cpp");
    assert!(
        first["text"]
            .as_str()
            .is_some_and(|text| !text.trim().is_empty())
    );
    assert!(
        first["source"]["files"]
            .as_array()
            .unwrap()
            .iter()
            .all(|file| file["sha256"].as_str().is_some_and(|hash| hash.len() == 64))
    );
    let pid = || async {
        let state = service.state.lock().await;
        let infer = state.active.as_ref().unwrap().runtime.llama().unwrap();
        crate::peer_pid(&UnixStream::connect(infer.socket()).unwrap()).unwrap()
    };
    let first_pid = pid().await;
    let second = service.execute(request(json!({"op":"run","model":MODEL,"input":"What is two plus two? Answer briefly.","maxTokens":32})), MAX_TIMEOUT_MS).await.unwrap();
    assert!(
        second["text"]
            .as_str()
            .is_some_and(|text| !text.trim().is_empty())
    );
    assert_eq!(
        pid().await,
        first_pid,
        "a resident model must reuse its worker"
    );
    let log = std::fs::read_to_string(root.join("run/infer.log")).unwrap();
    let offloaded = log.lines().find_map(|line| {
        let (_, tail) = line.split_once("offloaded ")?;
        tail.split('/').next()?.parse::<usize>().ok()
    });
    let cpu_only = std::env::var("AXO_TEST_GGUF_CPU_ONLY").as_deref() == Ok("1");
    if cpu_only {
        assert_eq!(offloaded.unwrap_or(0), 0, "CPU test offloaded GPU layers");
        assert!(
            log.lines()
                .any(|line| line.contains("CPU") && line.contains("model buffer size")),
            "CPU test did not load weights on CPU"
        );
    } else if runtime["compiledAccelerator"] == "cuda" {
        assert!(
            log.contains("CUDA0"),
            "CUDA build did not select a CUDA device"
        );
        assert!(
            offloaded.is_some_and(|n| n > 0),
            "CUDA build did not offload any layers"
        );
    }
    service
        .execute(
            request(json!({"op":"unload","model":MODEL})),
            MAX_TIMEOUT_MS,
        )
        .await
        .unwrap();
    assert!(service.state.lock().await.active.is_none());
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while Path::new(&format!("/proc/{first_pid}")).exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "unload left the worker running"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    eprintln!(
        "GGUF acceptance passed: compiledAccelerator={}, cpuOnly={cpu_only}, offloadedLayers={offloaded:?}; verified install, two generations, worker reuse and retirement",
        runtime["compiledAccelerator"]
    );
    std::fs::remove_dir_all(root).unwrap();
}
