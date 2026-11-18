//! `axo.agents.list`: the coding agents this Mac has, found as a launch finds them (RFD0072).

use axo_agent::AgentKind;
use axo_agent::discovery::{self, SearchPlaces};
use axo_ipc::{Extension, TypedMethods};
use axo_protocol::rpc::{self, method};
use jsonrpc_core::IoHandler;

pub(crate) struct Agents;

impl Extension for Agents {
    fn name(&self) -> &'static str {
        "agents"
    }

    fn register(&self, methods: &mut IoHandler) {
        methods.add_typed(
            method::AGENTS_LIST,
            "expected no parameters",
            |_: rpc::NoParams| async move {
                let home = crate::current_user_home_directory().unwrap_or_default();
                Ok(rpc::AgentsList {
                    agents: list(&home).await,
                })
            },
        );
    }
}

/// Every agent, in `AgentKind::ALL`'s order, each looked for at the same time.
pub(crate) async fn list(home: &std::path::Path) -> Vec<rpc::AgentAvailability> {
    let lookups = AgentKind::ALL.map(|kind| {
        let places = SearchPlaces::from_environment(kind, home);
        tokio::spawn(async move {
            discovery::discover(kind, &places, discovery::VERSION_TIMEOUT).await
        })
    });
    let mut agents = Vec::new();
    for (kind, lookup) in AgentKind::ALL.into_iter().zip(lookups) {
        let found = lookup.await.unwrap_or_else(|_| Err(discovery::DiscoveryError::NotInstalled(kind)));
        agents.push(availability(kind, found));
    }
    agents
}

fn availability(
    kind: AgentKind,
    found: Result<discovery::InstalledAgent, discovery::DiscoveryError>,
) -> rpc::AgentAvailability {
    let capabilities = kind.capabilities();
    match found {
        Ok(installed) => rpc::AgentAvailability {
            agent: kind,
            installed: true,
            executable: Some(installed.executable.display().to_string()),
            version: Some(installed.version.to_string()),
            problem: None,
            capabilities,
        },
        Err(error) => rpc::AgentAvailability {
            agent: kind,
            installed: false,
            executable: None,
            version: None,
            problem: Some(error.to_string()),
            capabilities,
        },
    }
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn every_agent_is_listed_with_what_it_can_do() {
        // The test environment points Codex, OpenCode and Claude Code at the fakes.
        let listed = super::list(std::path::Path::new("/nonexistent-home")).await;
        let kinds: Vec<_> = listed.iter().map(|agent| agent.agent).collect();
        assert_eq!(kinds, axo_agent::AgentKind::ALL);
        let codex = &listed[1];
        assert!(codex.installed, "{codex:?}");
        assert_eq!(codex.version.as_deref(), Some("0.170.0"));
        let claude = &listed[3];
        assert!(claude.installed, "{claude:?}");
        assert!(!claude.capabilities.deliveries.steer);
        let wire = serde_json::to_value(&listed[2]).unwrap();
        assert_eq!(wire["agent"], "opencode");
        assert_eq!(wire["capabilities"]["deliveries"]["followUp"], true);
    }
}
