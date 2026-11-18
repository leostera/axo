//! Axo's MCP server (`axod mcp`, RFD0015) as each agent is configured with it. Pi gets it from
//! pi-axo; every other agent gets it at launch, in its own configuration format, with the same
//! command, environment, description and timeout pi-axo registers.

use std::path::PathBuf;

use serde_json::{Value, json};

/// A question to the person (elicitation_request) and a script (apps_run) each wait up to five
/// minutes; axod answers within that plus a margin. As pi-axo's `timeout: 330`.
pub const TOOL_TIMEOUT_SECONDS: u64 = 330;

/// What `axod mcp` needs to serve one Session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AxoMcp {
    /// The `axod` executable; its `mcp` subcommand is the server.
    pub axod: PathBuf,
    /// axod's local socket.
    pub socket: PathBuf,
    /// The Axo Session the agent runs in.
    pub session_id: String,
}

impl AxoMcp {
    fn environment(&self) -> Value {
        json!({
            "AXO_SOCKET": self.socket.to_string_lossy(),
            "AXO_SESSION_ID": self.session_id,
        })
    }

    /// Codex's `-c key=value` overrides (TOML values) for `mcp_servers.axo`, to go before its
    /// subcommand.
    pub fn codex_overrides(&self) -> Vec<String> {
        let values = [
            ("command", toml_string(&self.axod.to_string_lossy())),
            ("args", "[\"mcp\"]".to_owned()),
            (
                "env",
                format!(
                    "{{ AXO_SOCKET = {}, AXO_SESSION_ID = {} }}",
                    toml_string(&self.socket.to_string_lossy()),
                    toml_string(&self.session_id)
                ),
            ),
            ("tool_timeout_sec", TOOL_TIMEOUT_SECONDS.to_string()),
        ];
        values
            .into_iter()
            .flat_map(|(key, value)| ["-c".to_owned(), format!("mcp_servers.axo.{key}={value}")])
            .collect()
    }

    /// OpenCode's `mcp.axo`: a local server, its timeout in milliseconds.
    pub fn opencode_config(&self) -> Value {
        json!({
            "type": "local",
            "command": [self.axod.to_string_lossy(), "mcp"],
            "environment": self.environment(),
            "enabled": true,
            "timeout": TOOL_TIMEOUT_SECONDS * 1000,
        })
    }

    /// Claude Code's `--mcp-config` document.
    pub fn claude_config(&self) -> Value {
        json!({
            "mcpServers": {
                "axo": {
                    "type": "stdio",
                    "command": self.axod.to_string_lossy(),
                    "args": ["mcp"],
                    "env": self.environment(),
                }
            }
        })
    }
}

/// `text` as a TOML basic string.
pub fn toml_string(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\t' => quoted.push_str("\\t"),
            '\r' => quoted.push_str("\\r"),
            control if control.is_control() => {
                quoted.push_str(&format!("\\u{:04X}", control as u32));
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mcp() -> AxoMcp {
        AxoMcp {
            axod: PathBuf::from("/Applications/Axo.app/Contents/MacOS/axod"),
            socket: PathBuf::from("/Users/me/Library/Application Support/Axo/run/axod.sock"),
            session_id: "5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f".into(),
        }
    }

    #[test]
    fn codex_gets_the_server_as_config_overrides() {
        assert_eq!(
            mcp().codex_overrides(),
            [
                "-c",
                "mcp_servers.axo.command=\"/Applications/Axo.app/Contents/MacOS/axod\"",
                "-c",
                "mcp_servers.axo.args=[\"mcp\"]",
                "-c",
                "mcp_servers.axo.env={ AXO_SOCKET = \"/Users/me/Library/Application Support/Axo/run/axod.sock\", AXO_SESSION_ID = \"5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f\" }",
                "-c",
                "mcp_servers.axo.tool_timeout_sec=330",
            ]
        );
    }

    #[test]
    fn opencode_and_claude_code_get_the_same_server() {
        let opencode = mcp().opencode_config();
        assert_eq!(opencode["command"][1], "mcp");
        assert_eq!(opencode["timeout"], 330_000);
        let claude = mcp().claude_config();
        assert_eq!(claude["mcpServers"]["axo"]["args"], json!(["mcp"]));
        assert_eq!(
            claude["mcpServers"]["axo"]["env"]["AXO_SESSION_ID"],
            "5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f"
        );
    }

    #[test]
    fn toml_strings_escape_whatever_a_path_holds() {
        assert_eq!(toml_string(r#"a"b\c"#), r#""a\"b\\c""#);
        assert_eq!(toml_string("x\ny\u{7}"), "\"x\\ny\\u0007\"");
        // Every string round-trips through a tiny TOML basic-string reader.
        let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
        for _ in 0..2_000 {
            let text: String = (0..(seed % 24))
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    char::from_u32((seed % 0x500) as u32).unwrap_or('?')
                })
                .collect();
            assert_eq!(read_toml_string(&toml_string(&text)), text);
        }
    }

    fn read_toml_string(quoted: &str) -> String {
        let inner = &quoted[1..quoted.len() - 1];
        let mut out = String::new();
        let mut chars = inner.chars();
        while let Some(character) = chars.next() {
            if character != '\\' {
                assert!(character != '"' && !character.is_control(), "unescaped {character:?}");
                out.push(character);
                continue;
            }
            match chars.next().unwrap() {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                'u' => {
                    let hex: String = chars.by_ref().take(4).collect();
                    out.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap());
                }
                other => panic!("unknown escape {other}"),
            }
        }
        out
    }
}
