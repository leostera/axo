use crate::credential::HostCredentialStore;
use httparse::{EMPTY_HEADER, Response};
use native_tls::TlsConnector;
use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;
use url::Url;

const CODE_ALPHABET: &str = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CREDENTIAL_BYTES: usize = 32;
const MAX_RESPONSE_BYTES: usize = 65_536;
const MAX_RESPONSE_HEADERS: usize = 64;
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

pub struct PairingResult {
    pub account_id: String,
    pub credential_id: String,
}

pub struct RedemptionRequest<'a> {
    pub relay_url: &'a Url,
    pub code: &'a str,
    pub host_id: &'a str,
    pub host_generation: &'a str,
    pub credential_id: &'a str,
    pub label: &'a str,
    pub host_kind: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RedeemRequest<'a> {
    code: &'a str,
    host_id: &'a str,
    host_generation: &'a str,
    credential_id: &'a str,
    credential: String,
    label: &'a str,
    host_kind: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RedeemResponse {
    linked: bool,
    account_id: String,
    host_id: String,
    host_generation: String,
    credential_id: String,
    linked_at: String,
}

struct PairingCode(String);

struct HttpResponse {
    status: u16,
    body: Vec<u8>,
}

impl PairingCode {
    fn parse(raw: &str) -> io::Result<Self> {
        let raw = raw.trim();
        if raw.len() != 9 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "pairing code is invalid",
            ));
        }
        let normalized = raw.to_ascii_uppercase();
        let bytes = normalized.as_bytes();
        if bytes[4] != b'-'
            || !bytes[..4]
                .iter()
                .chain(&bytes[5..])
                .all(|byte| CODE_ALPHABET.as_bytes().contains(byte))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "pairing code is invalid",
            ));
        }
        Ok(Self(normalized))
    }
}

pub fn validate_code(raw: &str) -> io::Result<()> {
    PairingCode::parse(raw).map(|_| ())
}

/// Creates a fresh host credential and stores it before any network request.
pub fn prepare_credential(credentials: &dyn HostCredentialStore) -> io::Result<String> {
    let credential_id = create_uuid_v4()?;
    let mut secret = [0_u8; CREDENTIAL_BYTES];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut secret)?;
    let result = credentials.store(&credential_id, &secret);
    secret.fill(0);
    result?;
    Ok(credential_id)
}

/// Redeems a one-time code using the Keychain credential reserved for this attempt.
pub fn redeem(
    request: RedemptionRequest<'_>,
    credentials: &dyn HostCredentialStore,
) -> io::Result<PairingResult> {
    let code = PairingCode::parse(request.code)?;
    if !is_uuid(request.host_id) || !is_uuid(request.host_generation) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "host identity is invalid",
        ));
    }
    if request.label.trim().is_empty()
        || request.label.len() > 128
        || request.label.chars().any(char::is_control)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "host label is invalid",
        ));
    }
    if !valid_host_kind(request.host_kind) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "host kind is invalid",
        ));
    }

    if !is_uuid(request.credential_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "host credential identifier is invalid",
        ));
    }
    let mut secret = credentials.load(request.credential_id)?;
    if secret.len() != CREDENTIAL_BYTES {
        secret.fill(0);
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "stored host credential is invalid",
        ));
    }

    let payload = RedeemRequest {
        code: &code.0,
        host_id: request.host_id,
        host_generation: request.host_generation,
        credential_id: request.credential_id,
        credential: encode_base64url(&secret),
        label: request.label,
        host_kind: request.host_kind,
    };
    secret.fill(0);

    (|| {
        let body = serde_json::to_vec(&payload)
            .map_err(|_| io::Error::other("could not encode pairing request"))?;
        let endpoint = redemption_url(request.relay_url)?;
        let response = match post_json(&endpoint, &body) {
            Ok(response) => response,
            Err(first_error) => match post_json(&endpoint, &body) {
                Ok(response) => response,
                Err(_) => return Err(first_error),
            },
        };
        if response.status != 200 {
            return Err(io::Error::other(format!(
                "pairing service returned HTTP {}",
                response.status
            )));
        }
        let response: RedeemResponse = serde_json::from_slice(&response.body).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing service returned an invalid response",
            )
        })?;
        if !response.linked
            || !is_uuid(&response.account_id)
            || response.host_id != request.host_id
            || response.host_generation != request.host_generation
            || response.credential_id != request.credential_id
            || !is_rfc3339_timestamp(&response.linked_at)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing service did not confirm this host",
            ));
        }
        Ok(PairingResult {
            account_id: response.account_id,
            credential_id: request.credential_id.to_owned(),
        })
    })()
}

fn redemption_url(relay_url: &Url) -> io::Result<Url> {
    if relay_url.scheme() != "wss" {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "host pairing requires a secure relay endpoint",
        ));
    }
    let mut endpoint = relay_url.clone();
    endpoint
        .set_scheme("https")
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "pairing endpoint is invalid"))?;
    endpoint.set_path("/api/v1/host-pairings/redeem");
    endpoint.set_query(None);
    endpoint.set_fragment(None);
    Ok(endpoint)
}

fn post_json(endpoint: &Url, body: &[u8]) -> io::Result<HttpResponse> {
    let host = endpoint.host_str().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "pairing endpoint has no host")
    })?;
    let port = endpoint.port_or_known_default().unwrap_or(443);
    let address = (host, port).to_socket_addrs()?.next().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            "pairing endpoint has no address",
        )
    })?;
    let stream = TcpStream::connect_timeout(&address, HTTP_TIMEOUT)?;
    stream.set_read_timeout(Some(HTTP_TIMEOUT))?;
    stream.set_write_timeout(Some(HTTP_TIMEOUT))?;
    let mut stream = TlsConnector::new()
        .map_err(|_| io::Error::other("could not initialize TLS for host pairing"))?
        .connect(host, stream)
        .map_err(|_| {
            io::Error::other("could not establish a secure connection for host pairing")
        })?;

    let mut request_target = endpoint.path().to_owned();
    if request_target.is_empty() {
        request_target.push('/');
    }
    if let Some(query) = endpoint.query() {
        request_target.push('?');
        request_target.push_str(query);
    }
    let host_header = if port == 443 {
        host.to_owned()
    } else {
        format!("{host}:{port}")
    };
    write!(
        stream,
        "POST {request_target} HTTP/1.1\r\nHost: {host_header}\r\nContent-Type: application/json\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)?;
    stream.flush()?;

    let mut raw_response = Vec::new();
    stream
        .take((MAX_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut raw_response)?;
    if raw_response.len() > MAX_RESPONSE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "pairing response exceeded its size limit",
        ));
    }
    parse_http_response(&raw_response)
}

fn parse_http_response(raw: &[u8]) -> io::Result<HttpResponse> {
    let mut headers = [EMPTY_HEADER; MAX_RESPONSE_HEADERS];
    let mut response = Response::new(&mut headers);
    let header_length = match response.parse(raw).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "pairing service returned malformed HTTP",
        )
    })? {
        httparse::Status::Complete(length) => length,
        httparse::Status::Partial => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing service returned incomplete HTTP",
            ));
        }
    };
    let status = response.code.unwrap_or_default();
    let content_length = response
        .headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case("content-length"))
        .map(|header| {
            std::str::from_utf8(header.value)
                .ok()
                .and_then(|value| value.parse::<usize>().ok())
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "pairing response length is invalid",
                    )
                })
        })
        .transpose()?;
    let chunked = response.headers.iter().any(|header| {
        header.name.eq_ignore_ascii_case("transfer-encoding")
            && header.value.eq_ignore_ascii_case(b"chunked")
    });
    let body = &raw[header_length..];
    let body = if chunked {
        decode_chunked_body(body)?
    } else if let Some(length) = content_length {
        if length > MAX_RESPONSE_BYTES || body.len() != length {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing response body is incomplete",
            ));
        }
        body.to_vec()
    } else {
        body.to_vec()
    };
    Ok(HttpResponse { status, body })
}

fn decode_chunked_body(mut input: &[u8]) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    loop {
        let line_end = input
            .windows(2)
            .position(|window| window == b"\r\n")
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "pairing response chunk is malformed",
                )
            })?;
        let size_text = std::str::from_utf8(&input[..line_end]).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing response chunk is malformed",
            )
        })?;
        let size_text = size_text.split(';').next().unwrap_or_default();
        let size = usize::from_str_radix(size_text, 16).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing response chunk size is invalid",
            )
        })?;
        input = &input[line_end + 2..];
        if size == 0 {
            return Ok(output);
        }
        if output.len().saturating_add(size) > MAX_RESPONSE_BYTES
            || input.len() < size.saturating_add(2)
            || &input[size..size + 2] != b"\r\n"
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pairing response chunk exceeded its bounds",
            ));
        }
        output.extend_from_slice(&input[..size]);
        input = &input[size + 2..];
    }
}

fn create_uuid_v4() -> io::Result<String> {
    let mut bytes = [0_u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    ))
}

pub fn encode_base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut encoded = String::with_capacity((bytes.len() * 4).div_ceil(3));
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        encoded.push(ALPHABET[(first >> 2) as usize] as char);
        encoded.push(ALPHABET[(((first & 0x03) << 4) | (second >> 4)) as usize] as char);
        if chunk.len() > 1 {
            encoded.push(ALPHABET[(((second & 0x0f) << 2) | (third >> 6)) as usize] as char);
        }
        if chunk.len() > 2 {
            encoded.push(ALPHABET[(third & 0x3f) as usize] as char);
        }
    }
    encoded
}

fn valid_host_kind(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.as_bytes()[0].is_ascii_lowercase()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn is_rfc3339_timestamp(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 24
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[10] == b'T'
        && bytes[13] == b':'
        && bytes[16] == b':'
        && bytes[19] == b'.'
        && bytes[23] == b'Z'
        && bytes.iter().enumerate().all(|(index, byte)| {
            matches!(index, 4 | 7 | 10 | 13 | 16 | 19 | 23) || byte.is_ascii_digit()
        })
}

#[cfg(test)]
mod tests {
    use super::{
        CREDENTIAL_BYTES, PairingCode, decode_chunked_body, encode_base64url, parse_http_response,
        prepare_credential,
    };

    #[test]
    fn prepared_credentials_are_persisted_before_redemption() {
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        let credential_id = prepare_credential(&credentials).unwrap();
        let mut secret =
            crate::credential::HostCredentialStore::load(&credentials, &credential_id).unwrap();

        assert!(super::is_uuid(&credential_id));
        assert_eq!(secret.len(), CREDENTIAL_BYTES);
        secret.fill(0);
    }

    #[test]
    fn pairing_code_normalizes_and_rejects_non_crockford_characters() {
        assert_eq!(PairingCode::parse(" b26a-nrkt ").unwrap().0, "B26A-NRKT");
        assert!(PairingCode::parse("B26A-IRKT").is_err());
        assert!(PairingCode::parse("B26ANRKT").is_err());
        assert!(PairingCode::parse("B26A-NRKT-extra").is_err());
    }

    #[test]
    fn host_credential_encoding_is_unpadded_base64url() {
        let encoded = encode_base64url(&[0xff; CREDENTIAL_BYTES]);
        assert_eq!(encoded.len(), 43);
        assert!(
            encoded
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        );
    }

    #[test]
    fn http_response_parser_requires_success_and_supports_chunked_json() {
        assert_eq!(
            parse_http_response(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n{\"ok\":1}\r\n0\r\n\r\n").unwrap().body,
            b"{\"ok\":1}"
        );
        assert_eq!(
            parse_http_response(b"HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n")
                .unwrap()
                .status,
            302
        );
        assert!(decode_chunked_body(b"5\r\nno\r\n0\r\n\r\n").is_err());
    }
}
