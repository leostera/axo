//! Transport routing names the authority explicitly. The explicit native
//! harness remains for owned PTY/operator fixtures; serve-user never selects it.
use crate::{model::*, rpc, runtime::Manager, state::controller::Controller};
use serde_json::Value;
use std::{collections::BTreeMap, sync::Arc};
#[derive(Clone)]
pub(crate) enum RpcOwner {
    Central(Arc<Controller>),
    NativeHarness(Arc<Manager>),
}
impl RpcOwner {
    pub(crate) fn runtime(&self) -> Arc<Manager> {
        match self {
            Self::Central(owner) => owner.runtime_owner(),
            Self::NativeHarness(owner) => owner.clone(),
        }
    }
    pub(crate) fn dispatch(
        &self,
        call: rpc::Call,
        machine: MachineId,
        profiles: &BTreeMap<String, TerminalLaunch>,
        local: bool,
    ) -> Option<Value> {
        match self {
            Self::Central(owner) => crate::state::rpc::dispatch(call, owner, machine, local),
            Self::NativeHarness(owner) if local => {
                rpc::dispatch_local(call, owner, machine, profiles)
            }
            Self::NativeHarness(owner) => rpc::dispatch(call, owner, machine, profiles),
        }
    }
}
