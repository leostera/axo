//! Loopback sign-in (RFD0016): some services only send a sign-in back to `http://localhost`, so
//! the sign-in has to end on the person's Mac. This listens on one of the redirect ports the
//! service has registered, opens the service's sign-in page in the person's browser, and waits
//! for the browser to come back with the code.
//!
//! It knows nothing about any one service. The caller (the Worker, through the relay) builds the
//! sign-in URL and keeps the PKCE verifier, so what comes back here, a one-time code, is of no
//! use to anyone without it. Nothing is written to disk and nothing secret is logged.

use std::fmt;
use std::future::Future;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// The longest a sign-in may wait for the person.
pub const MAX_TIMEOUT: Duration = Duration::from_secs(600);
/// A request line and headers longer than this are not a browser coming back.
const MAX_REQUEST_BYTES: usize = 16 * 1024;
/// How long one connection may take to send its request; a browser's idle preconnect must not
/// hold up the real redirect.
const READ_TIMEOUT: Duration = Duration::from_secs(5);
/// Apps answered in one sign-in; past this many, more are dropped.
const MAX_APPS: usize = 64;

/// One sign-in: where to send the person, and where they come back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignIn {
    /// The service's sign-in page, with every parameter but `redirect_uri`, which is added here
    /// once a port is free.
    pub authorize_url: String,
    /// The redirect ports the service registered, tried in order.
    pub ports: Vec<u16>,
    /// The redirect's path, such as `/callback`.
    pub path: String,
    /// The `state` the sign-in URL carries; a callback with any other is not this sign-in's.
    pub state: String,
    pub timeout: Duration,
}

/// What the browser came back with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Callback {
    /// The redirect URI the code was issued for; the token request must send the same.
    pub redirect_uri: String,
    pub code: Option<String>,
    /// The service's `error` and `error_description` when the person declined, or it failed.
    pub error: Option<String>,
    pub error_description: Option<String>,
}

#[derive(Debug)]
pub enum SignInError {
    /// Every registered port is taken, by another sign-in or another program.
    NoFreePort(Vec<u16>),
    /// The browser could not be opened.
    Open(io::Error),
    /// The person did not finish in time.
    TimedOut,
    Io(io::Error),
}

impl fmt::Display for SignInError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoFreePort(ports) => {
                let ports: Vec<String> = ports.iter().map(u16::to_string).collect();
                write!(
                    f,
                    "ports {} are all in use on this Mac; close the other sign-in and try again",
                    ports.join(", ")
                )
            }
            Self::Open(error) => write!(f, "could not open the browser: {error}"),
            Self::TimedOut => f.write_str("the sign-in was not finished in time"),
            Self::Io(error) => write!(f, "the sign-in's local server failed: {error}"),
        }
    }
}

impl std::error::Error for SignInError {}

/// Runs one sign-in: listens, opens `authorize_url` plus `redirect_uri` with `open_browser`, and
/// returns the first callback on `path` that carries `state`. Anything else is answered and
/// ignored, so a stray request cannot end the sign-in.
pub async fn sign_in<F: Future<Output = io::Result<()>>>(
    request: &SignIn,
    open_browser: impl FnOnce(String) -> F,
) -> Result<Callback, SignInError> {
    let listeners = listen(&request.ports).await?;
    let redirect_uri = format!("http://localhost:{}{}", listeners.port, request.path);
    let separator = if request.authorize_url.contains('?') {
        '&'
    } else {
        '?'
    };
    let url = format!(
        "{}{separator}redirect_uri={}",
        request.authorize_url,
        percent_encode(&redirect_uri)
    );
    let waiting = async {
        open_browser(url).await.map_err(SignInError::Open)?;
        // A browser's idle preconnect must not hold up the real redirect. This set owns every
        // connection task: a callback, timeout or cancelled sign-in drops and aborts them all.
        let mut serving = tokio::task::JoinSet::new();
        let mut accepted = 0;
        loop {
            tokio::select! {
                completed = serving.join_next(), if !serving.is_empty() => {
                    if let Some(Ok(Some(callback))) = completed {
                        return Ok(callback);
                    }
                }
                incoming = listeners.accept() => {
                    match incoming {
                        Ok(stream) => {
                            if accepted >= MAX_APPS { continue; }
                            accepted += 1;
                            let request = request.clone();
                            let redirect_uri = redirect_uri.clone();
                            serving.spawn(async move {
                                tokio::time::timeout(READ_TIMEOUT, serve(stream, &request, &redirect_uri))
                                    .await.ok().flatten()
                            });
                        }
                        Err(error) if matches!(error.kind(), io::ErrorKind::Interrupted | io::ErrorKind::ConnectionAborted) => {}
                        Err(error) => return Err(SignInError::Io(error)),
                    }
                }
            }
        }
    };
    tokio::time::timeout(request.timeout.min(MAX_TIMEOUT), waiting)
        .await
        .map_err(|_| SignInError::TimedOut)?
}

/// One redirect port, on both loopback families when IPv6 is available.
struct Listeners {
    v4: TcpListener,
    v6: Option<TcpListener>,
    port: u16,
}

impl Listeners {
    async fn accept(&self) -> io::Result<TcpStream> {
        let v6 = async {
            match &self.v6 {
                Some(listener) => listener.accept().await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            result = self.v4.accept() => result.map(|(stream, _)| stream),
            result = v6 => result.map(|(stream, _)| stream),
        }
    }
}

async fn listen(ports: &[u16]) -> Result<Listeners, SignInError> {
    for &port in ports {
        let Ok(v4) = TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await else {
            continue;
        };
        let port = v4.local_addr().map_err(SignInError::Io)?.port();
        let v6 = TcpListener::bind((Ipv6Addr::LOCALHOST, port)).await.ok();
        return Ok(Listeners { v4, v6, port });
    }
    Err(SignInError::NoFreePort(ports.to_vec()))
}

/// Answers one connection. `Some` when it is this sign-in's callback.
async fn serve(mut stream: TcpStream, request: &SignIn, redirect_uri: &str) -> Option<Callback> {
    let target = read_target(&mut stream).await?;
    let (path, query) = target.split_once('?').unwrap_or((target.as_str(), ""));
    if path != request.path {
        respond(&mut stream, "404 Not Found", "Not found.").await;
        return None;
    }
    let params = parse_query(query);
    let value = |name: &str| {
        params
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
    };
    if value("state").as_deref() != Some(request.state.as_str()) {
        respond(
            &mut stream,
            "400 Bad Request",
            "This is not the sign-in Axo started. Go back to Axo and start again.",
        )
        .await;
        return None;
    }
    let callback = Callback {
        redirect_uri: redirect_uri.to_owned(),
        code: value("code"),
        error: value("error"),
        error_description: value("error_description"),
    };
    if callback.code.is_some() {
        respond(
            &mut stream,
            "200 OK",
            "Signed in. You can close this tab and go back to Axo.",
        )
        .await;
    } else {
        respond(
            &mut stream,
            "200 OK",
            "The sign-in did not finish. You can close this tab; Axo says what happened.",
        )
        .await;
    }
    Some(callback)
}

/// The request target of a `GET`, from the request line.
async fn read_target(stream: &mut TcpStream) -> Option<String> {
    let mut buffer = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    while !buffer.windows(4).any(|w| w == b"\r\n\r\n") {
        let read = stream.read(&mut chunk).await.ok()?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.len() > MAX_REQUEST_BYTES {
            return None;
        }
    }
    let text = String::from_utf8_lossy(&buffer);
    let line = text.lines().next()?;
    let mut parts = line.split(' ');
    if parts.next()? != "GET" {
        return None;
    }
    parts.next().map(str::to_owned)
}

async fn respond(stream: &mut TcpStream, status: &str, message: &str) {
    let body = format!(
        "<!doctype html><meta charset=utf-8><title>Axo</title>\
         <body style=\"font:16px -apple-system,system-ui,sans-serif;margin:4rem auto;max-width:32rem\">\
         <p>{}</p></body>",
        escape_html(message)
    );
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// `application/x-www-form-urlencoded` pairs, decoded.
fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            (percent_decode(key), percent_decode(value))
        })
        .collect()
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => match std::str::from_utf8(&bytes[i + 1..i + 3])
                .ok()
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
            {
                Some(byte) => {
                    out.push(byte);
                    i += 2;
                }
                None => out.push(b'%'),
            },
            byte => out.push(byte),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Percent-encodes everything but RFC 3986's unreserved characters.
pub fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 3);
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Opens a URL in the person's default browser, as one argument: no shell parses it.
pub async fn open_in_browser(url: String) -> io::Result<()> {
    let status = tokio::process::Command::new("/usr/bin/open")
        .arg(url)
        .kill_on_drop(true)
        .status()
        .await?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("open exited with {status}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::mpsc;

    fn block<F: Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(future)
    }

    fn request(ports: Vec<u16>) -> SignIn {
        SignIn {
            authorize_url: "https://example.com/oauth/authorize?client_id=c&state=s3cr3t-state"
                .into(),
            ports,
            path: "/callback".into(),
            state: "s3cr3t-state".into(),
            timeout: Duration::from_secs(10),
        }
    }

    fn free_port() -> u16 {
        TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .unwrap()
            .local_addr()
            .unwrap()
            .port()
    }

    fn get(port: u16, target: &str) -> String {
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        write!(stream, "GET {target} HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).unwrap();
        answer
    }

    /// Runs a sign-in on a thread; the "browser" is told the URL it would open.
    fn start(
        request: SignIn,
    ) -> (
        mpsc::Receiver<String>,
        std::thread::JoinHandle<Result<Callback, SignInError>>,
    ) {
        let (tx, rx) = mpsc::channel();
        let handle = std::thread::spawn(move || {
            block(sign_in(&request, move |url| async move {
                tx.send(url).map_err(io::Error::other)
            }))
        });
        (rx, handle)
    }

    #[test]
    fn the_browser_coming_back_with_the_state_gives_the_code_and_the_redirect_uri() {
        let port = free_port();
        let (opened, handle) = start(request(vec![port]));
        let url = opened.recv().unwrap();
        let redirect = format!("http://localhost:{port}/callback");
        assert_eq!(
            url,
            format!(
                "https://example.com/oauth/authorize?client_id=c&state=s3cr3t-state&redirect_uri={}",
                percent_encode(&redirect)
            )
        );
        // A preconnect that says nothing, a stray path and a wrong state do not end it.
        let idle = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        assert!(get(port, "/favicon.ico").starts_with("HTTP/1.1 404"));
        assert!(get(port, "/callback?code=evil&state=other").starts_with("HTTP/1.1 400"));
        let answer = get(port, "/callback?code=a%2Fb+c&state=s3cr3t-state");
        assert!(
            answer.starts_with("HTTP/1.1 200") && answer.contains("Signed in"),
            "{answer}"
        );
        drop(idle);
        let callback = handle.join().unwrap().unwrap();
        assert_eq!(
            callback,
            Callback {
                redirect_uri: redirect,
                code: Some("a/b c".into()),
                error: None,
                error_description: None
            }
        );
    }

    #[test]
    fn a_declined_sign_in_comes_back_with_the_services_error() {
        let port = free_port();
        let (opened, handle) = start(request(vec![port]));
        opened.recv().unwrap();
        get(
            port,
            "/callback?error=access_denied&error_description=The+user+declined&state=s3cr3t-state",
        );
        let callback = handle.join().unwrap().unwrap();
        assert_eq!(callback.code, None);
        assert_eq!(callback.error.as_deref(), Some("access_denied"));
        assert_eq!(
            callback.error_description.as_deref(),
            Some("The user declined")
        );
    }

    #[test]
    fn a_taken_port_moves_on_to_the_next_and_all_taken_is_refused() {
        let taken = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let busy = taken.local_addr().unwrap().port();
        let free = free_port();
        let (opened, handle) = start(request(vec![busy, free]));
        assert!(opened.recv().unwrap().contains(&percent_encode(&format!(
            "http://localhost:{free}/callback"
        ))));
        get(free, "/callback?code=x&state=s3cr3t-state");
        assert_eq!(handle.join().unwrap().unwrap().code.as_deref(), Some("x"));
        let refused = block(sign_in(&request(vec![busy]), |_| async { Ok(()) })).unwrap_err();
        assert!(matches!(refused, SignInError::NoFreePort(_)), "{refused}");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancelling_sign_in_releases_the_port_and_its_idle_connections() {
        let port = free_port();
        let request = request(vec![port]);
        let (opened, ready) = tokio::sync::oneshot::channel();
        let signing_in = tokio::spawn(async move {
            sign_in(&request, move |_| async move {
                opened.send(()).unwrap();
                Ok(())
            })
            .await
        });
        ready.await.unwrap();
        let mut idle = tokio::net::TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        tokio::task::yield_now().await;
        signing_in.abort();
        assert!(signing_in.await.unwrap_err().is_cancelled());
        let _rebound = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        let mut byte = [0];
        let ended = tokio::time::timeout(
            Duration::from_secs(1),
            tokio::io::AsyncReadExt::read(&mut idle, &mut byte),
        )
        .await
        .unwrap();
        assert!(
            matches!(ended, Ok(0) | Err(_)),
            "an idle callback survived cancellation"
        );
    }

    #[test]
    fn nobody_coming_back_times_out() {
        let mut slow = request(vec![free_port()]);
        slow.timeout = Duration::from_millis(200);
        assert!(matches!(
            block(sign_in(&slow, |_| async { Ok(()) })),
            Err(SignInError::TimedOut)
        ));
    }
}
