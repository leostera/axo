//! The brief: what a Session's agent can do through Axo, as a few lines for its system prompt.
//!
//! The MCP server's instructions say all of it, but Pi shows the model only a server's first
//! line and keeps the rest behind `describeNamespace("axo")`. So pi-axo puts this brief in the
//! system prompt (`axo.session.brief`): the tools an agent reaches for first, and the account's
//! Macs and apps by name. It leaves out what changes from minute to minute, such as which Macs
//! are online, so the prompt stays the same, and cached, until something real changes.

use serde_json::Value;

/// What this Session's agent can reach through Axo.
pub struct Reach {
    /// This build of axod has computer use (`axo_computer::AVAILABLE`).
    pub computer: bool,
    pub account: Account,
}

/// The person's Axo account, as far as this Mac knows it now.
pub enum Account {
    /// This axod has no relay, so there is no account to reach.
    Absent,
    /// The account did not answer: this Mac is offline, not linked, or the account was slow.
    Unreachable,
    /// What the account reaches, from `axo.apps.list`.
    Listed(AccountApps),
}

/// The account's Macs, apps and MCP servers, by the names a script calls them with.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct AccountApps {
    pub macs: Vec<String>,
    pub apps: Vec<ProvidedApp>,
    pub servers: Vec<McpServer>,
}

/// An app Axo provides, such as `apps.gmail`.
#[derive(Debug, PartialEq, Eq)]
pub struct ProvidedApp {
    /// What a script calls it: `codemode.<name>.<tool>`.
    pub name: String,
    /// The signed-in accounts a call may name.
    pub accounts: Vec<String>,
}

/// A remote MCP server the account added.
#[derive(Debug, PartialEq, Eq)]
pub struct McpServer {
    pub name: String,
    pub needs_sign_in: bool,
}

impl AccountApps {
    /// `axo.apps.list`'s answer; `None` when it is not one. Entries of a kind this build does not
    /// know, or without a name, are left out.
    pub fn parse(listed: &Value) -> Option<Self> {
        let mut parsed = Self::default();
        for app in listed["apps"].as_array()? {
            let Some(name) = app["name"].as_str() else {
                continue;
            };
            match app["kind"].as_str() {
                Some("host") => parsed.macs.push(name.to_string()),
                Some("app") => parsed.apps.push(ProvidedApp {
                    name: name.to_string(),
                    accounts: app["accounts"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|account| account["state"] == "ready")
                        .filter_map(|account| account["account"].as_str())
                        .map(str::to_string)
                        .collect(),
                }),
                Some("thirdParty") => parsed.servers.push(McpServer {
                    name: name.to_string(),
                    needs_sign_in: app["state"] == "needsSignIn",
                }),
                _ => {}
            }
        }
        Some(parsed)
    }
}

const INTRODUCTION: &str = "You run inside Axo, as the agent of one of its Sessions. Call Axo's tools from a codemode script as `tools.mcp__axo__<tool>(args)`; each answers JSON in `structuredContent`. These are the ones to reach for first; `describeNamespace(\"axo\")` has the full guide.";

const SESSIONS: &str = "- Sessions on this Mac: `whoami` (your own Session; \"self\" works wherever a Session ID goes), `session_catalog` (open and archived Sessions, with the path of each one's Pi transcript), `session_prompt`, `session_create`, `terminal_write` and `terminal_screen` (type into and read a terminal pane).";

const ASKING: &str = "- Asking the person: `elicitation_request` asks them a yes-or-no question on their own devices and waits up to 5 minutes for the answer; act only on \"accept\". Ask before anything that sends, posts, pays or deletes. Never ask for a password, login or one-time code in the chat.";

const COMPUTER: &str = "- This Mac's apps (computer use): `computer({ tool, args })` reads a window with the tool `get_window_state` and acts in it with `run_steps` or `run_script`; `computer_tools` gives each tool's schema. To log in or enter a code, use the tool `request_input` (`{ pid, window_id, fields: [{ kind, label? }], submit? }`): the person fills the fields in on their own device, and the values go into the app without passing through you. An action that may send, post, pay or delete asks the person first; you cannot approve for them.";

const ACCOUNT: &str = "- The person's Axo account: `apps_run` runs a JavaScript async function in the cloud, where `codemode.hosts.list()`, `codemode.bash.run({ host, command })`, `codemode.computer.run({ host, tool, args })`, `codemode.ai.run({ model, task, input, host? })` (local GGUF, native MLX generation or Core ML named-feature predict; installs and loads on demand; `ai.capabilities({})` describes backend support, `ai.info({ model })` inspects HF candidates; use the HF app for search) and `codemode.apps.<app>.<tool>({ account, ... })` are called; `apps_search` finds a tool by what it does, and `apps_list` lists the apps with their signed-in accounts.";

const ACCOUNT_UNREACHABLE: &str = "- The person's Axo account, if this Mac is linked to one: it does not answer now. `apps_list` says what it reaches once it does, and `apps_run` calls it.";

/// The brief for `reach`, as plain text with one line per thing the agent can use.
pub fn brief(reach: &Reach) -> String {
    let mut lines = vec![INTRODUCTION.to_string(), SESSIONS.into(), ASKING.into()];
    if reach.computer {
        lines.push(COMPUTER.into());
    }
    match &reach.account {
        Account::Absent => {}
        Account::Unreachable => lines.push(ACCOUNT_UNREACHABLE.into()),
        Account::Listed(apps) => {
            lines.push(ACCOUNT.into());
            lines.extend(account_lines(apps));
        }
    }
    lines.join("\n")
}

/// The account's Macs, apps and MCP servers by name, one kind per line; none for a kind it has
/// none of.
fn account_lines(apps: &AccountApps) -> Vec<String> {
    let mut lines = Vec::new();
    if !apps.macs.is_empty() {
        lines.push(format!(
            "  Macs (`host`): {}.",
            quoted(apps.macs.iter().map(String::as_str))
        ));
    }
    if !apps.apps.is_empty() {
        let described = apps
            .apps
            .iter()
            .map(|app| match app.accounts.as_slice() {
                [] => format!("`{}` (no account signed in)", app.name),
                accounts => format!("`{}` ({})", app.name, accounts.join(", ")),
            })
            .collect::<Vec<_>>();
        lines.push(format!("  Apps: {}.", described.join(", ")));
    }
    if !apps.servers.is_empty() {
        let described = apps
            .servers
            .iter()
            .map(|server| {
                if server.needs_sign_in {
                    format!("`codemode.{}` (needs sign-in)", server.name)
                } else {
                    format!("`codemode.{}`", server.name)
                }
            })
            .collect::<Vec<_>>();
        lines.push(format!("  MCP servers: {}.", described.join(", ")));
    }
    lines
}

fn quoted<'a>(names: impl Iterator<Item = &'a str>) -> String {
    names
        .map(|name| format!("\"{name}\""))
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn listed() -> Value {
        json!({ "apps": [
            { "kind": "host", "name": "studio", "hostId": "h1", "state": "online" },
            { "kind": "host", "name": "cfbook", "hostId": "h2", "state": "offline" },
            { "kind": "thirdParty", "name": "linear", "url": "https://mcp.linear.app/mcp", "state": "needsSignIn", "tools": 0 },
            { "kind": "app", "name": "apps.gmail", "title": "Gmail", "state": "ready", "tools": ["search_messages"],
              "accounts": [{ "account": "a@x.test", "state": "ready" }, { "account": "b@x.test", "state": "needsSignIn" }] },
            { "kind": "app", "name": "apps.calendar", "title": "Google Calendar", "state": "needsSignIn", "tools": [], "accounts": [] },
            { "kind": "somethingNew", "name": "later" },
            { "kind": "host" }
        ] })
    }

    #[test]
    fn the_account_is_read_by_the_names_a_script_calls() {
        assert_eq!(
            AccountApps::parse(&listed()).unwrap(),
            AccountApps {
                macs: vec!["studio".into(), "cfbook".into()],
                apps: vec![
                    ProvidedApp {
                        name: "apps.gmail".into(),
                        accounts: vec!["a@x.test".into()]
                    },
                    ProvidedApp {
                        name: "apps.calendar".into(),
                        accounts: vec![]
                    },
                ],
                servers: vec![McpServer {
                    name: "linear".into(),
                    needs_sign_in: true
                }],
            }
        );
        assert_eq!(AccountApps::parse(&json!({ "nope": [] })), None);
    }

    #[test]
    fn a_linked_mac_with_computer_use_hears_of_everything_by_name() {
        let text = brief(&Reach {
            computer: true,
            account: Account::Listed(AccountApps::parse(&listed()).unwrap()),
        });
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], INTRODUCTION);
        assert_eq!(lines[1], SESSIONS);
        assert_eq!(lines[2], ASKING);
        assert_eq!(lines[3], COMPUTER);
        assert_eq!(lines[4], ACCOUNT);
        assert_eq!(
            &lines[5..],
            [
                "  Macs (`host`): \"studio\", \"cfbook\".",
                "  Apps: `apps.gmail` (a@x.test), `apps.calendar` (no account signed in).",
                "  MCP servers: `codemode.linear` (needs sign-in).",
            ]
        );
    }

    #[test]
    fn what_is_not_there_is_not_mentioned() {
        let text = brief(&Reach {
            computer: false,
            account: Account::Absent,
        });
        assert_eq!(text, [INTRODUCTION, SESSIONS, ASKING].join("\n"));
        assert!(!text.contains("request_input"));
        assert!(!text.contains("apps_run"));
    }

    #[test]
    fn an_account_that_does_not_answer_is_still_pointed_at() {
        let text = brief(&Reach {
            computer: false,
            account: Account::Unreachable,
        });
        assert_eq!(text.lines().last(), Some(ACCOUNT_UNREACHABLE));
    }

    #[test]
    fn an_account_with_nothing_yet_gets_the_tools_and_no_empty_lists() {
        let text = brief(&Reach {
            computer: false,
            account: Account::Listed(AccountApps::default()),
        });
        assert_eq!(text.lines().last(), Some(ACCOUNT));
    }

    #[test]
    fn which_macs_are_online_does_not_change_the_brief() {
        let mut moved = listed();
        moved["apps"][0]["state"] = json!("offline");
        moved["apps"][1]["state"] = json!("online");
        let render = |listed: &Value| {
            brief(&Reach {
                computer: true,
                account: Account::Listed(AccountApps::parse(listed).unwrap()),
            })
        };
        assert_eq!(render(&listed()), render(&moved));
    }

    #[test]
    fn every_tool_the_brief_names_is_one_the_server_offers() {
        let text = brief(&Reach {
            computer: true,
            account: Account::Listed(AccountApps::default()),
        });
        let offered: Vec<&str> = crate::TOOLS.iter().map(|tool| tool.name).collect();
        for named in [
            "whoami",
            "session_catalog",
            "session_prompt",
            "session_create",
            "terminal_write",
            "terminal_screen",
            "elicitation_request",
            "computer_tools",
            "apps_run",
            "apps_search",
            "apps_list",
        ] {
            assert!(
                text.contains(&format!("`{named}`")),
                "{named} not in the brief"
            );
            assert!(offered.contains(&named), "{named} is not a tool");
        }
        assert!(text.contains("`computer({ tool, args })`"));
        assert!(offered.contains(&crate::COMPUTER));
        // What `computer` runs, as its `tool`.
        for named in ["get_window_state", "run_steps", "run_script"] {
            assert!(
                text.contains(&format!("`{named}`")),
                "{named} not in the brief"
            );
            assert!(
                axo_computer::TOOLS.contains(&named),
                "{named} is not a computer tool"
            );
        }
        assert!(text.contains(&format!("`{}`", axo_computer::REQUEST_INPUT)));
    }
}
