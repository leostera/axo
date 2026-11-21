//! Convert an authenticated Pi history into an idle Codex rollout. No turn is started here.
use super::*;
use axo_agent::PiForkHistory;
use std::io::{BufRead, Write};
use std::process::Stdio;
use std::time::Duration;

const MAX_ROLLOUT: u64 = 64 * 1024 * 1024;
pub(super) const CODEX_VERSION: &str = "0.168.0";

pub(super) fn converter() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    let path = executable.with_file_name("atxf-0.2.0.exe");
    path.is_file().then_some(path)
}

pub(super) fn resume_params(params: &mut Value, id: &str, rollout: &Path) {
    params["threadId"] = json!(id);
    params["path"] = json!(rollout);
    params["excludeTurns"] = json!(true);
}

pub(super) fn verify_resume(
    value: &Value,
    id: &str,
    folder: &Path,
    rollout: &Path,
) -> io::Result<()> {
    let thread = &value["thread"];
    let same = |value: &Value, path: &Path| {
        let actual = value
            .as_str()
            .and_then(|value| std::fs::canonicalize(value).ok());
        let expected = std::fs::canonicalize(path).ok();
        actual.is_some() && actual == expected
    };
    if thread["id"] != id
        || thread["status"]["type"] != "idle"
        || !same(&thread["path"], rollout)
        || !same(&value["cwd"], folder)
    {
        return Err(invalid(
            "Codex did not resume the exact imported child in the destination folder",
        ));
    }
    Ok(())
}

pub(super) struct Imported {
    pub path: PathBuf,
    pub messages: Vec<ImportedMessage>,
}

pub(super) struct ImportedMessage {
    pub role: &'static str,
    pub text: String,
}

pub(super) async fn convert(
    converter: &Path,
    directory: &Path,
    child: SessionId,
    folder: &Path,
    source_host: &str,
    destination_host: &str,
    history: PiForkHistory,
) -> io::Result<Imported> {
    let stamp = axo_relay::current_timestamp();
    let input = history.into_child(child, folder, source_host, destination_host, &stamp)?;
    let provenance: Value = serde_json::from_str(
        std::str::from_utf8(&input)
            .map_err(io::Error::other)?
            .lines()
            .last()
            .ok_or_else(|| invalid("Fork provenance is missing"))?,
    )?;
    let provenance = provenance["content"]
        .as_str()
        .ok_or_else(|| invalid("Fork provenance is invalid"))?;
    let private = directory.join(child.to_string());
    std::fs::create_dir_all(directory)?;
    std::fs::create_dir(&private)?;
    let source = private.join("history.pi.jsonl");
    std::fs::write(&source, &input)?;
    let output = convert_with(converter, &source).await?;
    let rollout = private.join(format!(
        "rollout-{}-{child}.jsonl",
        stamp[..19].replace(':', "-")
    ));
    let messages = write_rollout(
        output.as_slice(),
        &rollout,
        child,
        folder,
        &stamp,
        provenance,
    )?;
    Ok(Imported {
        path: rollout,
        messages,
    })
}

async fn convert_with(executable: &Path, source: &Path) -> io::Result<Vec<u8>> {
    let mut child = tokio::process::Command::new(executable)
        .args(["convert", "--from", "pi", "--to", "codex", "--no-carry"])
        .arg(source)
        .creation_flags(0x08000000) // CREATE_NO_WINDOW
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let stdout = child.stdout.take().expect("piped stdout");
    tokio::time::timeout(Duration::from_secs(15), async {
        let mut contents = Vec::new();
        stdout
            .take(MAX_ROLLOUT + 1)
            .read_to_end(&mut contents)
            .await?;
        if contents.len() as u64 > MAX_ROLLOUT || !child.wait().await?.success() {
            return Err(invalid("ATXF did not produce a bounded Codex rollout"));
        }
        Ok(contents)
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "ATXF conversion timed out"))?
}

fn write_rollout(
    converted: impl BufRead,
    rollout: &Path,
    child: SessionId,
    folder: &Path,
    stamp: &str,
    expected_provenance: &str,
) -> io::Result<Vec<ImportedMessage>> {
    let mut lines = converted.lines();
    let header: Value = serde_json::from_str(
        &lines
            .next()
            .transpose()?
            .ok_or_else(|| invalid("ATXF returned no Codex history"))?,
    )?;
    if header["type"] != "session_meta" {
        return Err(invalid("ATXF did not return Codex session metadata first"));
    }
    let mut output = std::io::BufWriter::new(
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(rollout)?,
    );
    // Never carry over the source model, cwd, permissions, or base instructions.
    writeln!(
        output,
        "{}",
        json!({"timestamp":stamp,"type":"session_meta","payload":{
            "id":child,"timestamp":stamp,"cwd":folder,"originator":"atxf","cli_version":CODEX_VERSION,"source":"cli"
        }})
    )?;
    let mut messages = Vec::new();
    let mut provenance = 0;
    for line in lines {
        let record: Value = serde_json::from_str(&line?)?;
        let payload = &record["payload"];
        // Historical provider tool calls may have no matching result at the captured head.
        // Materialize them as historical developer text, not runnable Codex protocol items.
        let record = match (
            record["type"].as_str(),
            payload["type"].as_str(),
            payload["role"].as_str(),
        ) {
            (Some("response_item"), Some("message"), Some(role @ ("user" | "assistant"))) => {
                let text = message_text(payload);
                if !text.is_empty() {
                    messages.push(ImportedMessage {
                        role: if role == "user" { "user" } else { "assistant" },
                        text,
                    });
                }
                record
            }
            (Some("response_item"), Some("message"), Some("developer")) => {
                if message_text(payload) == expected_provenance {
                    provenance += 1;
                }
                record
            }
            (
                Some("response_item"),
                Some(
                    "function_call"
                    | "function_call_output"
                    | "custom_tool_call"
                    | "custom_tool_call_output",
                ),
                _,
            ) => developer(
                stamp,
                &format!("Historical source tool record (not runnable): {payload}"),
            ),
            (Some("compacted"), _, _) => developer(
                stamp,
                &format!(
                    "Historical conversation summary: {}",
                    payload["message"].as_str().unwrap_or_default()
                ),
            ),
            (Some("response_item"), Some("reasoning"), _) => {
                // Provider reasoning blobs are not reusable by the destination model.
                developer(
                    stamp,
                    &format!(
                        "Historical source reasoning summary: {}",
                        payload["summary"]
                    ),
                )
            }
            (Some("turn_context"), _, _) => continue,
            _ => return Err(invalid("ATXF returned an unsupported Codex record")),
        };
        writeln!(output, "{record}")?;
    }
    if provenance != 1 {
        return Err(invalid("ATXF did not retain hidden fork provenance"));
    }
    output.flush()?;
    output.get_ref().sync_all()?;
    Ok(messages)
}

fn developer(stamp: &str, text: &str) -> Value {
    json!({"timestamp":stamp,"type":"response_item","payload":{
        "type":"message","role":"developer","content":[{"type":"input_text","text":text}]
    }})
}

fn message_text(payload: &Value) -> String {
    payload["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n")
}
