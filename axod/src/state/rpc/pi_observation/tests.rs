use super::*;
fn binding() -> Binding {
    let session_id = SessionId::new();
    let pane_id = PaneId::new();
    Binding {
        workspace_id: Some(WorkspaceId::new()),
        session_id,
        pane_id,
        chat_id: serde_json::from_value(json!(uuid::Uuid::new_v4())).unwrap(),
        runtime: RuntimeRef {
            host_generation: HostGeneration::new(),
            runtime_generation: RuntimeGeneration::new(),
            target: TerminalTarget {
                session_id,
                pane_id,
            },
        },
        file: "/owned/private/chat.jsonl".into(),
        directory: "/owned/workspace".into(),
        start_command_id: CommandId::new(),
    }
}
fn state(binding: &Binding) -> Value {
    json!({"chatId":binding.chat_id,"title":"Observed title","file":binding.file,"leafId":null,"cwd":binding.directory,"mode":"tui","stdinTTY":true,"stdoutTTY":true,"stderrTTY":true,"rows":30,"columns":100,"pid":123,"busy":false,"interactionId":null,"uiWaits":0,"question":null,"tools":[],"pending":false,"recovery":false,"model":null})
}
fn parse(value: Value, binding: &Binding) -> Result<LiveState, (i32, &'static str)> {
    LiveState::parse(serde_json::from_value(value).unwrap(), binding)
}
#[test]
fn projection_omits_process_paths_and_keeps_only_exact_bound_control_metadata() {
    let binding = binding();
    let projected = serde_json::to_value(parse(state(&binding), &binding).unwrap()).unwrap();
    assert_eq!(projected.as_object().unwrap().len(), 8);
    for key in ["file", "cwd", "pid", "tools", "model", "argv"] {
        assert!(projected.get(key).is_none());
    }
    let mut foreign = state(&binding);
    foreign["file"] = json!("/different/chat.jsonl");
    assert_eq!(parse(foreign, &binding).err().unwrap().0, -32002);
    let mut oversized = state(&binding);
    oversized["leafId"] = json!("é".repeat(65));
    assert_eq!(parse(oversized, &binding).err().unwrap().0, -32009);
}
#[test]
fn question_projection_requires_active_interaction_distinct_options_and_utf16_bounds() {
    let binding = binding();
    let interaction = uuid::Uuid::new_v4();
    let options = json!([{"id":uuid::Uuid::new_v4(),"label":"First"},{"id":uuid::Uuid::new_v4(),"label":"Second"}]);
    let mut waiting = state(&binding);
    waiting["interactionId"] = json!(interaction);
    waiting["uiWaits"] = json!(1);
    waiting["question"] = json!({"id":uuid::Uuid::new_v4(),"interactionId":interaction,"title":"😀".repeat(1000),"options":options});
    assert!(parse(waiting.clone(), &binding).is_ok());
    for key in ["interactionId", "uiWaits"] {
        let mut invalid = waiting.clone();
        invalid[key] = if key == "uiWaits" {
            json!(0)
        } else {
            Value::Null
        };
        assert_eq!(parse(invalid, &binding).err().unwrap().0, -32009);
    }
    let mut duplicate = waiting.clone();
    duplicate["question"]["options"][1] = duplicate["question"]["options"][0].clone();
    assert_eq!(parse(duplicate, &binding).err().unwrap().0, -32009);
    waiting["question"]["title"] = json!("😀".repeat(1001));
    assert_eq!(parse(waiting, &binding).err().unwrap().0, -32009);
    assert_eq!(
        control_failure(ControlError::OutcomeUnknown),
        (-32009, "Central Pi observation gap")
    );
}
