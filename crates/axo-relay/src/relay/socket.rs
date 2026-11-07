//! The relay's WebSocket transport: connecting with the host credential, refusing redirects,
//! and reading and sending whole JSON messages, fragmented when large (RFD0016, Transport).

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tungstenite::Message;
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::protocol::WebSocketConfig;

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::fragments::{self, Reassembler};
use crate::link::AccountLink;

pub(crate) const MAX_FRAME_BYTES: usize = fragments::FRAME_BYTES;

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// A relay socket, on tokio: written through its sink half and read through its
/// stream half, so the loop can wait on reading while it writes.
pub(crate) type RelaySocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
pub(crate) type RelaySink = futures_util::stream::SplitSink<RelaySocket, Message>;
pub(crate) type RelayStream = futures_util::stream::SplitStream<RelaySocket>;

/// The account-scoped daemon WebSocket, authenticated with the host credential.
pub(super) fn relay_websocket_request(
    endpoint: &RelayEndpoint,
    account: &AccountLink,
    host_id: &str,
    credentials: &dyn HostCredentialStore,
) -> io::Result<tungstenite::http::Request<()>> {
    host_websocket_request(
        endpoint.daemon_url(account.account_id(), host_id),
        account,
        credentials,
    )
}

/// A WebSocket request to one of the host's account routes, authenticated with its credential.
pub(crate) fn host_websocket_request(
    url: url::Url,
    account: &AccountLink,
    credentials: &dyn HostCredentialStore,
) -> io::Result<tungstenite::http::Request<()>> {
    let mut secret = credentials.load(account.credential_id())?;
    if secret.len() != 32 {
        secret.fill(0);
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "stored host credential is invalid",
        ));
    }
    let token = crate::pairing::encode_base64url(&secret);
    secret.fill(0);
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(io::Error::other)?;
    let headers = request.headers_mut();
    headers.insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {token}")).map_err(io::Error::other)?,
    );
    headers.insert(
        "X-Axo-Credential-Id",
        HeaderValue::from_str(account.credential_id()).map_err(io::Error::other)?,
    );
    Ok(request)
}

/// The host and port a relay URL names.
fn address_of(uri: &tungstenite::http::Uri) -> io::Result<(String, u16)> {
    let host = uri
        .host()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "relay URL has no host"))?;
    let host = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(host);
    let port = uri
        .port_u16()
        .unwrap_or(if uri.scheme_str() == Some("wss") {
            443
        } else {
            80
        });
    Ok((host.to_owned(), port))
}

/// One connection attempt. The daemon route authenticates with the host credential and never
/// redirects; a redirect means something in front of it (usually a Cloudflare Access login)
/// is intercepting the route, which is reported instead of followed.
pub(crate) async fn connect_websocket(
    request: tungstenite::http::Request<()>,
    config: WebSocketConfig,
) -> io::Result<RelaySocket> {
    let timed_out = || io::Error::new(io::ErrorKind::TimedOut, "relay connection timed out");
    let (host, port) = address_of(request.uri())?;
    let stream = tokio::time::timeout(
        CONNECT_TIMEOUT,
        tokio::net::TcpStream::connect((host.as_str(), port)),
    )
    .await
    .map_err(|_| timed_out())??;
    stream.set_nodelay(true)?;
    let handshake =
        tokio_tungstenite::client_async_tls_with_config(request, stream, Some(config), None);
    match tokio::time::timeout(CONNECT_TIMEOUT, handshake).await {
        Err(_) => Err(timed_out()),
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(tungstenite::Error::Http(response))) if response.status().is_redirection() => {
            Err(io::Error::other(format!(
                "relay redirected the host connection (HTTP {}); the daemon route must not be behind a login",
                response.status().as_u16()
            )))
        }
        Ok(Err(error)) => Err(io::Error::other(error)),
    }
}

/// One whole message: a frame, or the last fragment's frame completing a larger message; `None`
/// for a control frame or a fragment that completes nothing yet. A fragment that breaks the rules
/// ends the connection. A ping's pong goes out through `sink`.
pub(crate) async fn receive(
    sink: &mut RelaySink,
    message: Option<Result<Message, tungstenite::Error>>,
    reassembler: &mut Reassembler,
) -> io::Result<Option<String>> {
    use futures_util::SinkExt;
    match message {
        Some(Ok(Message::Text(text))) => receive_text(text.to_string(), reassembler),
        Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {
            sink.flush().await.map_err(io::Error::other)?;
            Ok(None)
        }
        None | Some(Ok(Message::Close(_))) => Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "relay connection closed",
        )),
        Some(Ok(Message::Binary(_))) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "relay sent a binary frame",
        )),
        Some(Ok(Message::Frame(_))) => Ok(None),
        Some(Err(error)) => Err(io::Error::other(error)),
    }
}

/// Sends one message: in one frame, or as fragments when it is larger (RFD0016, Transport).
pub(crate) async fn send_json(sink: &mut RelaySink, value: &impl Serialize) -> io::Result<()> {
    use futures_util::SinkExt;
    for frame in frames(value)? {
        sink.send(Message::Text(frame.into()))
            .await
            .map_err(io::Error::other)?;
    }
    Ok(())
}

/// A text frame as a whole message, after reassembly when it is a fragment.
fn receive_text(raw: String, reassembler: &mut Reassembler) -> io::Result<Option<String>> {
    if !raw.contains(fragments::FRAGMENT_METHOD) && !raw.contains(fragments::DISCARD_METHOD) {
        return Ok(Some(raw));
    }
    let value: Value = serde_json::from_str(&raw)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
    if value.get("method").and_then(Value::as_str) == Some(fragments::DISCARD_METHOD) {
        reassembler.receive_discard(&value["params"]).map_err(
            |fragments::InvalidFragment(reason)| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("relay sent an invalid discard: {reason}"),
                )
            },
        )?;
        return Ok(None);
    }
    let Some(params) = fragments::fragment_params(&value) else {
        return Ok(Some(raw));
    };
    reassembler
        .receive(params)
        .map_err(|fragments::InvalidFragment(reason)| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("relay sent an invalid fragment: {reason}"),
            )
        })
}

/// One message's frames: itself, or its fragments when it is larger than a frame.
fn frames(value: &impl Serialize) -> io::Result<Vec<String>> {
    static MESSAGES: AtomicU64 = AtomicU64::new(0);
    let text = serde_json::to_string(value).map_err(io::Error::other)?;
    let message_id = format!(
        "axod-{}-{}",
        std::process::id(),
        MESSAGES.fetch_add(1, Ordering::Relaxed)
    );
    fragments::split(&text, &message_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "relay message exceeds the largest message the relay reassembles",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::time::Instant;
    use std::thread;

    fn accept_with_timeout(listener: &TcpListener) -> TcpStream {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    // Darwin can inherit O_NONBLOCK from the listener; a read
                    // timeout alone does not turn the accepted socket blocking.
                    stream.set_nonblocking(false).unwrap();
                    return stream;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "timed out waiting for redirected request"
                    );
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("could not accept WebSocket request: {error}"),
            }
        }
    }

    fn read_http_request(stream: &mut TcpStream) -> String {
        let mut request = Vec::new();
        let mut byte = [0_u8; 1];
        while !request.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
            assert!(
                request.len() <= 16 * 1024,
                "WebSocket request headers exceeded the test limit"
            );
        }
        String::from_utf8(request).unwrap()
    }

    #[test]
    fn a_redirected_host_connection_is_reported_not_followed() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let mut initial = accept_with_timeout(&listener);
            initial
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            assert!(read_http_request(&mut initial).starts_with("GET /daemon HTTP/1.1\r\n"));
            initial
                .write_all(
                    b"HTTP/1.1 302 Found\r\nLocation: /cdn-cgi/access/login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
            drop(initial);
            thread::sleep(Duration::from_millis(200));
            assert!(
                listener.accept().is_err(),
                "the redirect must not be followed"
            );
        });

        let request = format!("ws://{address}/daemon")
            .into_client_request()
            .unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let connecting = connect_websocket(request, WebSocketConfig::default());
        let error = match runtime.block_on(connecting) {
            Ok(_) => panic!("a redirect must not be accepted as a relay"),
            Err(error) => error,
        };
        assert!(
            error
                .to_string()
                .contains("relay redirected the host connection (HTTP 302)")
        );
        server.join().unwrap();
    }

    #[test]
    fn linked_hosts_connect_to_their_account_route_with_their_credential() {
        let account_id = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
        let host_id = "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe";
        let credential_id = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        crate::credential::HostCredentialStore::store(&credentials, credential_id, &[0xff; 32])
            .unwrap();
        let account = AccountLink::parse(account_id.to_owned(), credential_id.to_owned()).unwrap();

        let request = relay_websocket_request(
            &RelayEndpoint::production(),
            &account,
            host_id,
            &credentials,
        )
        .unwrap();

        assert_eq!(request.uri().scheme_str(), Some("wss"));
        assert_eq!(
            request.uri().path(),
            format!("/api/v1/accounts/{account_id}/hosts/{host_id}/daemon")
        );
        assert_eq!(request.headers()["X-Axo-Credential-Id"], credential_id);
        let authorization = request.headers()["Authorization"].to_str().unwrap();
        assert!(authorization.starts_with("Bearer "));
        assert_eq!(authorization.len(), "Bearer ".len() + 43);
        assert!(request.headers().get("origin").is_none());
        assert!(request.headers().get("Cf-Access-Jwt-Assertion").is_none());

        crate::credential::HostCredentialStore::store(&credentials, credential_id, &[0xff; 16])
            .unwrap();
        assert!(
            relay_websocket_request(
                &RelayEndpoint::production(),
                &account,
                host_id,
                &credentials,
            )
            .is_err(),
            "a credential of the wrong size is never sent"
        );
    }
}
