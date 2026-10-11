//! Explicit shell-pane add/remove. Native layout and rendering remain client-owned.
mod rpc;
pub(crate) mod store;
#[cfg(test)]
mod tests;
use crate::{model::*, runtime::Manager};
pub(crate) use rpc::dispatch;
use serde::Serialize;
use store::{PaneRecord, PaneState};
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneView {
    pane_id: PaneId,
    kind: &'static str,
    profile_id: crate::user_shell::ShellSource,
    state: PaneState,
    runtime: Option<RuntimeRef>,
    terminal: Option<TerminalSnapshot>,
}
pub(crate) fn view(pane: PaneRecord, manager: &Manager) -> PaneView {
    let runtime = pane
        .runtime
        .or_else(|| manager.pane_command_runtime(pane.add_command));
    let terminal = runtime.and_then(|runtime| {
        manager
            .list()
            .into_iter()
            .find(|snapshot| snapshot.runtime == runtime)
    });
    PaneView {
        pane_id: pane.pane_id,
        kind: "shell",
        profile_id: pane.profile_id,
        state: pane.state,
        runtime,
        terminal,
    }
}
pub(crate) fn session_views(session: SessionId, manager: &Manager) -> Vec<PaneView> {
    let panes = manager.panes.lock().unwrap().session_panes(session);
    panes.into_iter().map(|pane| view(pane, manager)).collect()
}
