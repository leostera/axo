//! Claude Code's HTTP hooks, as axod receives them: a listener on a loopback port for one
//! launch, at a path with a secret in it, and the `--settings` document that points every hook
//! axod follows at it. Claude posts each hook's JSON and goes on whatever the answer; axod
//! answers `200` with an empty body, which decides nothing.

use std::io;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

/// The hooks axod follows.
pub const EVENTS: [&str; 10] = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "PermissionDenied",
    "Notification",
    "Stop",
    "StopFailure",
];
/// The largest hook body read; a tool's input or response rides in it.
const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_HEAD: usize = 16 * 1024;
/// How long Claude waits for a hook (seconds), and axod for a hook's request.
const HOOK_TIMEOUT_SECONDS: u64 = 5;
const READ_TIMEOUT: Duration = Duration::from_secs(5);
const QUEUED_HOOKS: usize = 256;

/// A bound listener and the URL Claude posts to.
pub struct HookListener {
    listener: std::net::TcpListener,
    path: String,
    url: String,
}

impl std::fmt::Debug for HookListener {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("HookListener").finish_non_exhaustive()
    }
}

impl HookListener {
    /// Binds `127.0.0.1` on a port the system picks, at a path with 244 random bits.
    pub fn bind() -> io::Result<Self> {
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let secret = format!(
            "{}{}",
            axo_protocol::new_uuid_v4()?.replace('-', ""),
            axo_protocol::new_uuid_v4()?.replace('-', "")
        );
        let path = format!("/hook/{secret}");
        Ok(Self {
            listener,
            url: format!("http://127.0.0.1:{port}{path}"),
            path,
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    /// Accepts hooks until the receiver is dropped; each well-formed JSON object posted to the
    /// secret path is sent on. Must run inside a Tokio runtime.
    pub fn serve(self) -> io::Result<mpsc::Receiver<Value>> {
        let listener = TcpListener::from_std(self.listener)?;
        let (sender, receiver) = mpsc::channel(QUEUED_HOOKS);
        let path = self.path;
        tokio::spawn(async move {
            loop {
                let accepted = tokio::select! {
                    accepted = listener.accept() => accepted,
                    () = sender.closed() => return,
                };
                let Ok((stream, _)) = accepted else { continue };
                let (sender, path) = (sender.clone(), path.clone());
                tokio::spawn(async move {
                    if let Ok(Ok(Some(hook))) =
                        tokio::time::timeout(READ_TIMEOUT, receive(stream, &path)).await
                    {
                        let _ = sender.send(hook).await;
                    }
                });
            }
        });
        Ok(receiver)
    }
}

/// Reads one request; answers it, and returns its JSON when it is a hook for `path`.
async fn receive(mut stream: TcpStream, path: &str) -> io::Result<Option<Value>> {
    let mut buffer = Vec::new();
    let (head, length, ours) = loop {
        let mut chunk = [0_u8; 8192];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(None);
        }
        buffer.extend_from_slice(&chunk[..read]);
        let mut headers = [httparse::EMPTY_HEADER; 32];
        let mut request = httparse::Request::new(&mut headers);
        match request.parse(&buffer) {
            Ok(httparse::Status::Complete(head)) => {
                let length = request
                    .headers
                    .iter()
                    .find(|header| header.name.eq_ignore_ascii_case("content-length"))
                    .and_then(|header| std::str::from_utf8(header.value).ok())
                    .and_then(|value| value.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                let ours = request.method == Some("POST") && request.path == Some(path);
                break (head, length, ours);
            }
            Ok(httparse::Status::Partial) if buffer.len() < MAX_HEAD => {}
            _ => {
                answer(&mut stream, "400 Bad Request").await?;
                return Ok(None);
            }
        }
    };
    if !ours {
        answer(&mut stream, "404 Not Found").await?;
        return Ok(None);
    }
    if length > MAX_BODY {
        answer(&mut stream, "413 Payload Too Large").await?;
        return Ok(None);
    }
    let mut body = buffer.split_off(head);
    while body.len() < length {
        let mut chunk = vec![0_u8; (length - body.len()).min(64 * 1024)];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(None);
        }
        body.extend_from_slice(&chunk[..read]);
    }
    body.truncate(length);
    answer(&mut stream, "200 OK").await?;
    Ok(serde_json::from_slice::<Value>(&body).ok().filter(Value::is_object))
}

async fn answer(stream: &mut TcpStream, status: &str) -> io::Result<()> {
    stream
        .write_all(format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes())
        .await?;
    stream.shutdown().await
}

/// The `--settings` document: an HTTP hook to `url` for each event axod follows.
pub fn settings(url: &str) -> Value {
    let hook = json!([{ "hooks": [{ "type": "http", "url": url, "timeout": HOOK_TIMEOUT_SECONDS }] }]);
    let hooks: serde_json::Map<String, Value> = EVENTS
        .iter()
        .map(|event| ((*event).to_owned(), hook.clone()))
        .collect();
    json!({ "hooks": hooks })
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn post(url: &str, body: &str) -> String {
        let rest = url.strip_prefix("http://").unwrap();
        let (address, path) = rest.split_at(rest.find('/').unwrap());
        let mut stream = TcpStream::connect(address).await.unwrap();
        let request = format!(
            "POST {path} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        // Split, as a client may write it.
        let (first, second) = request.as_bytes().split_at(request.len() / 2);
        stream.write_all(first).await.unwrap();
        stream.write_all(second).await.unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).await.unwrap();
        answer
    }

    #[tokio::test]
    async fn hooks_posted_to_the_secret_path_are_received_and_nothing_else_is() {
        let listener = HookListener::bind().unwrap();
        let url = listener.url().to_owned();
        assert!(url.starts_with("http://127.0.0.1:"));
        let mut hooks = listener.serve().unwrap();
        assert!(post(&url, r#"{"hook_event_name":"Stop"}"#).await.starts_with("HTTP/1.1 200"));
        assert_eq!(hooks.recv().await.unwrap()["hook_event_name"], "Stop");
        let guessed = format!("{}/hook/guess", url.split("/hook/").next().unwrap());
        assert!(post(&guessed, "{}").await.starts_with("HTTP/1.1 404"));
        assert!(post(&url, "not json").await.starts_with("HTTP/1.1 200"));
        assert!(post(&url, r#"{"n":2}"#).await.starts_with("HTTP/1.1 200"));
        assert_eq!(hooks.recv().await.unwrap()["n"], 2, "only the JSON object came through");
    }

    #[test]
    fn every_followed_hook_posts_to_the_url() {
        let settings = settings("http://127.0.0.1:1/hook/s");
        for event in EVENTS {
            assert_eq!(settings["hooks"][event][0]["hooks"][0]["url"], "http://127.0.0.1:1/hook/s");
            assert_eq!(settings["hooks"][event][0]["hooks"][0]["type"], "http");
        }
    }
}
