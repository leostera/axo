//! What each local axod method becomes when a person reaches the host through the relay.
//!
//! The relay does not forward the local API verbatim: a remote caller names its target host and
//! generation, and some methods only make sense on the Mac itself. This table is the one place
//! that decides, for every method axod advertises, which of those it is. A test fails when a
//! method is added to [`method::ADVERTISED`](crate::rpc::method::ADVERTISED) without a decision
//! here, and the Worker's schemas are checked against the same table
//! (`fixtures/remote-parity.json`), so a method cannot silently be missing remotely.

use crate::rpc::method;

/// The remote counterpart of a local method.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Remote {
    /// Callable through the relay as this method.
    Call(&'static str),
    /// Delivered through the relay's host events and subscriptions; the named method is the
    /// remote entry point.
    Events(&'static str),
    /// Deliberately not exposed: it concerns this Mac only.
    LocalOnly(&'static str),
    /// Wanted remotely and not built yet; the named method is the planned name.
    Planned(&'static str),
}

/// One local method and its remote counterpart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Parity {
    pub local: &'static str,
    pub remote: Remote,
}

const fn row(local: &'static str, remote: Remote) -> Parity {
    Parity { local, remote }
}

/// Every method in [`method::ADVERTISED`](crate::rpc::method::ADVERTISED), in the same order.
pub const PARITY: &[Parity] = &[
    row(
        method::DAEMON_HEALTH,
        Remote::LocalOnly("the relay reports a host's presence instead"),
    ),
    row(
        method::CONFIG_GET,
        Remote::LocalOnly("settings choose what this Mac runs; change them on the Mac"),
    ),
    row(
        method::CONFIG_SET,
        Remote::LocalOnly("settings choose what this Mac runs; change them on the Mac"),
    ),
    row(
        method::SESSION_LIST,
        Remote::Events("axo.host.sessions.list"),
    ),
    row(
        method::SESSION_CATALOG,
        Remote::LocalOnly("archived Sessions and transcript paths for agents on this Mac"),
    ),
    row(
        method::SESSION_CREATE,
        Remote::Call("axo.remote.session.create"),
    ),
    row(
        method::SESSION_CLOSE,
        Remote::Call("axo.remote.session.close"),
    ),
    row(
        method::SESSION_REOPEN,
        Remote::LocalOnly("undoes a close made on this Mac"),
    ),
    row(
        method::SESSION_RENAME,
        Remote::Call("axo.remote.session.rename"),
    ),
    row(
        method::SESSION_PI_RESTART_FORCE,
        Remote::Call("axo.remote.session.restart"),
    ),
    row(
        method::SESSION_PI_RESTART_AUTO,
        Remote::Call("axo.remote.session.restart"),
    ),
    row(
        method::SESSION_LAYOUT_SET,
        Remote::Call("axo.remote.session.layout.set"),
    ),
    row(
        method::SHELL_CREATE,
        Remote::Call("axo.remote.shell.create"),
    ),
    row(method::SHELL_CLOSE, Remote::Call("axo.remote.shell.close")),
    row(
        method::SHELL_BUSY,
        Remote::LocalOnly("only the Mac app's close confirmation asks"),
    ),
    row(
        method::TERMINAL_INPUT,
        Remote::Call("axo.remote.terminal.input"),
    ),
    row(
        method::TERMINAL_RESIZE,
        Remote::Call("axo.remote.terminal.resize"),
    ),
    row(
        method::TERMINAL_WRITE,
        Remote::LocalOnly(
            "agents on this Mac type into panes; remote clients send sequenced input",
        ),
    ),
    row(
        method::TERMINAL_SCREEN,
        Remote::LocalOnly("clients show the conversation, not terminals"),
    ),
    row(
        method::SESSION_PROMPT,
        Remote::Call("axo.remote.session.prompt"),
    ),
    row(
        method::CLIENT_VIEWPORT_SET,
        Remote::LocalOnly("window geometry of a client on this Mac"),
    ),
    row(
        method::RELAY_LINK,
        Remote::LocalOnly("pairing links this Mac itself"),
    ),
    row(
        method::RELAY_STATUS,
        Remote::LocalOnly("remote-access control of this Mac"),
    ),
    row(
        method::RELAY_CONNECT,
        Remote::LocalOnly("remote-access control of this Mac"),
    ),
    row(
        method::SESSION_SHARE,
        Remote::LocalOnly("this Mac publishes its own redacted conversation to the cloud"),
    ),
    row(
        method::APPS_LIST,
        Remote::LocalOnly(
            "a Session on this Mac reaches its account's apps; the cloud already holds them",
        ),
    ),
    row(
        method::APPS_SEARCH,
        Remote::LocalOnly(
            "a Session on this Mac reaches its account's apps; the cloud already holds them",
        ),
    ),
    row(
        method::APPS_RUN,
        Remote::LocalOnly(
            "a Session on this Mac reaches its account's apps; the cloud already holds them",
        ),
    ),
    row(
        method::APPS_LOG,
        Remote::LocalOnly(
            "a Session on this Mac reaches its account's apps; the cloud already holds them",
        ),
    ),
    row(
        method::APPS_ADD,
        Remote::LocalOnly(
            "a Session on this Mac reaches its account's apps; the cloud already holds them",
        ),
    ),
    row(
        method::APPS_REMOVE,
        Remote::LocalOnly(
            "a Session on this Mac reaches its account's apps; the cloud already holds them",
        ),
    ),
    row(
        method::PEER_SESSIONS_LIST,
        Remote::LocalOnly("the other Macs' Sessions, as this Mac follows them"),
    ),
    row(
        method::PEER_SESSION_OPEN,
        Remote::LocalOnly("a pane on this Mac for another Mac's Session"),
    ),
    row(
        method::PEER_SESSION_CLOSE,
        Remote::LocalOnly("a pane on this Mac for another Mac's Session"),
    ),
    row(
        method::PEER_SESSION_WATCH,
        Remote::LocalOnly("a remote pane follows this Mac's copy"),
    ),
    row(
        method::PEER_COMMAND,
        Remote::LocalOnly("this Mac's own client call to another Mac"),
    ),
    row(
        method::ELICITATION_REQUEST,
        Remote::LocalOnly(
            "an agent on this Mac asks its person; the answer comes through the relay as axo.elicitation.resolve",
        ),
    ),
    row(
        method::ELICITATION_RESOLVE,
        Remote::LocalOnly(
            "Axo.app answers on this Mac; a remote person's answer arrives on the relay's own axo.elicitation.resolve, from the cloud",
        ),
    ),
    row(
        method::ELICITATION_LIST,
        Remote::LocalOnly(
            "the relay sends what is pending on every connection, as axo.elicitation.requested",
        ),
    ),
    row(
        method::ASSETS_FETCH,
        Remote::LocalOnly("axod mcp shows its agent images from the account's assets"),
    ),
    row(
        method::COMPUTER_INPUT,
        Remote::LocalOnly("another Mac's script asks through axo.apps.computer"),
    ),
    row(
        method::COMPUTER_REDACTIONS,
        Remote::LocalOnly("axod hides filled values from remote reads itself"),
    ),
    row(
        method::SESSION_BRIEF,
        Remote::LocalOnly("the system prompt of an agent running on this Mac"),
    ),
];

/// Remote calls with no local counterpart: what only a person away from the Mac needs.
pub const REMOTE_ONLY: &[&str] = &[
    // Presses Escape or Enter in the Session's Pi: stops a reply, or answers Pi's question.
    "axo.remote.session.key",
    // Stops the turn a client showed running, and no other (RFD0024).
    "axo.remote.session.stop",
    // What the Session's Pi can run and switch to, and switching it (RFD0033).
    "axo.remote.session.commands",
    "axo.remote.session.models",
    "axo.remote.session.model.set",
];

/// The remote methods that must exist now: every [`Remote::Call`] and [`Remote::Events`] name,
/// once each, in table order, then the [`REMOTE_ONLY`] calls.
pub fn required_remote_methods() -> Vec<&'static str> {
    let mut names = Vec::new();
    for parity in PARITY {
        if let Remote::Call(name) | Remote::Events(name) = parity.remote
            && !names.contains(&name)
        {
            names.push(name);
        }
    }
    names.extend(REMOTE_ONLY);
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Worker's contract: `packages/axo-api/scripts/check-schemas.mjs` reads this file too.
    const CONTRACT: &str =
        include_str!("../../../schemas/axo.leostera.dev/v1/fixtures/remote-parity.json");

    #[test]
    fn every_advertised_method_has_one_decision_in_order() {
        let table: Vec<&str> = PARITY.iter().map(|parity| parity.local).collect();
        assert_eq!(table, method::ADVERTISED);
    }

    #[test]
    fn remote_names_follow_the_remote_namespaces() {
        for parity in PARITY {
            if let Remote::Call(name) | Remote::Planned(name) = parity.remote {
                assert!(name.starts_with("axo.remote."), "{name}");
            }
            if let Remote::Events(name) = parity.remote {
                assert!(name.starts_with("axo.host."), "{name}");
            }
        }
        for name in REMOTE_ONLY {
            assert!(name.starts_with("axo.remote."), "{name}");
        }
    }

    #[test]
    fn the_worker_contract_lists_exactly_the_required_methods() {
        let contract: serde_json::Value = serde_json::from_str(CONTRACT).unwrap();
        let listed: Vec<&str> = contract["required"]
            .as_array()
            .expect("required is a list")
            .iter()
            .map(|name| name.as_str().unwrap())
            .collect();
        assert_eq!(listed, required_remote_methods());
        let planned: Vec<&str> = PARITY
            .iter()
            .filter_map(|parity| match parity.remote {
                Remote::Planned(name) => Some(name),
                _ => None,
            })
            .collect();
        let contract_planned: Vec<&str> = contract["planned"]
            .as_array()
            .expect("planned is a list")
            .iter()
            .map(|name| name.as_str().unwrap())
            .collect();
        assert_eq!(contract_planned, planned);
    }
}
