//! Actual ambient interactive Pi and an owned HTTP model, isolated HOME/agent
//! configuration. One explicit submission tests persisted resume without replay;
//! this is not installed-service or frontend acceptance.
use super::*;
use crate::{ambient_pi::AmbientPi, test_support::TestDirectory};
use serde_json::json;
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};
#[track_caller]
fn wait(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(45);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "Actual Pi graph admission deadline elapsed"
        );
        thread::sleep(Duration::from_millis(50));
    }
}
fn policy(root: &TestDirectory, model: &super::model_fixture::Model) -> crate::PiPolicy {
    let ambient = AmbientPi::find(None).expect("Ambient Pi dependency unavailable");
    let agent = root.path().join("agent");
    let sessions = root.path().join("sessions");
    for directory in [&agent, &sessions] {
        fs::create_dir(directory).unwrap();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fs::write(agent.join("settings.json"),br#"{"quietStartup":true,"packages":[],"compaction":{"enabled":false},"retry":{"enabled":false}}"#).unwrap();
    let config = root.path().join("provider.json");
    fs::write(
        &config,
        serde_json::to_vec(&json!({"baseUrl":format!("http://127.0.0.1:{}/v1", model.port)}))
            .unwrap(),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
    let executable = root.path().join("private-pi");
    fs::write(
        &executable,
        format!(
            "#!/bin/sh\nexport HOME='{}' PI_CODING_AGENT_DIR='{}' PI_OFFLINE=1 PI_AXO_INTERACTIVE_FIXTURE_CONFIG='{}'\nexec '{}' \"$@\"\n",
            root.path().display(),
            agent.display(),
            config.display(),
            ambient.executable.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let manifest = root.path().join("policy.json");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf();
    fs::write(&manifest,serde_json::to_vec(&json!({"extension":repo.join("pi-axo/index.ts"),"profiles":{},"local":{"executable":executable,"sessionDirectory":sessions,"arguments":["--offline","--no-extensions","--no-skills","--no-themes","--no-context-files","--no-prompt-templates","--no-approve","--extension",repo.join("pi-axo/tests/fixtures/provider.ts"),"--provider","axo-interactive-fixture","--model","fixture"]}})).unwrap()).unwrap();
    fs::set_permissions(&manifest, fs::Permissions::from_mode(0o600)).unwrap();
    crate::PiPolicy::read(&manifest).unwrap()
}
fn observe(controller: &Controller, machine: MachineId, binding: &Binding) -> serde_json::Value {
    crate::state::rpc::dispatch(crate::rpc::Call {
        id: Some(json!(1)), method: "axo.state.chat.observe".into(),
        params: Some(json!({"target":{"machineId":machine,"hostGeneration":controller.native.generation,"storeGeneration":controller.generation().unwrap(),"workspaceId":binding.workspace_id,"sessionId":binding.session_id}})),
    }, controller, machine, false).unwrap()
}
#[test]
fn actual_three_by_four_by_three_graph_admits_every_pane_and_resumes_exact_pi_file() {
    let root = TestDirectory::new();
    let model = super::model_fixture::Model::new();
    let machine = MachineId::new();
    let mut owner = Controller::open(root.path(), machine, Some(policy(&root, &model))).unwrap();
    let shell = root.path().join("private-zsh");
    fs::write(
        &shell,
        format!(
            "#!/bin/sh\nexport HOME='{}' ZDOTDIR='{}'\nexec /bin/zsh -f -i\n",
            root.path().display(),
            root.path().display()
        ),
    )
    .unwrap();
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
    Arc::get_mut(&mut owner.native).unwrap().user_shell =
        crate::user_shell::CapturedUserShell::parse(&shell);
    let controller = Arc::new(owner);
    let approval = ApprovedDirectory::local_selection(root.path()).unwrap();
    let mut pi_session = None;
    for _ in 0..3 {
        let graph = controller
            .create_workspace(
                CommandId::new(),
                controller.revision().unwrap(),
                "Workspace",
                &approval,
            )
            .unwrap()
            .graph;
        pi_session.get_or_insert(graph.initial_session.session.session_id);
        let mut sessions = vec![graph.initial_session.session.session_id];
        for _ in 1..4 {
            sessions.push(
                controller
                    .create_session(
                        CommandId::new(),
                        controller.revision().unwrap(),
                        graph.workspace.workspace_id,
                        "Session",
                    )
                    .unwrap()
                    .graph
                    .session
                    .session_id,
            );
        }
        for session in sessions {
            controller
                .add_shell(CommandId::new(), controller.revision().unwrap(), session)
                .unwrap();
        }
    }
    let workers = controller.supervise().unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .filter(|observation| observation.availability == Availability::Live)
            .count()
            == 36
    });
    assert_eq!(controller.native.managed_live.lock().unwrap().len(), 12);
    assert_eq!(
        controller
            .native
            .list()
            .iter()
            .filter(|snapshot| matches!(snapshot.process, ProcessState::Running { .. }))
            .count(),
        36
    );
    let session = pi_session.unwrap();
    let binding = controller
        .database
        .lock()
        .unwrap()
        .binding(session)
        .unwrap()
        .unwrap();
    assert_eq!(model.requests.load(Ordering::SeqCst), 0);
    let observed = observe(&controller, machine, &binding);
    assert_eq!(observed["result"]["value"]["kind"], "live");
    assert_eq!(
        observed["result"]["value"]["target"]["runtime"],
        json!(binding.runtime)
    );
    assert_eq!(
        observed["result"]["value"]["target"]["chatId"],
        json!(binding.chat_id)
    );
    assert!(observed["result"]["value"]["state"].get("file").is_none());
    assert!(observed["result"]["value"]["state"].get("pid").is_none());
    assert!(serde_json::to_vec(&observed).unwrap().len() < 48 * 1024);
    let exact_target = observed["result"]["value"]["target"].clone();
    let snapshot = crate::state::rpc::dispatch(
        crate::rpc::Call {
            id: Some(json!(2)),
            method: "axo.state.chat.get".into(),
            params: Some(json!({"target":exact_target})),
        },
        &controller,
        machine,
        false,
    )
    .unwrap();
    assert_eq!(snapshot["result"]["value"]["kind"], "live");
    assert_eq!(snapshot["result"]["value"]["target"], exact_target);
    assert_eq!(
        model.requests.load(Ordering::SeqCst),
        0,
        "Snapshot is not submission"
    );
    let mut foreign_target = exact_target.clone();
    foreign_target["chatId"] = json!(uuid::Uuid::new_v4());
    let rejected = crate::state::rpc::dispatch(
        crate::rpc::Call {
            id: Some(json!(3)),
            method: "axo.state.chat.get".into(),
            params: Some(json!({"target":foreign_target})),
        },
        &controller,
        machine,
        false,
    )
    .unwrap();
    assert_eq!(rejected["error"]["code"], -32002);
    let running = controller
        .native
        .managed_live
        .lock()
        .unwrap()
        .get(&session)
        .unwrap()
        .clone();
    let selected_model = running.control.get().unwrap().model.unwrap();
    assert_eq!(selected_model.provider, "axo-interactive-fixture");
    assert_eq!(selected_model.id, "fixture");
    running
        .control
        .send("Owned central fixture request")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(45);
    loop {
        let requests = model.requests.load(Ordering::SeqCst);
        let persisted = binding.file.exists();
        let busy = running.control.get().map(|state| state.busy);
        if requests == 1 && persisted && busy == Ok(false) {
            break;
        }
        if Instant::now() >= deadline {
            let error = fs::read_to_string(&binding.file)
                .unwrap_or_default()
                .lines()
                .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
                .filter_map(|value| {
                    value
                        .pointer("/message/errorMessage")
                        .and_then(|message| message.as_str())
                        .map(str::to_owned)
                })
                .next_back()
                .unwrap_or_default();
            let categories: Vec<_> = [
                "key",
                "connection",
                "ECONN",
                "timeout",
                "context",
                "fetch",
                "request",
                "JSON",
                "provider",
                "model",
                "header",
            ]
            .into_iter()
            .filter(|category| error.to_lowercase().contains(&category.to_lowercase()))
            .collect();
            panic!(
                "Owned turn timed out: requests={requests}, persisted={persisted}, busy={busy:?}, error_categories={categories:?}"
            );
        }
        thread::sleep(Duration::from_millis(50));
    }
    let original_bytes = fs::read(&binding.file).unwrap();
    drop(running);
    controller.native.stop(binding.runtime).unwrap();
    wait(|| {
        controller
            .database
            .lock()
            .unwrap()
            .binding(session)
            .unwrap()
            .is_some_and(|current| current.runtime != binding.runtime)
    });
    let resumed = controller
        .database
        .lock()
        .unwrap()
        .binding(session)
        .unwrap()
        .unwrap();
    assert_eq!(resumed.pane_id, binding.pane_id);
    assert_eq!(resumed.chat_id, binding.chat_id);
    assert_eq!(resumed.file, binding.file);
    assert_ne!(
        resumed.runtime.runtime_generation,
        binding.runtime.runtime_generation
    );
    assert_eq!(fs::read(&binding.file).unwrap(), original_bytes);
    let predecessor_read = crate::state::rpc::dispatch(
        crate::rpc::Call {
            id: Some(json!(5)),
            method: "axo.state.chat.get".into(),
            params: Some(json!({"target":exact_target})),
        },
        &controller,
        machine,
        false,
    )
    .unwrap();
    assert_eq!(
        predecessor_read["error"]["code"], -32002,
        "Snapshot must not retarget the resumed runtime"
    );
    assert_eq!(model.requests.load(Ordering::SeqCst), 1);
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .all(|observation| observation.availability == Availability::Live)
    });
    let history_target =
        observe(&controller, machine, &resumed)["result"]["value"]["target"].clone();
    let read_history = |cursor: Option<serde_json::Value>| {
        let mut params = json!({"target":history_target,"readMode":"stopped","limit":1});
        if let Some(cursor) = cursor {
            params["cursor"] = cursor;
        }
        crate::state::rpc::dispatch(
            crate::rpc::Call {
                id: Some(json!(6)),
                method: "axo.state.chat.history".into(),
                params: Some(params),
            },
            &controller,
            machine,
            false,
        )
        .unwrap()
    };
    assert_eq!(
        read_history(None)["error"]["code"],
        -32009,
        "Live writer cannot use stopped file history"
    );
    controller
        .set_lifecycle(
            CommandId::new(),
            controller.revision().unwrap(),
            LifecycleTarget::Session {
                workspace_id: resumed.workspace_id,
                session_id: session,
            },
            DesiredLifecycle::Archived,
        )
        .unwrap();
    wait(|| {
        controller.native.runtime_completed(resumed.runtime)
            && controller
                .database
                .lock()
                .unwrap()
                .attempt(resumed.pane_id)
                .unwrap()
                .is_some_and(|attempt| attempt.phase == AttemptPhase::CompletionProven)
            && !controller
                .native
                .managed_live
                .lock()
                .unwrap()
                .contains_key(&session)
    });
    let exclusion = WriterLease::acquire(&resumed.file).unwrap();
    assert_eq!(
        read_history(None)["error"]["code"],
        -32009,
        "A held writer lease blocks stopped history"
    );
    drop(exclusion);
    let first_history = read_history(None);
    assert_eq!(
        first_history["result"]["value"]["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let cursor = first_history["result"]["value"]["cursor"].clone();
    assert!(
        !cursor.is_null(),
        "Actual vanilla Pi turn has a continuation"
    );
    let next_history = read_history(Some(cursor));
    assert_eq!(
        next_history["result"]["value"]["headDigest"],
        first_history["result"]["value"]["headDigest"]
    );
    assert_ne!(
        next_history["result"]["value"]["entries"][0]["entryId"],
        first_history["result"]["value"]["entries"][0]["entryId"]
    );
    assert_eq!(
        fs::read(&resumed.file).unwrap(),
        original_bytes,
        "History read cannot rewrite canonical bytes"
    );
    // Vanilla Pi names an unsaved file before its first assistant turn. Missing
    // history is not authority to replace that already-admitted chat identity.
    let empty = controller
        .native
        .managed_live
        .lock()
        .unwrap()
        .values()
        .find(|running| running.binding.session_id != session)
        .unwrap()
        .binding
        .clone();
    assert!(!empty.file.exists());
    controller.native.stop(empty.runtime).unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .any(|observation| {
                observation.pane_id == empty.pane_id
                    && observation.availability == Availability::Blocked
            })
            && controller.native.runtime_completed(empty.runtime)
            && controller
                .database
                .lock()
                .unwrap()
                .attempt(empty.pane_id)
                .unwrap()
                .is_some_and(|attempt| attempt.phase == AttemptPhase::CompletionProven)
    });
    assert!(controller.native.runtime_completed(empty.runtime));
    assert_eq!(
        controller
            .database
            .lock()
            .unwrap()
            .binding(empty.session_id)
            .unwrap()
            .unwrap()
            .runtime,
        empty.runtime
    );
    assert!(!empty.file.exists());
    let stopped = observe(&controller, machine, &empty);
    assert_eq!(stopped["result"]["value"]["kind"], "stopped");
    assert_eq!(
        stopped["result"]["value"]["target"]["runtime"],
        json!(empty.runtime)
    );
    assert!(stopped["result"]["value"].get("state").is_none());
    let missing_history = crate::state::rpc::dispatch(
        crate::rpc::Call {
            id: Some(json!(7)),
            method: "axo.state.chat.history".into(),
            params: Some(
                json!({"target":stopped["result"]["value"]["target"],"readMode":"stopped"}),
            ),
        },
        &controller,
        machine,
        false,
    )
    .unwrap();
    assert_eq!(
        missing_history["error"]["code"], -32009,
        "Completion does not manufacture a never-written history file"
    );
    let stopped_snapshot = crate::state::rpc::dispatch(
        crate::rpc::Call {
            id: Some(json!(4)),
            method: "axo.state.chat.get".into(),
            params: Some(json!({"target":stopped["result"]["value"]["target"]})),
        },
        &controller,
        machine,
        false,
    )
    .unwrap();
    assert!(
        stopped_snapshot.get("error").is_some(),
        "Stopped readers cannot use a live snapshot route"
    );
    assert!(
        !empty.file.exists(),
        "Observation must not fabricate canonical history"
    );
    assert_eq!(model.requests.load(Ordering::SeqCst), 1);
    workers.shutdown().unwrap();
}
