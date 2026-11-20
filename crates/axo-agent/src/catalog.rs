//! Model discovery on the host, without opening a Session or submitting a prompt.
use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use axo_protocol::{PiModelInfo, ThinkingLevel};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};

use crate::{AgentKind, discovery};

const DEADLINE: Duration = Duration::from_secs(6);
const MAX_OUTPUT: u64 = 512 * 1024;
const MAX_MODELS: usize = 300;

#[derive(Debug)]
pub enum CatalogError {
    NotInstalled,
    Busy,
    Failed,
}

pub async fn models(home: &Path, agent: AgentKind) -> Result<Vec<PiModelInfo>, CatalogError> {
    static PROBES: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
    let slot = PROBES.try_acquire().map_err(|_| CatalogError::Busy)?;
    let binary = discovery::find(
        agent,
        &discovery::SearchPlaces::from_environment(agent, home),
    )
    .map_err(|_| CatalogError::NotInstalled)?;
    // Own the probe through cleanup even if the requesting connection goes away.
    let home = home.to_path_buf();
    tokio::spawn(async move {
        let _slot = slot;
        read_models(&binary, &home, agent)
            .await
            .map_err(|_| CatalogError::Failed)
    })
    .await
    .map_err(|_| CatalogError::Failed)?
}

async fn read_models(binary: &Path, home: &Path, agent: AgentKind) -> io::Result<Vec<PiModelInfo>> {
    let args: &[&str] = match agent {
        AgentKind::Pi => &["--no-extensions", "--list-models"],
        AgentKind::OpenCode => &["models"],
        AgentKind::Codex => &["app-server", "--listen", "stdio://"],
        AgentKind::ClaudeCode => &[
            "--print",
            "--bare",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config",
            r#"{"mcpServers":{}}"#,
            "--tools",
            "",
            "--disable-slash-commands",
        ],
    };
    let control_protocol = matches!(agent, AgentKind::Codex | AgentKind::ClaudeCode);
    let mut command = Command::new(binary);
    command
        .args(args)
        .current_dir(home)
        .env("HOME", home)
        .env("PWD", home)
        .env("NO_COLOR", "1")
        .stdin(if control_protocol {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    if agent == AgentKind::ClaudeCode {
        command
            .env("DISABLE_NONESSENTIAL_TRAFFIC", "1")
            .env("DISABLE_TELEMETRY", "1")
            .env("DISABLE_ERROR_REPORTING", "1");
    }
    // OpenCode 2 uses a shared service by default; legacy versions run the command
    // directly and don't recognize this option.
    if agent == AgentKind::Pi {
        command.env("PI_SKIP_VERSION_CHECK", "1");
    }
    if agent == AgentKind::OpenCode {
        command.env("OPENCODE_DISABLE_AUTOUPDATE", "true");
        let installed = discovery::discover(
            agent,
            &discovery::SearchPlaces::from_environment(agent, home),
            discovery::VERSION_TIMEOUT,
        )
        .await
        .map_err(|_| io::Error::other("could not identify OpenCode CLI"))?;
        if installed.version.major >= 2 {
            command.arg("--standalone");
        }
    }
    let mut child = command.spawn()?;
    let result = tokio::time::timeout(DEADLINE, async {
        match agent {
            AgentKind::Codex => return codex_models(&mut child).await,
            AgentKind::ClaudeCode => return claude_models(&mut child).await,
            _ => {}
        }
        let mut bytes = Vec::new();
        child
            .stdout
            .take()
            .ok_or(io::ErrorKind::BrokenPipe)?
            .take(MAX_OUTPUT + 1)
            .read_to_end(&mut bytes)
            .await?;
        if bytes.len() as u64 > MAX_OUTPUT {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let output = std::str::from_utf8(&bytes).map_err(io::Error::other)?;
        parse_lines(agent, output)
    })
    .await
    .unwrap_or_else(|_| Err(io::ErrorKind::TimedOut.into()));

    // For ordinary CLI queries require successful exit. Terminate an owned
    // server or failed/hung CLI, never a shared or Session process.
    if !control_protocol && result.is_ok() {
        match tokio::time::timeout(Duration::from_millis(250), child.wait()).await {
            Ok(Ok(status)) => {
                return if status.success() {
                    result
                } else {
                    Err(io::Error::other("catalog command failed"))
                };
            }
            Ok(Err(error)) => return Err(error),
            Err(_) => {}
        }
    }
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        // The unreaped child owns this group ID. Negative PID targets only that group.
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
    }
    let _ = child.kill().await;
    if !control_protocol && result.is_ok() {
        return Err(io::ErrorKind::TimedOut.into());
    }
    result
}

fn model(
    provider: &str,
    id: &str,
    name: &str,
    thinking_levels: Vec<ThinkingLevel>,
) -> Option<PiModelInfo> {
    let safe = |value: &str| {
        !value.is_empty()
            && value.encode_utf16().count() <= 128
            && !value.chars().any(char::is_control)
            && value.trim() == value
    };
    // Neither command diagnostics nor credential-like arbitrary fields are part of this wire format.
    if !safe(provider) || !safe(id) || !safe(name) {
        return None;
    }
    Some(PiModelInfo {
        provider: provider.into(),
        id: id.into(),
        name: name.into(),
        thinking_levels,
    })
}

fn parse_lines(agent: AgentKind, output: &str) -> io::Result<Vec<PiModelInfo>> {
    let mut lines = output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    if agent == AgentKind::Pi {
        let Some(header) = lines.next() else {
            return Err(io::ErrorKind::InvalidData.into());
        };
        if header.starts_with("No models available") {
            return Ok(vec![]);
        }
        if !header.split_whitespace().take(2).eq(["provider", "model"]) {
            return Err(io::ErrorKind::InvalidData.into());
        }
    }
    let mut models = Vec::new();
    let mut seen = HashSet::new();
    for line in lines {
        let (provider, id) = if agent == AgentKind::Pi {
            let mut fields = line.split_whitespace();
            let (Some(provider), Some(id)) = (fields.next(), fields.next()) else {
                return Err(io::ErrorKind::InvalidData.into());
            };
            (provider, id)
        } else {
            let Some((provider, id)) = line.split_once('/') else {
                return Err(io::ErrorKind::InvalidData.into());
            };
            (provider, id)
        };
        if provider.chars().any(char::is_whitespace) || id.chars().any(char::is_whitespace) {
            return Err(io::ErrorKind::InvalidData.into());
        }
        // These CLI lists don't enumerate the model's exact supported thinking levels.
        if let Some(info) = model(provider, id, id, vec![])
            && seen.insert((provider, id))
        {
            models.push(info);
            if models.len() == MAX_MODELS {
                break;
            }
        }
    }
    Ok(models)
}

// Same initialization receipt as the Agent SDK's supportedModels. Bare mode
// advertises aliases; it does not establish provider authorization.
async fn claude_models(child: &mut Child) -> io::Result<Vec<PiModelInfo>> {
    let mut input = child.stdin.take().ok_or(io::ErrorKind::BrokenPipe)?;
    let mut output = BufReader::new(
        child
            .stdout
            .take()
            .ok_or(io::ErrorKind::BrokenPipe)?
            .take(MAX_OUTPUT),
    );
    request(
        &mut input,
        &json!({"type":"control_request","request_id":"models","request":{"subtype":"initialize"}}),
    )
    .await?;
    let mut line = String::new();
    loop {
        line.clear();
        if output.read_line(&mut line).await? == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let value: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
        let reply = &value["response"];
        if value["type"] == "control_response" && reply["request_id"] == "models" {
            if reply["subtype"] != "success" {
                return Err(io::Error::other("Claude Code initialization refused"));
            }
            return parse_claude(&reply["response"]["models"]);
        }
    }
}

fn parse_claude(items: &Value) -> io::Result<Vec<PiModelInfo>> {
    let items = items.as_array().ok_or(io::ErrorKind::InvalidData)?;
    let mut seen = HashSet::new();
    Ok(items
        .iter()
        .filter_map(|row| {
            let id = row["value"].as_str()?;
            let info = model(
                "claude-code",
                id,
                row["displayName"].as_str().unwrap_or(id),
                vec![],
            )?;
            seen.insert(id).then_some(info)
        })
        .take(MAX_MODELS)
        .collect())
}

async fn codex_models(child: &mut Child) -> io::Result<Vec<PiModelInfo>> {
    let mut input = child.stdin.take().ok_or(io::ErrorKind::BrokenPipe)?;
    let mut output = BufReader::new(
        child
            .stdout
            .take()
            .ok_or(io::ErrorKind::BrokenPipe)?
            .take(MAX_OUTPUT),
    );
    let init = json!({"id":1,"method":"initialize","params":{
        "clientInfo":{"name":"axod","version":env!("CARGO_PKG_VERSION")},
        "capabilities":{"explicitGatewayOauth":true}
    }});
    request(&mut input, &init).await?;
    response(&mut output, 1).await?;
    request(&mut input, &json!({"method":"initialized"})).await?;
    // Read gateway state before the catalog. Older builds may not implement this
    // method; reject any other error instead of attempting authentication.
    request(
        &mut input,
        &json!({"id":2,"method":"account/gatewayOAuth/read"}),
    )
    .await?;
    let gateway = reply(&mut output, 2).await?;
    if let Some(error) = gateway.get("error")
        && error["code"].as_i64() != Some(-32601)
    {
        return Err(io::Error::other("catalog auth check failed"));
    }
    let mut cursor = None::<String>;
    let mut seen = HashSet::new();
    let mut models = Vec::new();
    for id in 3..=8 {
        request(
            &mut input,
            &json!({"id":id,"method":"model/list","params":{"limit":100,"cursor":cursor}}),
        )
        .await?;
        let page = response(&mut output, id).await?;
        let items = page["data"].as_array().ok_or(io::ErrorKind::InvalidData)?;
        for item in items.iter().filter(|item| item["hidden"] != true) {
            let Some(id) = item["id"].as_str() else {
                continue;
            };
            let name = item["displayName"].as_str().unwrap_or(id);
            let levels = item["supportedReasoningEfforts"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|effort| effort["reasoningEffort"].as_str())
                .filter_map(|effort| match effort {
                    "none" => Some(ThinkingLevel::Off),
                    "minimal" => Some(ThinkingLevel::Minimal),
                    "low" => Some(ThinkingLevel::Low),
                    "medium" => Some(ThinkingLevel::Medium),
                    "high" => Some(ThinkingLevel::High),
                    "xhigh" => Some(ThinkingLevel::Xhigh),
                    "max" => Some(ThinkingLevel::Max),
                    _ => None,
                })
                .take(7)
                .collect();
            if let Some(info) = model("codex", id, name, levels)
                && seen.insert(id.to_owned())
            {
                models.push(info);
                if models.len() == MAX_MODELS {
                    return Ok(models);
                }
            }
        }
        cursor = page["nextCursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            return Ok(models);
        }
    }
    Err(io::ErrorKind::InvalidData.into())
}

async fn request(input: &mut (impl AsyncWriteExt + Unpin), value: &Value) -> io::Result<()> {
    input.write_all(format!("{value}\n").as_bytes()).await
}

async fn reply(output: &mut (impl AsyncBufReadExt + Unpin), id: u64) -> io::Result<Value> {
    let mut line = String::new();
    loop {
        line.clear();
        if output.read_line(&mut line).await? == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let value: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
        if value["id"].as_u64() == Some(id) {
            return Ok(value);
        }
    }
}

async fn response(output: &mut (impl AsyncBufReadExt + Unpin), id: u64) -> io::Result<Value> {
    reply(output, id)
        .await?
        .get("result")
        .cloned()
        .ok_or_else(|| io::Error::other("catalog request failed"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_returns_advertised_aliases_not_raw_configuration() {
        let aliases = parse_claude(&json!([
            {"value":"sonnet","displayName":"Sonnet","description":"private config"},
            {"value":"sonnet","displayName":"duplicate"}
        ]))
        .unwrap();
        assert_eq!(aliases.len(), 1);
        assert_eq!(aliases[0].provider, "claude-code");
        assert_eq!(aliases[0].id, "sonnet");
        assert!(aliases[0].thinking_levels.is_empty());
        assert!(
            !serde_json::to_string(&aliases)
                .unwrap()
                .contains("private config")
        );
        assert!(parse_claude(&Value::Null).is_err());
    }

    #[test]
    fn cli_catalogs_only_report_models_and_do_not_guess_thinking_levels() {
        let pi = parse_lines(
            AgentKind::Pi,
            "provider   model  context max-out thinking images\nopenai gpt-5 400K 128K yes yes\n",
        )
        .unwrap();
        assert_eq!(pi[0].id, "gpt-5");
        assert!(pi[0].thinking_levels.is_empty());
        let open = parse_lines(
            AgentKind::OpenCode,
            "anthropic/claude-sonnet\nopenai/gpt-5\nopenai/gpt-5\n",
        )
        .unwrap();
        assert_eq!(open.len(), 2);
        assert_eq!(open[0].provider, "anthropic");
        assert!(parse_lines(AgentKind::Pi, "Please sign in").is_err());
        assert!(parse_lines(AgentKind::OpenCode, "Please sign in").is_err());
    }
}
