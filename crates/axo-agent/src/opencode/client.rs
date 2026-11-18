//! axod's HTTP client for one private `opencode serve` (v2 API, `packages/protocol` at
//! v2.0.20): JSON requests with the server's password, and its event stream.

use std::io;
use std::path::Path;
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::{Value, json};

/// OpenCode's username for basic authentication (`packages/server/src/auth.ts`).
const USERNAME: &str = "opencode";
/// The longest answer read; a session's export is the largest.
const MAX_ANSWER_BYTES: usize = 64 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Where a private server listens and the password it was started with.
#[derive(Clone, Eq, PartialEq)]
pub struct ServerAddress {
    /// `http://127.0.0.1:<port>`, without a trailing slash.
    pub url: String,
    pub password: String,
}

impl std::fmt::Debug for ServerAddress {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ServerAddress")
            .field("url", &self.url)
            .finish_non_exhaustive()
    }
}

impl ServerAddress {
    /// The address in the server's `server listening on <url>` line; only a loopback HTTP URL.
    pub fn from_listening_line(line: &str, password: String) -> Option<Self> {
        let url = line.trim().strip_prefix("server listening on ")?.trim_end_matches('/');
        let rest = url.strip_prefix("http://")?;
        let (host, port) = rest.rsplit_once(':')?;
        let loopback = matches!(host, "127.0.0.1" | "localhost" | "[::1]");
        (loopback && port.parse::<u16>().is_ok_and(|port| port != 0)).then(|| Self {
            url: url.to_owned(),
            password,
        })
    }
}

#[derive(Clone, Debug)]
pub struct Client {
    http: reqwest::Client,
    address: ServerAddress,
}

/// One event stream: bytes as the server writes them.
pub type EventBytes = futures_util::stream::BoxStream<'static, io::Result<Vec<u8>>>;

impl Client {
    pub fn new(address: ServerAddress) -> io::Result<Self> {
        let http = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .build()
            .map_err(io::Error::other)?;
        Ok(Self { http, address })
    }

    pub fn address(&self) -> &ServerAddress {
        &self.address
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.address.url)
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.http
            .request(method, self.url(path))
            .basic_auth(USERNAME, Some(&self.address.password))
    }

    /// Sends a request and reads its JSON answer; fails on any status but 2xx.
    async fn call(&self, request: reqwest::RequestBuilder) -> io::Result<Value> {
        let response = request
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(io::Error::other)?;
        let status = response.status();
        let body = read_limited(response).await?;
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(io::Error::new(io::ErrorKind::NotFound, "OpenCode has no such thing"));
        }
        if !status.is_success() {
            return Err(io::Error::other(format!("OpenCode answered {status}")));
        }
        if body.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&body).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    pub async fn info(&self) -> io::Result<Value> {
        self.call(self.request(reqwest::Method::GET, "/api/info")).await
    }

    /// Creates a session in `directory` named `title`; its id.
    pub async fn create_session(&self, directory: &Path, title: &str) -> io::Result<String> {
        let answer = self
            .call(self.request(reqwest::Method::POST, "/api/session").json(&json!({
                "title": title,
                "location": { "directory": directory },
            })))
            .await?;
        session_id(&answer["data"]["id"])
            .map(str::to_owned)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "OpenCode named no session"))
    }

    pub async fn session(&self, id: &str) -> io::Result<Value> {
        let answer = self
            .call(self.request(reqwest::Method::GET, &format!("/api/session/{}", segment(id)?)))
            .await?;
        Ok(answer["data"].clone())
    }

    /// Whether the session is running an execution now.
    pub async fn is_active(&self, id: &str) -> io::Result<bool> {
        let answer = self.call(self.request(reqwest::Method::GET, "/api/session/active")).await?;
        Ok(answer["data"].get(id).is_some())
    }

    pub async fn prompt(&self, id: &str, text: &str, delivery: Option<&str>) -> io::Result<Value> {
        let mut body = json!({ "text": text });
        if let Some(delivery) = delivery {
            body["delivery"] = json!(delivery);
        }
        self.call(
            self.request(reqwest::Method::POST, &format!("/api/session/{}/prompt", segment(id)?))
                .json(&body),
        )
        .await
    }

    /// Whether an execution was running and is now interrupted.
    pub async fn interrupt(&self, id: &str) -> io::Result<bool> {
        let answer = self
            .call(self.request(
                reqwest::Method::POST,
                &format!("/api/session/{}/interrupt", segment(id)?),
            ))
            .await?;
        Ok(answer["interrupted"] == true)
    }

    pub async fn select_model(&self, id: &str, provider: &str, model: &str) -> io::Result<()> {
        self.call(
            self.request(reqwest::Method::POST, &format!("/api/session/{}/model", segment(id)?))
                .json(&json!({ "model": { "id": model, "providerID": provider } })),
        )
        .await
        .map(drop)
    }

    pub async fn models(&self, directory: &Path) -> io::Result<Value> {
        self.call(
            self.request(reqwest::Method::GET, "/api/model")
                .query(&[("location[directory]", directory.to_string_lossy().as_ref())]),
        )
        .await
    }

    /// The session's messages as `opencode session export` writes them (`{info, messages}`).
    pub async fn export(&self, id: &str) -> io::Result<Value> {
        let answer = self
            .call(self.request(
                reqwest::Method::GET,
                &format!("/api/experimental/session/{}/export", segment(id)?),
            ))
            .await?;
        Ok(answer["data"].clone())
    }

    /// Subscribes to every event the server publishes, from now on.
    pub async fn events(&self) -> io::Result<EventBytes> {
        let response = self
            .request(reqwest::Method::GET, "/api/event")
            .header("accept", "text/event-stream")
            .send()
            .await
            .map_err(io::Error::other)?;
        if !response.status().is_success() {
            return Err(io::Error::other(format!(
                "OpenCode answered {} to the event stream",
                response.status()
            )));
        }
        Ok(response
            .bytes_stream()
            .map(|chunk| chunk.map(|bytes| bytes.to_vec()).map_err(io::Error::other))
            .boxed())
    }
}

/// An OpenCode session id: `ses_` and URL-safe characters only, so it goes in a path as is.
pub fn session_id(value: &Value) -> Option<&str> {
    value.as_str().filter(|id| is_session_id(id))
}

pub fn is_session_id(id: &str) -> bool {
    id.starts_with("ses")
        && id.len() <= 128
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

fn segment(id: &str) -> io::Result<&str> {
    if is_session_id(id) {
        Ok(id)
    } else {
        Err(io::Error::new(io::ErrorKind::InvalidInput, "not an OpenCode session id"))
    }
}

async fn read_limited(response: reqwest::Response) -> io::Result<Vec<u8>> {
    let mut body = Vec::new();
    let mut chunks = response.bytes_stream();
    while let Some(chunk) = chunks.next().await {
        let chunk = chunk.map_err(io::Error::other)?;
        if body.len() + chunk.len() > MAX_ANSWER_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "OpenCode's answer is too large"));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_loopback_url_is_taken_from_the_listening_line() {
        let parse = |line: &str| ServerAddress::from_listening_line(line, "pw".into()).map(|a| a.url);
        assert_eq!(parse("server listening on http://127.0.0.1:4096\n"), Some("http://127.0.0.1:4096".into()));
        assert_eq!(parse("server listening on http://localhost:51234/"), Some("http://localhost:51234".into()));
        assert_eq!(parse("server listening on http://10.0.0.2:4096"), None);
        assert_eq!(parse("server listening on https://127.0.0.1:4096"), None);
        assert_eq!(parse("server listening on http://127.0.0.1:0"), None);
        assert_eq!(parse("listening on http://127.0.0.1:4096"), None);
    }

    #[test]
    fn session_ids_are_checked_before_they_go_in_a_path() {
        assert!(is_session_id("ses_e73a7ea43ffepr6zTFga6PRFtL"));
        assert!(!is_session_id("ses_../../api"));
        assert!(!is_session_id("msg_1"));
        assert!(!is_session_id(&format!("ses_{}", "a".repeat(200))));
    }

    #[test]
    fn the_password_is_not_debug_printed() {
        let address = ServerAddress { url: "http://127.0.0.1:1".into(), password: "secret".into() };
        assert!(!format!("{address:?}").contains("secret"));
    }
}
