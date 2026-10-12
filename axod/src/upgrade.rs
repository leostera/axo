//! Local-only, generation-bound idle handoff. Never signals a PID or retires accepted work.
use crate::{
    model::*,
    rpc::{Destination, Outcome},
    runtime::Manager,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Plan {
    #[serde(deserialize_with = "crate::model::deserialize_uuid")]
    pub handoff_id: uuid::Uuid,
    pub expected_version: String,
    pub replacement_version: String,
    pub replacement_build_number: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    target: Destination,
    plan: Plan,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Disposition {
    Quiesced,
    DeferredActiveWork,
    NotNewer,
}

pub(crate) fn prepare(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let params: Parameters = serde_json::from_value(params.unwrap_or(Value::Null))
        .map_err(|_| (-32602, "Invalid upgrade plan"))?;
    crate::rpc::validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    let plan = params.plan;
    if plan.expected_version != crate::host::VERSION
        || plan.replacement_version.is_empty()
        || plan.replacement_version.len() > 128
        || plan.replacement_version.chars().any(char::is_control)
        || plan.replacement_build_number == 0
        || plan.replacement_build_number > 9_007_199_254_740_991
    {
        return Err((-32602, "Invalid upgrade plan"));
    }
    let disposition = manager.prepare_upgrade(&plan)?;
    Ok(
        json!({"machineId":machine,"hostGeneration":manager.generation,"daemonVersion":crate::host::VERSION,
        "daemonBuildNumber":build_number(),"plan":plan,"disposition":disposition}),
    )
}
pub(crate) fn build_number() -> u64 {
    env!("AXOD_BUILD_NUMBER").parse().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{journal::Journal, test_support::TestDirectory};
    use std::collections::BTreeMap;
    fn plan() -> Plan {
        Plan {
            handoff_id: uuid::Uuid::new_v4(),
            expected_version: crate::host::VERSION.into(),
            replacement_version: "0.1.0 (next)".into(),
            replacement_build_number: build_number() + 1,
        }
    }
    #[test]
    fn idle_quiescence_blocks_admission_and_reconciles_only_exact_plan() {
        let root = TestDirectory::new();
        let manager = Manager::new(Journal::open(root.path()).unwrap());
        let plan = plan();
        assert_eq!(
            manager.prepare_upgrade(&plan).unwrap(),
            Disposition::Quiesced
        );
        assert_eq!(
            manager.prepare_upgrade(&plan).unwrap(),
            Disposition::Quiesced
        );
        let other = Plan {
            handoff_id: uuid::Uuid::new_v4(),
            ..plan
        };
        assert_eq!(manager.prepare_upgrade(&other).unwrap_err().0, -32007);
        assert!(
            manager
                .start(
                    CommandId::new(),
                    TerminalTarget {
                        session_id: SessionId::new(),
                        pane_id: PaneId::new()
                    },
                    &TerminalLaunch {
                        directory: root.path().to_str().unwrap().into(),
                        argv: vec!["/bin/cat".into()]
                    }
                )
                .is_err()
        );
        assert!(manager.list().is_empty());
    }
    #[test]
    fn live_owned_runtime_defers_handoff_and_older_build_cannot_downgrade() {
        let root = TestDirectory::new();
        let manager = Manager::new(Journal::open(root.path()).unwrap());
        let plan = plan();
        let same = Plan {
            replacement_build_number: build_number(),
            ..plan.clone()
        };
        assert_eq!(
            manager.prepare_upgrade(&same).unwrap(),
            Disposition::NotNewer
        );
        let target = TerminalTarget {
            session_id: SessionId::new(),
            pane_id: PaneId::new(),
        };
        let runtime = manager
            .start(
                CommandId::new(),
                target,
                &TerminalLaunch {
                    directory: root.path().to_str().unwrap().into(),
                    argv: vec!["/bin/sh".into(), "-c".into(), "sleep 60".into()],
                },
            )
            .unwrap();
        assert_eq!(
            manager.prepare_upgrade(&plan).unwrap(),
            Disposition::DeferredActiveWork
        );
        // Owned fixture shutdown only; a deferred upgrade never signaled this process.
        assert!(matches!(
            manager.list()[0].process,
            ProcessState::Running { .. }
        ));
        manager.stop(runtime.runtime).unwrap();
        manager.shutdown();
    }
    #[test]
    fn cloud_cannot_prepare_a_local_service_handoff() {
        let root = TestDirectory::new();
        let manager = Manager::new(Journal::open(root.path()).unwrap());
        let machine = MachineId::new();
        let reply = crate::rpc::dispatch(
            crate::rpc::Call {
                id: Some(json!(1)),
                method: "axo.host.prepareUpgrade".into(),
                params: Some(json!({
                    "target":{"machineId":machine,"hostGeneration":manager.generation},"plan":plan()
                })),
            },
            &manager,
            machine,
            &BTreeMap::new(),
        )
        .unwrap();
        assert_eq!(reply["error"]["code"], -32601);
        assert_eq!(
            manager.prepare_upgrade(&plan()).unwrap(),
            Disposition::Quiesced
        );
    }
}
