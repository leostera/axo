//! A stand-in for Claude Code 2.1.327's TUI in tests: `--version`, and the interactive TUI
//! (`--session-id ID | --resume ID`, `--settings`, `--mcp-config`, `--append-system-prompt`).
//! It posts its hooks to the HTTP URL in `--settings`, reads its terminal raw, and takes a
//! bracketed paste followed by Enter as a prompt: `UserPromptSubmit`, a transcript in Claude's
//! format under `$CLAUDE_CONFIG_DIR/projects` (or `$HOME/.claude/projects`), then `Stop` with `echo: <text>`, and only then (as Claude does) the reply in the transcript. The prompt `hang`
//! runs until Escape, which (as Claude does) posts no hook.
//!
//! In a folder its `.claude.json` (in `$CLAUDE_CONFIG_DIR`, or the home) does not trust, as
//! Claude does, it first asks whether to trust it, with "No, exit" chosen, and runs no hook
//! until answered: Down then Enter trusts the folder (and records it), Enter alone exits.
//!
//! It logs to `$AXO_FAKE_CLAUDE_LOG`, or `fake-claude.log` in its working directory.

use std::io::{Read, Write};
use std::net::TcpStream;

use serde_json::{Value, json};

fn log(line: &str) {
    let path = std::env::var("AXO_FAKE_CLAUDE_LOG").unwrap_or_else(|_| "fake-claude.log".into());
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(format!("{line}\n").as_bytes());
    }
}

fn argument(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|arg| arg == name).and_then(|index| args.get(index + 1).cloned())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--version") {
        println!("2.1.327 (Claude Code)");
        return;
    }
    let (resumed, id) = match (argument(&args, "--resume"), argument(&args, "--session-id")) {
        (Some(id), _) => (true, id),
        (None, Some(id)) => (false, id),
        _ => panic!("no conversation"),
    };
    let settings: Value = serde_json::from_str(&argument(&args, "--settings").unwrap_or_default()).unwrap_or_default();
    let url = settings["hooks"]["Stop"][0]["hooks"][0]["url"].as_str().unwrap_or_default().to_owned();
    log(&format!("tui {} {id}", if resumed { "resume" } else { "new" }));
    if let Some(mcp) = argument(&args, "--mcp-config") {
        log(&format!("mcp {mcp}"));
    }
    if let Some(brief) = argument(&args, "--append-system-prompt") {
        log(&format!("brief {}", brief.lines().next().unwrap_or_default()));
    }
    let cwd = std::env::current_dir().unwrap().display().to_string();
    let home = std::env::var("HOME").unwrap();
    let config = std::env::var("CLAUDE_CONFIG_DIR").unwrap_or_else(|_| format!("{home}/.claude"));
    let project = format!("{config}/projects/{}", cwd.replace(|c: char| !c.is_ascii_alphanumeric(), "-"));
    let transcript = format!("{project}/{id}.jsonl");
    let hook = |name: &str, fields: Value| {
        let mut body = json!({ "session_id": id, "transcript_path": transcript, "cwd": cwd, "hook_event_name": name });
        for (key, value) in fields.as_object().unwrap() {
            body[key] = value.clone();
        }
        post(&url, &body);
        log(&format!("hook {name}"));
    };
    raw_terminal();
    let record = if std::env::var_os("CLAUDE_CONFIG_DIR").is_some() {
        format!("{config}/.claude.json")
    } else {
        format!("{home}/.claude.json")
    };
    if !trusted(&record, &cwd) && !ask_for_trust(&record, &cwd) {
        log("exit untrusted");
        return;
    }
    hook("SessionStart", json!({ "source": if resumed { "resume" } else { "startup" }, "model": "claude-opus-5" }));
    let mut input = Vec::new();
    let mut byte = [0_u8; 1];
    // Unbuffered, so that poll sees what is not read yet.
    // SAFETY: fd 0 is the PTY, owned by this process for its life.
    let mut stdin = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(0) };
    while stdin.read(&mut byte).map(|read| read == 1).unwrap_or(false) {
        input.push(byte[0]);
        if input == b"\x1b" {
            // A lone Escape, unless more of a sequence follows at once.
            std::thread::sleep(std::time::Duration::from_millis(30));
            if !has_input() {
                log("escape");
                input.clear();
            }
            continue;
        }
        if input == b"\x03\x03" {
            log("exit");
            return;
        }
        if input.ends_with(b"\x1b[201~\r") {
            let text = String::from_utf8_lossy(&input[6..input.len() - 7]).into_owned();
            input.clear();
            log(&format!("prompt {text}"));
            // As Claude Code 2.1.327 does: the file and the prompt's line come after
            // UserPromptSubmit, and the reply reaches the file only after Stop.
            hook("UserPromptSubmit", json!({ "prompt": text }));
            write_user(&transcript, &id, &text);
            if text != "hang" {
                hook("Stop", json!({ "last_assistant_message": format!("echo: {text}"), "stop_hook_active": false }));
                std::thread::sleep(std::time::Duration::from_millis(300));
                write_assistant(&transcript, &id, &text);
            }
        } else if !input.starts_with(b"\x1b") && !input.starts_with(b"\x03") {
            input.clear();
        }
    }
}

fn write_user(transcript: &str, id: &str, text: &str) {
    append(transcript, &json!({
        "parentUuid": null, "isSidechain": false, "type": "user",
        "message": { "role": "user", "content": text },
        "uuid": format!("u-{}", text.len()), "timestamp": "2026-08-05T18:59:15.639Z",
        "cwd": "/tmp", "sessionId": id, "version": "2.1.327",
    }));
}

fn write_assistant(transcript: &str, id: &str, text: &str) {
    append(transcript, &json!({
        "parentUuid": format!("u-{}", text.len()), "isSidechain": false, "type": "assistant",
        "message": { "model": "claude-opus-5", "id": "msg_1", "type": "message", "role": "assistant",
            "content": [{ "type": "text", "text": format!("echo: {text}") }], "stop_reason": "end_turn",
            "usage": { "input_tokens": 1, "output_tokens": 1 } },
        "uuid": format!("a-{}", text.len()), "timestamp": "2026-08-05T18:59:16.639Z",
        "cwd": "/tmp", "sessionId": id, "version": "2.1.327",
    }));
}

fn append(transcript: &str, record: &Value) {
    // Claude makes the project's directory only when it first writes there.
    std::fs::create_dir_all(std::path::Path::new(transcript).parent().unwrap()).unwrap();
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(transcript).unwrap();
    file.write_all(format!("{record}\n").as_bytes()).unwrap();
}

/// Whether `.claude.json` at `record` trusts `cwd` or a folder above it.
fn trusted(record: &str, cwd: &str) -> bool {
    let config: Value = std::fs::read_to_string(record)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    std::path::Path::new(cwd)
        .ancestors()
        .any(|folder| config["projects"][folder.to_str().unwrap_or_default()]["hasTrustDialogAccepted"] == true)
}

/// Claude's question, until the person answers: whether they trusted the folder.
fn ask_for_trust(record: &str, cwd: &str) -> bool {
    log("asks trust");
    let mut stdout = std::io::stdout();
    let _ = write!(
        stdout,
        " Accessing workspace:\r\n\r\n {cwd}\r\n\r\n Quick safety check: Is this a project you created or one you trust?\r\n\r\n ❯ No, exit\r\n   Yes, I trust this folder\r\n\r\n Enter to confirm · Esc to cancel\r\n"
    );
    let _ = stdout.flush();
    // SAFETY: fd 0 is the PTY, owned by this process for its life.
    let mut stdin = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(0) };
    let (mut yes, mut input, mut byte) = (false, Vec::new(), [0_u8; 1]);
    while stdin.read(&mut byte).map(|read| read == 1).unwrap_or(false) {
        input.push(byte[0]);
        if input.ends_with(b"\x1b[B") {
            yes = true;
        } else if input.ends_with(b"\x1b[A") {
            yes = false;
        } else if byte[0] == b'\r' {
            break;
        }
    }
    std::mem::forget(stdin);
    if !yes {
        return false;
    }
    let mut config: Value = std::fs::read_to_string(record)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_else(|| json!({}));
    config["projects"][cwd]["hasTrustDialogAccepted"] = json!(true);
    std::fs::write(record, config.to_string()).unwrap();
    // As Ink does, the question is cleared once answered.
    let _ = write!(stdout, "\x1b[2J\x1b[H ❯ \r\n");
    let _ = stdout.flush();
    log("trusted");
    true
}

fn post(url: &str, body: &Value) {
    let Some(rest) = url.strip_prefix("http://") else { return };
    let Some(slash) = rest.find('/') else { return };
    let (address, path) = rest.split_at(slash);
    let Ok(mut stream) = TcpStream::connect(address) else { return };
    let body = body.to_string();
    let _ = write!(
        stream,
        "POST {path} HTTP/1.1\r\nHost: {address}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    let mut answer = String::new();
    let _ = stream.read_to_string(&mut answer);
}

fn raw_terminal() {
    // SAFETY: termios on stdin, which is the PTY.
    unsafe {
        let mut termios: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(0, &mut termios) == 0 {
            libc::cfmakeraw(&mut termios);
            libc::tcsetattr(0, libc::TCSANOW, &termios);
        }
    }
}

fn has_input() -> bool {
    let mut descriptor = libc::pollfd { fd: 0, events: libc::POLLIN, revents: 0 };
    // SAFETY: one pollfd for stdin.
    unsafe { libc::poll(&mut descriptor, 1, 0) > 0 }
}
