use super::*;

#[tokio::test]
#[ignore = "requires a checksum-verified public Core ML package"]
async fn real_coreml_process_predicts_and_reaps_before_workspace_cleanup() {
    let root = crate::tests::run_directory();
    let helper = std::fs::canonicalize(std::env::var("AXO_TEST_COREML_HELPER").unwrap()).unwrap();
    let model = std::fs::canonicalize(std::env::var("AXO_TEST_COREML_MODEL").unwrap()).unwrap();
    let mut process = Process::new(helper.clone(), Kind::CoreMl, model.clone(), root.clone());
    process.ensure_running().await.unwrap();
    let description = process
        .request(&json!({"op":"describe"}), Duration::from_secs(5))
        .await
        .unwrap();
    assert_eq!(description["inputs"]["image"]["type"], "image");
    let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let request = json!({"op":"predict","features":{"image":{"type":"image","data_url":image}},"outputs":["classLabel"]});
    let prediction = process
        .request(&request, Duration::from_secs(30))
        .await
        .unwrap();
    assert_eq!(prediction["classLabel"]["type"], "string");
    assert_eq!(prediction.as_object().unwrap().len(), 1);
    let workspace = process.workspace();
    assert!(
        std::fs::read_dir(&workspace).unwrap().next().is_some(),
        "compiled assets are owned inside the worker workspace"
    );
    let invalid = json!({"op":"predict","features":{},"outputs":["missing"]});
    assert!(
        process
            .request(&invalid, Duration::from_secs(5))
            .await
            .is_err()
    );
    assert!(
        process.loaded().await,
        "a rejected input does not crash the worker"
    );
    let pid = process.pid().unwrap();
    process.stop().await;
    // SAFETY: signal zero only probes; after reaping, this PID should no longer exist.
    assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    assert!(
        !workspace.exists(),
        "retirement removes compiled assets after reaping"
    );

    std::fs::create_dir(&workspace).unwrap();
    std::fs::write(workspace.join("stale.txt"), b"simulated hard-exit residue").unwrap();
    let mut recovered = Process::new(helper, Kind::CoreMl, model, root.clone());
    recovered.ensure_running().await.unwrap();
    assert!(
        !workspace.join("stale.txt").exists(),
        "a locked launch retires stale data"
    );
    assert_eq!(
        recovered
            .request(&request, Duration::from_secs(30))
            .await
            .unwrap()["classLabel"]["type"],
        "string"
    );
    let recovered_pid = recovered.pid().unwrap();
    drop(recovered);
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            // SAFETY: signal zero does not act on a process.
            if unsafe { libc::kill(recovered_pid as i32, 0) } == -1 && !workspace.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("Drop retains retirement ownership through kill/reap and cleanup");
    std::fs::remove_dir_all(root).unwrap();
}
