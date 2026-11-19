//! `axod mcp`: an MCP stdio bridge to the already-running, per-user daemon.
//! Input closes/cancellation drop the pipe, retiring any permission request.
use super::*;
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::net::windows::named_pipe::ClientOptions;

const MAX_FRAME: u64 = 1024 * 1024;

pub fn serve_stdio(pipe: Option<String>, session: String) -> io::Result<()> {
    let session: SessionId = session.parse().map_err(io::Error::other)?;
    let pipe = pipe.unwrap_or(format!(r"\\.\pipe\Axo-{}", security::current_sid()?));
    if !pipe.starts_with(r"\\.\pipe\") {
        return Err(invalid("MCP needs a local named pipe"));
    }
    let (input, mut messages) = tokio::sync::mpsc::channel(16);
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        loop {
            let mut line = String::new();
            use std::io::Read;
            match stdin.by_ref().take(MAX_FRAME + 1).read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) if line.len() as u64 > MAX_FRAME => break,
                _ => {}
            }
            if !line.trim().is_empty() && input.blocking_send(line).is_err() {
                break;
            }
        }
    });
    let stdout = Arc::new(Mutex::new(std::io::stdout()));
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async move {
        let mut running: HashMap<String, (u64, tokio::task::JoinHandle<()>)> = HashMap::new();
        let (done, mut completed) = tokio::sync::mpsc::channel::<(String, u64)>(32);
        let mut generation = 0u64;
        loop {
            tokio::select! {
                Some((key, finished)) = completed.recv() => {
                    if running.get(&key).is_some_and(|(current, _)| *current == finished) { running.remove(&key); }
                }
                line = messages.recv() => {
                    let Some(line) = line else { break; };
                    let message: Value = match serde_json::from_str(&line) {
                        Ok(value) => value,
                        Err(_) => { write(&stdout, json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}))?; continue; }
                    };
                    let method = message["method"].as_str().unwrap_or_default();
                    if method == "notifications/cancelled" {
                        let key = message["params"]["requestId"].to_string();
                        if let Some((_, task)) = running.remove(&key) { task.abort(); }
                        continue;
                    }
                    let Some(id) = message.get("id").filter(|id| id.is_number() || id.is_string()).cloned() else { continue; };
                    let key = id.to_string();
                    if message["jsonrpc"] != "2.0" || running.contains_key(&key) || running.len() >= 16 {
                        write(&stdout, json!({"jsonrpc":"2.0","id":id,"error":{"code":-32600,"message":"Invalid request, duplicate id, or too many calls"}}))?;
                        continue;
                    }
                    let (pipe, stdout, done) = (pipe.clone(), stdout.clone(), done.clone());
                    let task_key = key.clone();
                    generation += 1;
                    running.insert(key, (generation, tokio::spawn(async move {
                        let reply = match handle(&pipe, session, &message).await {
                            Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
                            Err(e) => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32602,"message":e.to_string()}}),
                        };
                        let _ = write(&stdout, reply);
                        let _ = done.send((task_key, generation)).await;
                    })));
                }
            }
        }
        for (_, (_, task)) in running { task.abort(); }
        Ok(())
    })
}

fn write(stdout: &Mutex<std::io::Stdout>, value: Value) -> io::Result<()> {
    let mut out = stdout.lock().unwrap();
    serde_json::to_writer(&mut *out, &value)?;
    out.write_all(b"\n")?;
    out.flush()
}

async fn handle(pipe: &str, session: SessionId, message: &Value) -> io::Result<Value> {
    match message["method"].as_str().unwrap_or_default() {
        "initialize" => Ok(
            json!({"protocolVersion":"2025-06-18","serverInfo":{"name":"axo","version":env!("CARGO_PKG_VERSION")},"capabilities":{"tools":{}},
            "instructions":"self({}) returns your Axo Session ID. Use session_rename({sessionId:\"self\",name:\"new name\"}) to rename your own Session. This works without shell escalation or computer-use permission. Do not open daemon pipes from shell commands to rename a Session. Axo computer use runs on the person's Windows PC. Use computer_tools to read the supported tools and schemas, then call computer. Read a fresh get_window_state before each action; use returned window and element identifiers. Use run_steps for bounded sequences. Actions may ask the person in Axo or on their connected devices. confirm:true asks, never approves. Use request_input for supported sign-in forms. The person supplies private values in Axo and you receive a receipt. Never ask for passwords or one-time codes in chat or pass them as tool arguments."}),
        ),
        "ping" => Ok(json!({})),
        "resources/list" => Ok(json!({"resources":[]})),
        "resources/templates/list" => Ok(json!({"resourceTemplates":[]})),
        "prompts/list" => Ok(json!({"prompts":[]})),
        "tools/list" => Ok(json!({"tools":[
            {"name":"self","description":"Returns the calling Axo Session's ID.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"outputSchema":{"type":"object","required":["sessionId"],"properties":{"sessionId":{"type":"string"}}},"annotations":{"readOnlyHint":true}},
            {"name":"session_rename","description":"Renames your own Axo Session without shell commands or elevated permissions. sessionId must be self or your Session ID.","inputSchema":{"type":"object","required":["sessionId","name"],"properties":{"sessionId":{"type":"string"},"name":{"type":"string","minLength":1,"maxLength":80}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":false}},
            {"name":"computer_tools","description":"Lists native Windows computer tools and their input schemas. Optionally filter by tool name.","inputSchema":{"type":"object","properties":{"tool":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":true}},
            {"name":"computer","description":"Sees and operates Windows apps using one allowlisted native tool. Inspect computer_tools first. Permission is controlled by the person in Axo. confirm:true asks them first; nothing here approves on their behalf.","inputSchema":{"type":"object","required":["tool"],"properties":{"tool":{"type":"string"},"args":{"type":"object"},"confirm":{"type":"boolean"}},"additionalProperties":false}}
        ]})),
        "tools/call" => {
            let arguments = &message["params"]["arguments"];
            let result = match message["params"]["name"].as_str() {
                Some("self") => {
                    if !arguments.is_null() && !arguments.as_object().is_some_and(|args| args.is_empty()) {
                        return Err(invalid("self takes no arguments"));
                    }
                    let identity = json!({"sessionId":session});
                    json!({"content":[{"type":"text","text":identity.to_string()}],"structuredContent":identity})
                }
                Some("session_rename") => {
                    let params = rename_params(session, arguments.clone())?;
                    let result = rpc(pipe, method::SESSION_RENAME, params).await?;
                    json!({"content":[{"type":"text","text":result.to_string()}],"structuredContent":result})
                }
                Some("computer_tools") => {
                    let mut result = rpc(pipe, computer::TOOLS, json!({})).await?;
                    if let Some(name) = arguments["tool"].as_str() {
                        if let Some(tools) = result["tools"].as_array_mut() { tools.retain(|t| t["name"] == name); }
                    }
                    json!({"content":[{"type":"text","text":result.to_string()}],"structuredContent":result})
                }
                Some("computer") => rpc(pipe, computer::CALL, json!({"sessionId":session,"tool":arguments["tool"],"args":arguments.get("args").cloned().unwrap_or(json!({})),"confirm":arguments.get("confirm").cloned().unwrap_or(json!(false)),"timeoutMs":300_000})).await?,
                _ => return Err(invalid("Unknown MCP tool")),
            };
            Ok(result)
        }
        _ => Err(invalid("Unknown MCP method")),
    }
}

// The tool never accepts a different Session, even when supplied a real UUID.
fn rename_params(session: SessionId, arguments: Value) -> io::Result<Value> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Rename {
        session_id: String,
        name: rpc::SessionName,
    }
    let request: Rename = serde_json::from_value(arguments)?;
    if request.session_id != "self" && request.session_id.parse::<SessionId>().ok() != Some(session)
    {
        return Err(invalid("session_rename may only rename your own Session"));
    }
    Ok(json!({"sessionId":session,"name":request.name.as_str()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rename_is_bound_to_the_bridge_session_and_preserves_the_exact_name() {
        let session: SessionId = "00000000-0000-4000-8000-000000000001".parse().unwrap();
        for target in ["self".to_owned(), session.to_string()] {
            let params =
                rename_params(session, json!({"sessionId":target,"name":"axo: windows"})).unwrap();
            assert_eq!(params, json!({"sessionId":session,"name":"axo: windows"}));
        }
        for arguments in [
            json!({"sessionId":"00000000-0000-4000-8000-000000000002","name":"other"}),
            json!({"sessionId":"self","name":""}),
            json!({"sessionId":"self","name":" leading"}),
            json!({"sessionId":"self","name":"control\ncharacter"}),
            json!({"sessionId":"self","name":"x".repeat(81)}),
            json!({"sessionId":"self","name":"😀".repeat(41)}),
            json!({"sessionId":"self","name":"ok","pipe":"other"}),
        ] {
            assert!(rename_params(session, arguments).is_err());
        }
    }
}

async fn rpc(pipe: &str, method: &str, params: Value) -> io::Result<Value> {
    static ID: AtomicU64 = AtomicU64::new(1);
    let mut client = None;
    for _ in 0..30 {
        match ClientOptions::new().open(pipe) {
            Ok(pipe) => {
                client = Some(pipe);
                break;
            }
            Err(e) if e.raw_os_error() == Some(231) => {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await
            }
            Err(e) => return Err(e),
        }
    }
    let mut client = client.ok_or_else(|| io::Error::other("Axo daemon is busy"))?;
    let id = ID.fetch_add(1, Ordering::Relaxed);
    let mut bytes =
        serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?;
    bytes.push(b'\n');
    client.write_all(&bytes).await?;
    client.flush().await?;
    let mut reader = BufReader::new(client).take(16 * 1024 * 1024 + 1);
    let mut line = String::new();
    tokio::time::timeout(
        std::time::Duration::from_secs(310),
        reader.read_line(&mut line),
    )
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Computer tool timed out"))??;
    if line.len() > 16 * 1024 * 1024 {
        return Err(invalid("Computer result is too large"));
    }
    let result: Value = serde_json::from_str(&line)?;
    if result["id"] != id {
        return Err(invalid("Unexpected daemon reply"));
    }
    if let Some(error) = result.get("error") {
        return Err(io::Error::other(
            error["message"].as_str().unwrap_or("Computer call failed"),
        ));
    }
    Ok(result["result"].clone())
}
