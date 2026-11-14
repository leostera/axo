//! This test owns a separate Xvfb/DBus desktop. It never bypasses the real host's lock gate.
use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

fn invoke(
    runtime: &tokio::runtime::Runtime,
    registry: &ToolRegistry,
    tool: &str,
    args: Value,
) -> Value {
    serde_json::to_value(runtime.block_on(registry.invoke(tool, args))).unwrap()
}

fn successful(value: Value) -> Value {
    assert_ne!(value["isError"], true, "fixture operation failed: {value}");
    value
}

fn token(state: &Value, label: &str) -> String {
    state["structuredContent"]["elements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|element| element["label"].as_str() == Some(label))
        .unwrap_or_else(|| panic!("fixture element missing: {label}"))["element_token"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[test]
#[ignore = "run linux/computer-smoke.sh with an isolated Xvfb, D-Bus and GTK fixture"]
fn real_linux_desktop_reads_captures_edits_and_checks_nested_lock_state() {
    assert_eq!(
        std::env::var("AXO_LINUX_ISOLATED_DESKTOP").as_deref(),
        Ok("1")
    );
    assert!(
        std::env::var_os("WAYLAND_DISPLAY").is_none(),
        "not an isolated X11 desktop"
    );
    let pid: u32 = std::env::var("AXO_LINUX_FIXTURE_PID")
        .unwrap()
        .parse()
        .unwrap();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let locked = Arc::new(AtomicBool::new(false));
    let lock_after_read = Arc::new(AtomicBool::new(false));
    let mut registry = {
        let _entered = runtime.enter();
        registry()
    };
    registry.set_invocation_guard({
        let locked = locked.clone();
        let lock_after_read = lock_after_read.clone();
        Arc::new(move |tool| {
            // Test-only state models this owned virtual desktop, not the actual logind session.
            let blocked = locked.load(Ordering::SeqCst);
            if !blocked
                && tool == "get_window_state"
                && lock_after_read.swap(false, Ordering::SeqCst)
            {
                locked.store(true, Ordering::SeqCst);
            }
            Box::pin(async move { blocked.then(|| "fixture locked".to_owned()) })
        })
    });
    let registry = Arc::new(registry);
    registry.init_self_weak();
    let call = |tool, args| invoke(&runtime, &registry, tool, args);
    let deadline = Instant::now() + Duration::from_secs(20);
    let window = loop {
        let windows = successful(call("list_windows", json!({"pid":pid})));
        if let Some(window) = windows["structuredContent"]["windows"]
            .as_array()
            .unwrap()
            .first()
        {
            break window["window_id"].as_u64().unwrap();
        }
        assert!(Instant::now() < deadline, "fixture window not enumerated");
        std::thread::sleep(Duration::from_millis(100));
    };
    let read_args = json!({"pid":pid,"window_id":window,"tree_format":"both","timeout_ms":5000});
    let first = loop {
        let state = successful(call("get_window_state", read_args.clone()));
        if state["structuredContent"]["elements"]
            .as_array()
            .is_some_and(|items| {
                items
                    .iter()
                    .any(|item| item["label"] == "Axo fixture input")
            })
        {
            break state;
        }
        assert!(
            Instant::now() < deadline,
            "fixture accessibility tree not published"
        );
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(
        first["content"]
            .as_array()
            .unwrap()
            .iter()
            .any(|content| content["type"] == "image"),
        "fixture screenshot missing"
    );
    let old_entry = token(&first, "Axo fixture input");
    successful(call(
        "set_value",
        json!({"pid":pid,"window_id":window,"element_token":old_entry,"value":"axo-linux-fixture"}),
    ));
    let edited = successful(call("get_window_state", read_args.clone()));
    assert!(
        edited.to_string().contains("axo-linux-fixture"),
        "AT-SPI did not observe the edited value"
    );
    let button = token(&edited, "Copy input");
    successful(call(
        "click",
        json!({"pid":pid,"window_id":window,"element_token":button}),
    ));
    let deadline = Instant::now() + Duration::from_secs(5);
    let echoed = loop {
        let state = successful(call("get_window_state", read_args.clone()));
        if state.to_string().contains("Echo: axo-linux-fixture") {
            break state;
        }
        assert!(
            Instant::now() < deadline,
            "button action did not update fixture"
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    let stale = call(
        "set_value",
        json!({"pid":pid,"window_id":window,"element_token":old_entry,"value":"must-not-be-filled"}),
    );
    assert_eq!(stale["isError"], true, "stale snapshot token was accepted");
    lock_after_read.store(true, Ordering::SeqCst);
    let script = format!(
        "await cua.call('get_window_state', {{pid:{pid},window_id:{window},tree_format:'elements'}}); await cua.call('set_value', {{pid:{pid},window_id:{window},element_token:{},value:'must-not-be-filled'}});",
        json!(token(&echoed, "Axo fixture input"))
    );
    let blocked = call("run_script", json!({"script":script,"max_calls":4}));
    assert_eq!(
        blocked["isError"], true,
        "script ran after virtual desktop locked"
    );
    assert!(
        blocked.to_string().contains("fixture locked"),
        "nested guard was not consulted"
    );
    locked.store(false, Ordering::SeqCst);
    let final_state = successful(call("get_window_state", read_args));
    assert!(!final_state.to_string().contains("must-not-be-filled"));
    eprintln!(
        "Linux X11 acceptance passed: window enumeration, AT-SPI, screenshot, edit/readback, click, stale-token refusal and nested lock guard"
    );
}
