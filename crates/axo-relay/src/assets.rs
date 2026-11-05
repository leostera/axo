//! Fetching a prompt's attachments (RFD0030) before the prompt reaches Pi, and uploading what
//! this Mac makes for the account (screenshots of computer use from another Mac, RFD0028).
//!
//! Each attachment is downloaded with this Mac's host credential from the account's cached read,
//! to `~/.axo/assets/<hex>/<name>`: written to a temporary file while its SHA-256 is computed,
//! and renamed into place only if the bytes match the name and the size. A prompt gets all its
//! attachments or none: the first that can't be fetched refuses the whole prompt.

use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axo_protocol::asset::{
    AssetHash, AssetName, AssetType, Attachment, Attachments, FetchedAttachment, MAX_ASSET_BYTES,
};
use httparse::{EMPTY_HEADER, Status};
use native_tls::TlsConnector;
use sha2::{Digest, Sha256};
use url::Url;

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::link::AccountLink;

/// How long one read may wait before the download is given up.
const READ_TIMEOUT: Duration = Duration::from_secs(30);
/// How long one attachment may take in all.
const FETCH_DEADLINE: Duration = Duration::from_secs(5 * 60);
const MAX_HEADER_BYTES: usize = 16 * 1024;

/// Where attachments come from and go to.
#[derive(Clone)]
pub struct AssetSource {
    pub endpoint: RelayEndpoint,
    pub account: AccountLink,
    pub host_id: String,
    pub credentials: Arc<dyn HostCredentialStore>,
    /// `~/.axo/assets`.
    pub directory: PathBuf,
}

/// Why an attachment could not be fetched; the prompt is refused with it.
#[derive(Debug)]
pub enum FetchError {
    /// The account has no such asset (deleted, or never uploaded).
    NotFound,
    /// The bytes didn't match the attachment's hash or size.
    Mismatch,
    /// The network, the disk or the credential failed.
    Failed(io::Error),
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => formatter.write_str("not found"),
            Self::Mismatch => formatter.write_str("mismatch"),
            Self::Failed(error) => write!(formatter, "failed: {error}"),
        }
    }
}

impl From<io::Error> for FetchError {
    fn from(error: io::Error) -> Self {
        Self::Failed(error)
    }
}

/// Fetches every attachment, or none: the first failure ends it.
pub fn fetch_all(
    source: &AssetSource,
    attachments: &Attachments,
) -> Result<Vec<FetchedAttachment>, FetchError> {
    attachments
        .iter()
        .map(|attachment| {
            let started = Instant::now();
            let outcome = fetch_one(source, attachment);
            log::info!(
                "event=assets.fetch hash={} bytes={} ms={} outcome={}",
                attachment.asset.hex(),
                attachment.size,
                started.elapsed().as_millis(),
                match &outcome {
                    Ok((_, true)) => "cached".to_owned(),
                    Ok((_, false)) => "fetched".to_owned(),
                    Err(error) => error.to_string(),
                }
            );
            outcome.map(|(fetched, _)| fetched)
        })
        .collect()
}

/// One attachment, and whether it was already on this Mac.
fn fetch_one(
    source: &AssetSource,
    attachment: &Attachment,
) -> Result<(FetchedAttachment, bool), FetchError> {
    let folder = source.directory.join(attachment.asset.hex());
    let path = folder.join(attachment.name.as_str());
    let fetched = FetchedAttachment {
        path: path.clone(),
        asset: attachment.asset,
        name: attachment.name.clone(),
        mime_type: attachment.mime_type,
        size: attachment.size,
    };
    // Only checked bytes are ever renamed into the folder, so a file there is the asset.
    if path.is_file() {
        return Ok((fetched, true));
    }
    fs::create_dir_all(&folder)?;
    if let Some(sibling) = existing_file(&folder)? {
        copy_into_place(&sibling, &path)?;
        return Ok((fetched, true));
    }
    let temporary = folder.join(format!(".download-{}", axo_protocol::new_uuid_v4()?));
    let result = download(source, attachment, &temporary);
    match result {
        Ok(()) => {
            fs::rename(&temporary, &path)?;
            Ok((fetched, false))
        }
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            Err(error)
        }
    }
}

/// A file already fetched under another name.
fn existing_file(folder: &Path) -> io::Result<Option<PathBuf>> {
    for entry in fs::read_dir(folder)? {
        let entry = entry?;
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(".download-")
            && entry.file_type()?.is_file()
        {
            return Ok(Some(entry.path()));
        }
    }
    Ok(None)
}

fn copy_into_place(from: &Path, to: &Path) -> io::Result<()> {
    let temporary = to.with_file_name(format!(".download-{}", axo_protocol::new_uuid_v4()?));
    fs::copy(from, &temporary)?;
    fs::rename(&temporary, to)
}

/// Downloads the asset to `temporary`, checking its size and hash as it goes.
fn download(
    source: &AssetSource,
    attachment: &Attachment,
    temporary: &Path,
) -> Result<(), FetchError> {
    let url = source.endpoint.asset_url(
        source.account.account_id(),
        &source.host_id,
        &attachment.asset.hex(),
    );
    let headers = authorization(source)?;
    let deadline = Instant::now() + FETCH_DEADLINE;
    let mut file = fs::File::create(temporary)?;
    let digest = get(&url, &headers, attachment.size, deadline, &mut file)?;
    file.sync_all()?;
    if digest != attachment.asset {
        return Err(FetchError::Mismatch);
    }
    Ok(())
}

/// This Mac's host credential as request headers.
fn authorization(source: &AssetSource) -> io::Result<String> {
    let mut secret = source.credentials.load(source.account.credential_id())?;
    if secret.len() != 32 {
        secret.fill(0);
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "stored host credential is invalid",
        ));
    }
    let token = crate::pairing::encode_base64url(&secret);
    secret.fill(0);
    Ok(format!(
        "Authorization: Bearer {token}\r\nX-Axo-Credential-Id: {}\r\n",
        source.account.credential_id()
    ))
}

/// Stores `bytes` in the account's assets with this Mac's credential, through the same route a
/// person's client uploads to, and keeps a copy where fetched attachments go. Answers the
/// attachment that names it, as an upload from the web or the phone does.
pub fn upload(
    source: &AssetSource,
    bytes: &[u8],
    name: AssetName,
    mime_type: AssetType,
) -> io::Result<Attachment> {
    if bytes.len() as u64 > MAX_ASSET_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "an asset is at most 100 MiB",
        ));
    }
    let digest: [u8; 32] = Sha256::digest(bytes).into();
    let asset = AssetHash::from_digest(digest);
    let url = source
        .endpoint
        .asset_url(source.account.account_id(), &source.host_id, &asset.hex());
    let headers = format!(
        "{}Content-Type: {}\r\nContent-Length: {}\r\nX-Axo-Asset-Name: {}\r\n",
        authorization(source)?,
        mime_type.as_str(),
        bytes.len(),
        percent_encode(name.as_str())
    );
    let started = Instant::now();
    let status = request(&url, "PUT", &headers, bytes, |stream| {
        Ok(read_head(&mut BufReader::new(stream))?.status)
    });
    log::info!(
        "event=assets.upload hash={} bytes={} ms={} outcome={}",
        asset.hex(),
        bytes.len(),
        started.elapsed().as_millis(),
        match &status {
            Ok(status) => status.to_string(),
            Err(error) => error.to_string(),
        }
    );
    match status? {
        200 | 201 => {}
        413 => return Err(io::Error::other("the account's assets are full")),
        status => {
            return Err(io::Error::other(format!(
                "the upload answered HTTP {status}"
            )));
        }
    }
    // A copy where a fetch would put it, so this Mac never downloads its own image again.
    let folder = source.directory.join(asset.hex());
    if fs::create_dir_all(&folder).is_ok() {
        let _ = fs::write(folder.join(name.as_str()), bytes);
    }
    Ok(Attachment {
        asset,
        name,
        mime_type,
        size: bytes.len() as u64,
    })
}

/// A header value as `encodeURIComponent` writes it, which the Worker decodes.
fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'!'
            | b'~'
            | b'*'
            | b'\''
            | b'('
            | b')' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// A stream to `url`'s host: TLS for https, plain for http (tests).
fn connect(url: &Url) -> io::Result<(Box<dyn ReadWrite>, String)> {
    let host = url
        .host_str()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "asset URL has no host"))?;
    let port = url.port_or_known_default().unwrap_or(443);
    let address = (host, port).to_socket_addrs()?.next().ok_or_else(|| {
        io::Error::new(io::ErrorKind::AddrNotAvailable, "asset URL has no address")
    })?;
    let stream = TcpStream::connect_timeout(&address, READ_TIMEOUT)?;
    stream.set_read_timeout(Some(READ_TIMEOUT))?;
    stream.set_write_timeout(Some(READ_TIMEOUT))?;
    let host_header = if port == 443 || port == 80 {
        host.to_owned()
    } else {
        format!("{host}:{port}")
    };
    if url.scheme() == "http" {
        return Ok((Box::new(stream), host_header));
    }
    let stream = TlsConnector::new()
        .map_err(|_| io::Error::other("could not initialize TLS"))?
        .connect(host, stream)
        .map_err(|_| io::Error::other("could not establish a secure connection"))?;
    Ok((Box::new(stream), host_header))
}

trait ReadWrite: Read + Write {}
impl<T: Read + Write> ReadWrite for T {}

/// Sends one request with `body` and hands the response stream to `answer`.
fn request<T>(
    url: &Url,
    method: &str,
    extra_headers: &str,
    body: &[u8],
    answer: impl FnOnce(&mut dyn ReadWrite) -> io::Result<T>,
) -> io::Result<T> {
    let (mut stream, host_header) = connect(url)?;
    write!(
        stream,
        "{method} {} HTTP/1.1\r\nHost: {host_header}\r\n{extra_headers}Accept-Encoding: identity\r\nConnection: close\r\n\r\n",
        url.path()
    )?;
    stream.write_all(body)?;
    stream.flush()?;
    answer(&mut *stream)
}

/// GETs `url`, streams at most `expected` bytes into `out`, and returns their hash. Fails with
/// `Mismatch` if the body is not exactly `expected` bytes.
fn get(
    url: &Url,
    extra_headers: &str,
    expected: u64,
    deadline: Instant,
    out: &mut impl Write,
) -> Result<axo_protocol::asset::AssetHash, FetchError> {
    request(url, "GET", extra_headers, &[], |stream| {
        Ok(receive(stream, expected, deadline, out))
    })?
}

/// Reads a GET's response: the body's bytes into `out`, checked against `expected`.
fn receive(
    stream: &mut dyn ReadWrite,
    expected: u64,
    deadline: Instant,
    out: &mut impl Write,
) -> Result<AssetHash, FetchError> {
    let mut reader = BufReader::new(stream);
    let head = read_head(&mut reader)?;
    if head.status == 404 {
        return Err(FetchError::NotFound);
    }
    if head.status != 200 {
        return Err(io::Error::other(format!("the asset answered HTTP {}", head.status)).into());
    }
    let mut body = Body {
        hasher: Sha256::new(),
        written: 0,
        expected,
        deadline,
        out,
    };
    if head.chunked {
        read_chunked(&mut reader, &mut body)?;
    } else if let Some(length) = head.length {
        if length != expected {
            return Err(FetchError::Mismatch);
        }
        copy_exact(&mut reader, length, &mut body)?;
    } else {
        copy_to_end(&mut reader, &mut body)?;
    }
    if body.written != expected {
        return Err(FetchError::Mismatch);
    }
    let digest: [u8; 32] = body.hasher.finalize().into();
    Ok(AssetHash::from_digest(digest))
}

struct Head {
    status: u16,
    length: Option<u64>,
    chunked: bool,
}

fn read_head(reader: &mut impl BufRead) -> io::Result<Head> {
    let mut raw = Vec::new();
    loop {
        let read = reader.read_until(b'\n', &mut raw)?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the asset response ended early",
            ));
        }
        if raw.len() > MAX_HEADER_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the asset response headers are too large",
            ));
        }
        if raw.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    let mut headers = [EMPTY_HEADER; 64];
    let mut response = httparse::Response::new(&mut headers);
    match response.parse(&raw) {
        Ok(Status::Complete(_)) => {}
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the asset response is malformed",
            ));
        }
    }
    let status = response.code.unwrap_or(0);
    let mut length = None;
    let mut chunked = false;
    for header in response.headers.iter() {
        if header.name.eq_ignore_ascii_case("content-length") {
            length = std::str::from_utf8(header.value)
                .ok()
                .and_then(|value| value.trim().parse().ok());
        } else if header.name.eq_ignore_ascii_case("transfer-encoding") {
            chunked = std::str::from_utf8(header.value)
                .is_ok_and(|value| value.to_ascii_lowercase().contains("chunked"));
        }
    }
    Ok(Head {
        status,
        length,
        chunked,
    })
}

struct Body<'a, W: Write> {
    hasher: Sha256,
    written: u64,
    expected: u64,
    deadline: Instant,
    out: &'a mut W,
}

impl<W: Write> Body<'_, W> {
    fn take(&mut self, bytes: &[u8]) -> Result<(), FetchError> {
        self.written += bytes.len() as u64;
        // More bytes than the attachment said is a mismatch, and never fills the disk.
        if self.written > self.expected || self.written > MAX_ASSET_BYTES {
            return Err(FetchError::Mismatch);
        }
        if Instant::now() > self.deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "the asset took too long").into());
        }
        self.hasher.update(bytes);
        self.out.write_all(bytes)?;
        Ok(())
    }
}

fn copy_exact<W: Write>(
    reader: &mut impl Read,
    mut remaining: u64,
    body: &mut Body<'_, W>,
) -> Result<(), FetchError> {
    let mut buffer = vec![0_u8; 64 * 1024];
    while remaining > 0 {
        let want = remaining.min(buffer.len() as u64) as usize;
        let read = reader.read(&mut buffer[..want])?;
        if read == 0 {
            return Err(FetchError::Mismatch);
        }
        body.take(&buffer[..read])?;
        remaining -= read as u64;
    }
    Ok(())
}

fn copy_to_end<W: Write>(reader: &mut impl Read, body: &mut Body<'_, W>) -> Result<(), FetchError> {
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            return Ok(());
        }
        body.take(&buffer[..read])?;
    }
}

fn read_chunked<W: Write>(
    reader: &mut impl BufRead,
    body: &mut Body<'_, W>,
) -> Result<(), FetchError> {
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 || line.len() > 1024 {
            return Err(FetchError::Mismatch);
        }
        let size_text = line.trim().split(';').next().unwrap_or("");
        let size = u64::from_str_radix(size_text, 16)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "malformed chunk"))?;
        if size == 0 {
            return Ok(());
        }
        copy_exact(reader, size, body)?;
        let mut end = [0_u8; 2];
        reader.read_exact(&mut end)?;
        if &end != b"\r\n" {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "malformed chunk").into());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::Mutex;
    use std::thread;

    const ACCOUNT: &str = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
    const CREDENTIAL: &str = "0d6b0f0a-5f4e-4b1c-9a0e-1f2e3d4c5b6a";
    const HOST: &str = "18355f00-95fd-4c93-8586-a71a8a52bf73";

    struct Store;
    impl HostCredentialStore for Store {
        fn store(&self, _: &str, _: &[u8]) -> io::Result<()> {
            Ok(())
        }
        fn load(&self, _: &str) -> io::Result<Vec<u8>> {
            Ok(vec![7; 32])
        }
        fn delete(&self, _: &str) -> io::Result<()> {
            Ok(())
        }
    }

    /// A relay that answers each request with the next canned response, and records the requests.
    fn relay(responses: Vec<Vec<u8>>) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let record = Arc::clone(&seen);
        thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buffer = [0_u8; 4096];
                // Up to the end of the headers; an upload's body may come in the same read.
                while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                    let read = stream.read(&mut buffer).unwrap();
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..read]);
                }
                record
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&request).into_owned());
                let _ = stream.write_all(&response);
            }
        });
        (origin, seen)
    }

    fn ok(body: &[u8]) -> Vec<u8> {
        let mut response =
            format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        response.extend_from_slice(body);
        response
    }

    fn chunked(body: &[u8]) -> Vec<u8> {
        let mut response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
        for chunk in body.chunks(5) {
            response.extend_from_slice(format!("{:x}\r\n", chunk.len()).as_bytes());
            response.extend_from_slice(chunk);
            response.extend_from_slice(b"\r\n");
        }
        response.extend_from_slice(b"0\r\n\r\n");
        response
    }

    fn source(origin: &str, directory: &Path) -> AssetSource {
        AssetSource {
            endpoint: RelayEndpoint::parse(origin).unwrap(),
            account: AccountLink::parse(ACCOUNT.to_owned(), CREDENTIAL.to_owned()).unwrap(),
            host_id: HOST.to_owned(),
            credentials: Arc::new(Store),
            directory: directory.to_owned(),
        }
    }

    fn attachments(items: &[(&[u8], &str)]) -> Attachments {
        let list = items
            .iter()
            .map(|(bytes, name)| {
                let digest: [u8; 32] = Sha256::digest(bytes).into();
                serde_json::from_value(serde_json::json!({
                    "asset": axo_protocol::asset::AssetHash::from_digest(digest).to_string(),
                    "name": name,
                    "mimeType": "image/png",
                    "size": bytes.len(),
                }))
                .unwrap()
            })
            .collect();
        Attachments::parse(list).unwrap()
    }

    fn temporary_directory() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "axo-assets-{}",
            axo_protocol::new_uuid_v4().unwrap()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn uploads_with_the_host_credential_to_the_asset_s_own_name_and_keeps_a_copy() {
        let directory = temporary_directory();
        let bytes = b"a screenshot".as_slice();
        let (origin, seen) = relay(vec![
            b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let name = AssetName::parse("Mail — Inbox.png".into()).unwrap();
        let mime = AssetType::parse("image/png").unwrap();
        let attachment = upload(&source(&origin, &directory), bytes, name, mime).unwrap();
        let digest: [u8; 32] = Sha256::digest(bytes).into();
        assert_eq!(attachment.asset, AssetHash::from_digest(digest));
        assert_eq!(attachment.size, bytes.len() as u64);
        let request = seen.lock().unwrap()[0].clone();
        assert!(
            request.starts_with(&format!(
                "PUT /api/v1/accounts/{ACCOUNT}/hosts/{HOST}/assets/{} HTTP/1.1\r\n",
                attachment.asset.hex()
            )),
            "{request}"
        );
        assert!(request.contains(&format!("X-Axo-Credential-Id: {CREDENTIAL}\r\n")));
        assert!(request.contains("Content-Type: image/png\r\n"));
        assert!(request.contains("X-Axo-Asset-Name: Mail%20%E2%80%94%20Inbox.png\r\n"));
        let kept = directory
            .join(attachment.asset.hex())
            .join("Mail — Inbox.png");
        assert_eq!(fs::read(kept).unwrap(), bytes);
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn an_upload_the_account_refuses_fails() {
        let directory = temporary_directory();
        let (origin, _) = relay(vec![
            b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let error = upload(
            &source(&origin, &directory),
            b"x",
            AssetName::parse("a.png".into()).unwrap(),
            AssetType::parse("image/png").unwrap(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("full"), "{error}");
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn fetches_with_the_host_credential_checks_the_hash_and_keeps_the_file() {
        let directory = temporary_directory();
        let bytes = b"a photo of a whiteboard".as_slice();
        let (origin, seen) = relay(vec![ok(bytes)]);
        let wanted = attachments(&[(bytes, "whiteboard.png")]);
        let fetched = fetch_all(&source(&origin, &directory), &wanted).unwrap();
        assert_eq!(fs::read(&fetched[0].path).unwrap(), bytes);
        assert_eq!(
            fetched[0].path,
            directory
                .join(fetched[0].asset.hex())
                .join("whiteboard.png")
        );
        let request = seen.lock().unwrap()[0].clone();
        assert!(request.starts_with(&format!(
            "GET /api/v1/accounts/{ACCOUNT}/hosts/{HOST}/assets/{} HTTP/1.1\r\n",
            fetched[0].asset.hex()
        )));
        assert!(
            request
                .contains("Authorization: Bearer BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc\r\n")
        );
        assert!(request.contains(&format!("X-Axo-Credential-Id: {CREDENTIAL}\r\n")));
        // A second prompt with the same file, under another name, needs no download.
        let again = fetch_all(
            &source(&origin, &directory),
            &attachments(&[(bytes, "copy.png")]),
        )
        .unwrap();
        assert_eq!(fs::read(&again[0].path).unwrap(), bytes);
        assert_eq!(seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_chunked_answer_is_read_and_checked() {
        let directory = temporary_directory();
        let bytes = b"chunked bytes arrive in pieces".as_slice();
        let (origin, _) = relay(vec![chunked(bytes)]);
        let fetched = fetch_all(
            &source(&origin, &directory),
            &attachments(&[(bytes, "a.png")]),
        )
        .unwrap();
        assert_eq!(fs::read(&fetched[0].path).unwrap(), bytes);
    }

    #[test]
    fn bytes_that_do_not_match_leave_nothing_behind() {
        let directory = temporary_directory();
        // Same length, so only the hash can tell.
        let (origin, _) = relay(vec![ok(b"BBBBBBBBBB")]);
        let wanted = attachments(&[(b"AAAAAAAAAA", "a.png")]);
        let wanted_hex = wanted.iter().next().unwrap().asset.hex();
        assert!(matches!(
            fetch_all(&source(&origin, &directory), &wanted),
            Err(FetchError::Mismatch)
        ));
        assert_eq!(fs::read_dir(directory.join(wanted_hex)).unwrap().count(), 0);
    }

    #[test]
    fn a_body_longer_than_the_attachment_is_refused_without_reading_it_all() {
        let directory = temporary_directory();
        let (origin, _) = relay(vec![chunked(&[1_u8; 64])]);
        let wanted = attachments(&[(&[1_u8; 8], "a.png")]);
        assert!(matches!(
            fetch_all(&source(&origin, &directory), &wanted),
            Err(FetchError::Mismatch)
        ));
    }

    #[test]
    fn a_missing_asset_refuses_the_whole_prompt() {
        let directory = temporary_directory();
        let first = b"first".as_slice();
        let (origin, _) = relay(vec![
            ok(first),
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let wanted = attachments(&[(first, "one.png"), (b"second", "two.png")]);
        assert!(matches!(
            fetch_all(&source(&origin, &directory), &wanted),
            Err(FetchError::NotFound)
        ));
    }
}
