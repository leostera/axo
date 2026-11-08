//! Fetching a prompt's attachments (RFD0030) before the prompt reaches Pi, and uploading what
//! this Mac makes for the account (screenshots of computer use from another Mac, RFD0028).
//!
//! Each attachment is downloaded with this Mac's host credential from the account's cached read,
//! to `~/.axo/assets/<hex>/<name>`: written to a temporary file while its SHA-256 is computed,
//! and renamed into place only if the bytes match the name and the size. A prompt gets all its
//! attachments or none: the first that can't be fetched refuses the whole prompt.
//!
//! They are the person's files (screenshots, photos, documents), so only the person's user may
//! read them: every folder is `0700` and every file `0600`, and what an older Axo left more open
//! is closed when the relay starts ([`make_private`]). A file reaches its name only by a rename,
//! so a name never holds a torn copy.
//!
//! The folder mirrors the account, and nothing is evicted, because Pi transcripts name these
//! paths and nothing re-fetches one when it is opened. While connected, the relay [`sweep`]s it:
//! a copy of an asset the account no longer has is removed, so the person's deletes reach every
//! Mac and the folder never outgrows the account's quota (RFD0074).

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};
use tokio::net::TcpStream;

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

/// How long one read or write may wait before the transfer is given up: a transfer is bounded by
/// its progress, not its size, so a 100 MiB upload on a slow link goes on while bytes move.
pub(crate) const READ_TIMEOUT: Duration = Duration::from_secs(30);
/// Bytes of an upload's body written at once, each within [`READ_TIMEOUT`].
const UPLOAD_CHUNK_BYTES: usize = 64 * 1024;
/// How long one attachment may take in all.
const FETCH_DEADLINE: Duration = Duration::from_secs(5 * 60);
const MAX_HEADER_BYTES: usize = 16 * 1024;
/// How often the relay sweeps the folder while it is connected (RFD0074).
pub const SWEEP_EVERY: Duration = Duration::from_secs(6 * 60 * 60);
/// A temporary this old belongs to no live transfer: a fetch's deadline is five minutes.
const STALE_DOWNLOAD: Duration = Duration::from_secs(60 * 60);

/// Held to read by every fetch and upload while it works in the folder, and to write by the
/// sweep while it removes a copy, so a copy is never removed under a fetch that is using it.
static CACHE: std::sync::LazyLock<tokio::sync::RwLock<()>> =
    std::sync::LazyLock::new(|| tokio::sync::RwLock::new(()));

/// Only the person's user may open the assets' folders, or read their files.
const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;

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
pub async fn fetch_all(
    source: &AssetSource,
    attachments: &Attachments,
) -> Result<Vec<FetchedAttachment>, FetchError> {
    let mut fetched = Vec::new();
    for attachment in attachments.iter() {
        let started = Instant::now();
        let outcome = tokio::time::timeout(FETCH_DEADLINE, fetch_one(source, attachment))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "the asset took too long"))?;
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
        fetched.push(outcome?.0);
    }
    Ok(fetched)
}

/// One attachment, and whether it was already on this Mac.
async fn fetch_one(
    source: &AssetSource,
    attachment: &Attachment,
) -> Result<(FetchedAttachment, bool), FetchError> {
    let folder = source.directory.join(attachment.asset.hex());
    let path = folder.join(attachment.name.as_str());
    let _using = CACHE.read().await;
    let fetched = FetchedAttachment {
        path: path.clone(),
        asset: attachment.asset,
        name: attachment.name.clone(),
        mime_type: attachment.mime_type,
        size: attachment.size,
    };
    // Only checked bytes are ever renamed into the folder, so a file there of the asset's size
    // is the asset. Its size still guards against a copy an older Axo wrote in place.
    if is_copy(&path, attachment.size).await {
        return Ok((fetched, true));
    }
    private_folder(&folder).await?;
    if let Some(sibling) = existing_copy(&folder, attachment.size).await? {
        copy_into_place(&sibling, &path).await?;
        return Ok((fetched, true));
    }
    let temporary = folder.join(format!(".download-{}", axo_protocol::new_uuid_v4()?));
    let _cleanup = DownloadFile(temporary.clone());
    let result = download(source, attachment, &temporary).await;
    match result {
        Ok(()) => {
            fs::rename(&temporary, &path).await?;
            Ok((fetched, false))
        }
        Err(error) => {
            let _ = fs::remove_file(&temporary).await;
            Err(error)
        }
    }
}

/// A partial download belongs to its future, including when a caller drops that future.
struct DownloadFile(PathBuf);

impl Drop for DownloadFile {
    fn drop(&mut self) {
        let path = self.0.clone();
        tokio::spawn(async move {
            let _ = fs::remove_file(path).await;
        });
    }
}

async fn within<T>(operation: impl std::future::Future<Output = io::Result<T>>) -> io::Result<T> {
    within_for(READ_TIMEOUT, operation).await
}

/// `operation`, given up if it makes no progress for `stall`.
async fn within_for<T>(
    stall: Duration,
    operation: impl std::future::Future<Output = io::Result<T>>,
) -> io::Result<T> {
    tokio::time::timeout(stall, operation)
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "asset transfer stalled"))?
}

/// Whether `path` is a whole copy of an asset of `size` bytes.
async fn is_copy(path: &Path, size: u64) -> bool {
    fs::metadata(path)
        .await
        .is_ok_and(|meta| meta.is_file() && meta.len() == size)
}

/// A copy already fetched under another name.
async fn existing_copy(folder: &Path, size: u64) -> io::Result<Option<PathBuf>> {
    let mut entries = fs::read_dir(folder).await?;
    while let Some(entry) = entries.next_entry().await? {
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(".download-")
            && is_copy(&entry.path(), size).await
        {
            return Ok(Some(entry.path()));
        }
    }
    Ok(None)
}

async fn copy_into_place(from: &Path, to: &Path) -> io::Result<()> {
    let temporary = to.with_file_name(format!(".download-{}", axo_protocol::new_uuid_v4()?));
    let _cleanup = DownloadFile(temporary.clone());
    fs::copy(from, &temporary).await?;
    fs::set_permissions(&temporary, std::fs::Permissions::from_mode(PRIVATE_FILE)).await?;
    fs::rename(&temporary, to).await
}

/// Creates `folder` (and what it is in) for the person's user alone.
async fn private_folder(folder: &Path) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(PRIVATE_FOLDER)
        .create(folder)
        .await?;
    fs::set_permissions(folder, std::fs::Permissions::from_mode(PRIVATE_FOLDER)).await
}

/// A new file only the person's user may read.
async fn private_file(path: &Path) -> io::Result<fs::File> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(PRIVATE_FILE)
        .open(path)
        .await
}

/// Closes what an older Axo left readable by others: `directory` and its asset folders `0700`,
/// their files `0600`. Links are left alone, never followed. Blocking; run it off the runtime.
pub fn make_private(directory: &Path) -> io::Result<()> {
    use std::fs;
    let set = |path: &Path, mode: u32| fs::set_permissions(path, fs::Permissions::from_mode(mode));
    match fs::symlink_metadata(directory) {
        Ok(meta) if meta.is_dir() => set(directory, PRIVATE_FOLDER)?,
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    for folder in fs::read_dir(directory)? {
        let folder = folder?;
        let kind = folder.file_type()?;
        if kind.is_file() {
            set(&folder.path(), PRIVATE_FILE)?;
            continue;
        }
        if !kind.is_dir() {
            continue;
        }
        set(&folder.path(), PRIVATE_FOLDER)?;
        for file in fs::read_dir(folder.path())? {
            let file = file?;
            if file.file_type()?.is_file() {
                set(&file.path(), PRIVATE_FILE)?;
            }
        }
    }
    Ok(())
}

/// Downloads the asset to `temporary`, checking its size and hash as it goes.
async fn download(
    source: &AssetSource,
    attachment: &Attachment,
    temporary: &Path,
) -> Result<(), FetchError> {
    let url = source.endpoint.asset_url(
        source.account.account_id(),
        &source.host_id,
        &attachment.asset.hex(),
    );
    let headers = authorization(source).await?;
    let deadline = Instant::now() + FETCH_DEADLINE;
    let mut file = private_file(temporary).await?;
    let digest = get(&url, &headers, attachment.size, deadline, &mut file).await?;
    file.sync_all().await?;
    if digest != attachment.asset {
        return Err(FetchError::Mismatch);
    }
    Ok(())
}

/// This Mac's host credential as request headers.
async fn authorization(source: &AssetSource) -> io::Result<String> {
    let credentials = Arc::clone(&source.credentials);
    let id = source.account.credential_id().to_owned();
    let mut secret = crate::blocking(move || credentials.load(&id)).await?;
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
pub async fn upload(
    source: &AssetSource,
    bytes: &[u8],
    name: AssetName,
    mime_type: AssetType,
) -> io::Result<Attachment> {
    upload_within(source, bytes, name, mime_type, READ_TIMEOUT).await
}

/// [`upload`], given up when the connection makes no progress for `stall`.
async fn upload_within(
    source: &AssetSource,
    bytes: &[u8],
    name: AssetName,
    mime_type: AssetType,
    stall: Duration,
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
        authorization(source).await?,
        mime_type.as_str(),
        bytes.len(),
        percent_encode(name.as_str())
    );
    let started = Instant::now();
    let status = async {
        let stream = request(&url, "PUT", &headers, bytes, stall).await?;
        Ok::<_, io::Error>(read_head(&mut BufReader::new(stream), stall).await?.status)
    }
    .await;
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
    // A copy where a fetch would put it, so this Mac never downloads its own image again. Only a
    // cache: the upload stands without it.
    if let Err(error) = keep_copy(&source.directory, &asset, &name, bytes).await {
        log::warn!(
            "event=assets.copy_failed hash={} error={error}",
            asset.hex()
        );
    }
    Ok(Attachment {
        asset,
        name,
        mime_type,
        size: bytes.len() as u64,
    })
}

/// Writes `bytes` under `name` in the asset's folder, whole or not at all.
async fn keep_copy(
    directory: &Path,
    asset: &AssetHash,
    name: &AssetName,
    bytes: &[u8],
) -> io::Result<()> {
    let _using = CACHE.read().await;
    let folder = directory.join(asset.hex());
    private_folder(&folder).await?;
    let temporary = folder.join(format!(".download-{}", axo_protocol::new_uuid_v4()?));
    let _cleanup = DownloadFile(temporary.clone());
    let mut file = private_file(&temporary).await?;
    file.write_all(bytes).await?;
    file.sync_all().await?;
    fs::rename(&temporary, folder.join(name.as_str())).await
}

/// Removes every copy of an asset the account no longer has, and every temporary no transfer
/// owns. Answers how many copies it removed. A copy is removed only on the account's `404`, asked
/// once to pick it and once more while no fetch can use it; on any other answer, or none, it is
/// kept. Only folders named by a hash are touched.
pub async fn sweep(source: &AssetSource) -> io::Result<usize> {
    let mut folders = match fs::read_dir(&source.directory).await {
        Ok(folders) => folders,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };
    let mut removed = 0;
    while let Some(folder) = folders.next_entry().await? {
        let Some(hex) = folder.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !is_hash(&hex) || !folder.file_type().await?.is_dir() {
            continue;
        }
        remove_stale_downloads(&folder.path()).await;
        if !is_gone(source, &hex).await {
            continue;
        }
        let _removing = CACHE.write().await;
        if is_gone(source, &hex).await {
            fs::remove_dir_all(folder.path()).await?;
            log::info!("event=assets.swept hash={hex}");
            removed += 1;
        }
    }
    Ok(removed)
}

fn is_hash(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// Whether the account answers that it has no asset `hex`; anything else is not gone.
async fn is_gone(source: &AssetSource, hex: &str) -> bool {
    let url = source
        .endpoint
        .asset_url(source.account.account_id(), &source.host_id, hex);
    let status = async {
        let headers = authorization(source).await?;
        let stream = request(&url, "HEAD", &headers, &[], READ_TIMEOUT).await?;
        Ok::<_, io::Error>(
            read_head(&mut BufReader::new(stream), READ_TIMEOUT)
                .await?
                .status,
        )
    }
    .await;
    match status {
        Ok(404) => true,
        Ok(_) => false,
        Err(error) => {
            log::warn!("event=assets.sweep_unanswered hash={hex} error={error}");
            false
        }
    }
}

async fn remove_stale_downloads(folder: &Path) {
    let Ok(mut entries) = fs::read_dir(folder).await else {
        return;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let stale = entry.metadata().await.is_ok_and(|meta| {
            meta.is_file()
                && meta
                    .modified()
                    .ok()
                    .and_then(|modified| modified.elapsed().ok())
                    .is_some_and(|age| age > STALE_DOWNLOAD)
        });
        if stale
            && entry
                .file_name()
                .to_string_lossy()
                .starts_with(".download-")
        {
            let _ = fs::remove_file(entry.path()).await;
        }
    }
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
async fn connect(url: &Url) -> io::Result<(Box<dyn ReadWrite>, String)> {
    let host = url
        .host_str()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "asset URL has no host"))?;
    let port = url.port_or_known_default().unwrap_or(443);
    let stream = TcpStream::connect((host, port)).await?;
    let host_header = if port == 443 || port == 80 {
        host.to_owned()
    } else {
        format!("{host}:{port}")
    };
    if url.scheme() == "http" {
        return Ok((Box::new(stream), host_header));
    }
    let connector = crate::blocking(TlsConnector::new)
        .await
        .map_err(|_| io::Error::other("could not initialize TLS"))?;
    let stream = tokio_native_tls::TlsConnector::from(connector)
        .connect(host, stream)
        .await
        .map_err(|_| io::Error::other("could not establish a secure connection"))?;
    Ok((Box::new(stream), host_header))
}

pub(crate) trait ReadWrite: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> ReadWrite for T {}

/// Sends one request and returns its response stream.
pub(crate) async fn request(
    url: &Url,
    method: &str,
    extra_headers: &str,
    body: &[u8],
    stall: Duration,
) -> io::Result<Box<dyn ReadWrite>> {
    let (mut stream, host_header) = within_for(stall, connect(url)).await?;
    let headers = format!(
        "{method} {} HTTP/1.1\r\nHost: {host_header}\r\n{extra_headers}Accept-Encoding: identity\r\nConnection: close\r\n\r\n",
        url.path()
    );
    within_for(stall, stream.write_all(headers.as_bytes())).await?;
    for chunk in body.chunks(UPLOAD_CHUNK_BYTES) {
        within_for(stall, stream.write_all(chunk)).await?;
    }
    within_for(stall, stream.flush()).await?;
    Ok(stream)
}

/// GETs `url`, streams at most `expected` bytes into `out`, and returns their hash. Fails with
/// `Mismatch` if the body is not exactly `expected` bytes.
async fn get(
    url: &Url,
    extra_headers: &str,
    expected: u64,
    deadline: Instant,
    out: &mut (impl AsyncWrite + Unpin),
) -> Result<axo_protocol::asset::AssetHash, FetchError> {
    let mut stream = request(url, "GET", extra_headers, &[], READ_TIMEOUT).await?;
    receive(&mut *stream, expected, deadline, out).await
}

/// Reads a GET's response: the body's bytes into `out`, checked against `expected`.
async fn receive(
    stream: &mut dyn ReadWrite,
    expected: u64,
    deadline: Instant,
    out: &mut (impl AsyncWrite + Unpin),
) -> Result<AssetHash, FetchError> {
    let mut reader = BufReader::new(stream);
    let head = read_head(&mut reader, READ_TIMEOUT).await?;
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
        read_chunked(&mut reader, &mut body).await?;
    } else if let Some(length) = head.length {
        if length != expected {
            return Err(FetchError::Mismatch);
        }
        copy_exact(&mut reader, length, &mut body).await?;
    } else {
        copy_to_end(&mut reader, &mut body).await?;
    }
    if body.written != expected {
        return Err(FetchError::Mismatch);
    }
    let digest: [u8; 32] = body.hasher.finalize().into();
    Ok(AssetHash::from_digest(digest))
}

pub(crate) struct Head {
    pub(crate) status: u16,
    length: Option<u64>,
    chunked: bool,
}

pub(crate) async fn read_head(
    reader: &mut (impl AsyncBufRead + Unpin),
    stall: Duration,
) -> io::Result<Head> {
    let mut raw = Vec::new();
    loop {
        let read = within_for(
            stall,
            reader
                .take((MAX_HEADER_BYTES + 1 - raw.len()) as u64)
                .read_until(b'\n', &mut raw),
        )
        .await?;
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

struct Body<'a, W: AsyncWrite + Unpin> {
    hasher: Sha256,
    written: u64,
    expected: u64,
    deadline: Instant,
    out: &'a mut W,
}

impl<W: AsyncWrite + Unpin> Body<'_, W> {
    async fn take(&mut self, bytes: &[u8]) -> Result<(), FetchError> {
        self.written += bytes.len() as u64;
        // More bytes than the attachment said is a mismatch, and never fills the disk.
        if self.written > self.expected || self.written > MAX_ASSET_BYTES {
            return Err(FetchError::Mismatch);
        }
        if Instant::now() > self.deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "the asset took too long").into());
        }
        self.hasher.update(bytes);
        self.out.write_all(bytes).await?;
        Ok(())
    }
}

async fn copy_exact<W: AsyncWrite + Unpin>(
    reader: &mut (impl AsyncRead + Unpin),
    mut remaining: u64,
    body: &mut Body<'_, W>,
) -> Result<(), FetchError> {
    let mut buffer = vec![0_u8; 64 * 1024];
    while remaining > 0 {
        let want = remaining.min(buffer.len() as u64) as usize;
        let read = within(reader.read(&mut buffer[..want])).await?;
        if read == 0 {
            return Err(FetchError::Mismatch);
        }
        body.take(&buffer[..read]).await?;
        remaining -= read as u64;
    }
    Ok(())
}

async fn copy_to_end<W: AsyncWrite + Unpin>(
    reader: &mut (impl AsyncRead + Unpin),
    body: &mut Body<'_, W>,
) -> Result<(), FetchError> {
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = within(reader.read(&mut buffer)).await?;
        if read == 0 {
            return Ok(());
        }
        body.take(&buffer[..read]).await?;
    }
}

async fn read_chunked<W: AsyncWrite + Unpin>(
    reader: &mut (impl AsyncBufRead + Unpin),
    body: &mut Body<'_, W>,
) -> Result<(), FetchError> {
    loop {
        let mut line = String::new();
        if within(reader.take(1025).read_line(&mut line)).await? == 0 || line.len() > 1024 {
            return Err(FetchError::Mismatch);
        }
        let size_text = line.trim().split(';').next().unwrap_or("");
        let size = u64::from_str_radix(size_text, 16)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "malformed chunk"))?;
        if size == 0 {
            return Ok(());
        }
        copy_exact(reader, size, body).await?;
        let mut end = [0_u8; 2];
        within(reader.read_exact(&mut end)).await?;
        if &end != b"\r\n" {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "malformed chunk").into());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::{Read, Write};
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
                // Drain the request body before closing. Windows resets a TCP connection
                // closed with unread data, which can hide the canned HTTP error from clients.
                while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                    let read = stream.read(&mut buffer).unwrap();
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..read]);
                }
                if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    let length = String::from_utf8_lossy(&request[..end])
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().ok())
                                .flatten()
                        })
                        .unwrap_or(0);
                    while request.len() < end + 4 + length {
                        let read = stream.read(&mut buffer).unwrap();
                        if read == 0 {
                            break;
                        }
                        request.extend_from_slice(&buffer[..read]);
                    }
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

    /// A relay answering `HEAD` for each asset with the statuses `statuses` give its hash, in
    /// turn, the last one from then on; `500` for any other.
    fn account_with(statuses: Vec<(String, Vec<u16>)>) -> String {
        let statuses = Mutex::new(statuses);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut request = Vec::new();
                let mut buffer = [0_u8; 4096];
                while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                    let read = stream.read(&mut buffer).unwrap_or(0);
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..read]);
                }
                let request = String::from_utf8_lossy(&request);
                assert!(request.starts_with("HEAD "), "{request}");
                let status = statuses
                    .lock()
                    .unwrap()
                    .iter_mut()
                    .find(|(hex, _)| request.contains(&format!("/assets/{hex} ")))
                    .map_or(500, |(_, answers)| {
                        if answers.len() > 1 {
                            answers.remove(0)
                        } else {
                            answers[0]
                        }
                    });
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
            }
        });
        origin
    }

    #[tokio::test]
    async fn the_sweep_removes_only_copies_the_account_no_longer_has() {
        let directory = temporary_directory();
        let hex = |byte: u8| format!("{byte:02x}").repeat(32);
        let (deleted, kept, unanswered) = (hex(0xaa), hex(0xbb), hex(0xcc));
        for folder in [&deleted, &kept, &unanswered, &"notes".to_owned()] {
            fs::create_dir_all(directory.join(folder)).unwrap();
            fs::write(directory.join(folder).join("file.pdf"), b"x").unwrap();
        }
        let stale = directory.join(&kept).join(".download-stale");
        let fresh = directory.join(&kept).join(".download-fresh");
        for path in [&stale, &fresh] {
            fs::write(path, b"part").unwrap();
        }
        fs::File::options()
            .write(true)
            .open(&stale)
            .unwrap()
            .set_modified(std::time::SystemTime::now() - 2 * STALE_DOWNLOAD)
            .unwrap();
        let origin = account_with(vec![
            (deleted.clone(), vec![404]),
            (kept.clone(), vec![200]),
        ]);

        assert_eq!(sweep(&source(&origin, &directory)).await.unwrap(), 1);
        assert!(!directory.join(&deleted).exists(), "the person deleted it");
        assert!(directory.join(&kept).join("file.pdf").exists());
        assert!(
            directory.join(&unanswered).join("file.pdf").exists(),
            "never removed on doubt"
        );
        assert!(directory.join("notes").join("file.pdf").exists());
        assert!(!stale.exists(), "no transfer owns an hour-old temporary");
        assert!(fresh.exists(), "a live transfer's temporary is its own");
        assert_eq!(sweep(&source(&origin, &directory)).await.unwrap(), 0);
        let _ = fs::remove_dir_all(&directory);
    }

    #[tokio::test]
    async fn a_copy_uploaded_again_while_it_is_swept_is_kept() {
        let directory = temporary_directory();
        let hex = "dd".repeat(32);
        fs::create_dir_all(directory.join(&hex)).unwrap();
        // Gone when picked, back by the time no fetch can use it.
        let origin = account_with(vec![(hex.clone(), vec![404, 200])]);
        assert_eq!(sweep(&source(&origin, &directory)).await.unwrap(), 0);
        assert!(directory.join(&hex).exists());
        let _ = fs::remove_dir_all(&directory);
    }

    #[tokio::test]
    async fn a_missing_folder_sweeps_nothing() {
        let directory = temporary_directory().join("never-made");
        assert_eq!(
            sweep(&source(&account_with(vec![]), &directory))
                .await
                .unwrap(),
            0
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_stalled_body_yields_the_runtime_until_its_remaining_bytes_arrive() {
        use tokio::io::AsyncWriteExt;
        let (mut client, mut server) = tokio::io::duplex(4096);
        let transfer = tokio::spawn(async move {
            let mut out = Vec::new();
            let hash = receive(&mut client, 4, Instant::now() + FETCH_DEADLINE, &mut out)
                .await
                .unwrap();
            assert_eq!(out, b"abcd");
            assert_eq!(hash, AssetHash::from_digest(Sha256::digest(b"abcd").into()));
        });
        server
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab")
            .await
            .unwrap();
        tokio::task::yield_now().await;
        assert!(!transfer.is_finished());
        server.write_all(b"cd").await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), transfer)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn response_headers_are_bounded_even_without_a_newline() {
        let oversized = vec![b'x'; MAX_HEADER_BYTES + 2];
        let mut reader = BufReader::new(oversized.as_slice());
        let error = read_head(&mut reader, READ_TIMEOUT).await.err().unwrap();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn uploads_with_the_host_credential_to_the_asset_s_own_name_and_keeps_a_copy() {
        let directory = temporary_directory();
        let bytes = b"a screenshot".as_slice();
        let (origin, seen) = relay(vec![
            b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let name = AssetName::parse("Mail — Inbox.png".into()).unwrap();
        let mime = AssetType::parse("image/png").unwrap();
        let attachment = upload(&source(&origin, &directory), bytes, name, mime)
            .await
            .unwrap();
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

    /// A relay that takes an upload's body slowly, `pace` bytes a tenth of a second, and answers
    /// 201 once it has it all.
    fn slow_relay(pace: usize) -> String {
        use std::io::{BufRead, Read, Write};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = std::io::BufReader::new(stream);
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(value) = line.strip_prefix("Content-Length: ") {
                    length = value.trim().parse::<usize>().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
            }
            let mut chunk = vec![0_u8; pace];
            while length > 0 {
                let take = pace.min(length);
                reader.read_exact(&mut chunk[..take]).unwrap();
                length -= take;
                thread::sleep(Duration::from_millis(100));
            }
            let _ = reader
                .get_mut()
                .write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n");
        });
        origin
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_upload_that_keeps_moving_is_not_cut_off_by_its_size() {
        let directory = temporary_directory();
        // About 1.6 s in all, never a pause near the one-second stall.
        let bytes = vec![7_u8; 8 * 1024 * 1024];
        let origin = slow_relay(512 * 1024);
        let uploaded = upload_within(
            &source(&origin, &directory),
            &bytes,
            AssetName::parse("big.png".into()).unwrap(),
            AssetType::parse("image/png").unwrap(),
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert_eq!(uploaded.size, bytes.len() as u64);
        let _ = fs::remove_dir_all(&directory);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_upload_that_stops_moving_is_given_up() {
        let directory = temporary_directory();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        // Accepts, then never reads: the body fills the buffers and stops.
        let held = thread::spawn(move || listener.accept().unwrap());
        let error = upload_within(
            &source(&origin, &directory),
            &vec![7_u8; 32 * 1024 * 1024],
            AssetName::parse("big.png".into()).unwrap(),
            AssetType::parse("image/png").unwrap(),
            Duration::from_millis(300),
        )
        .await
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut, "{error}");
        drop(held.join());
        let _ = fs::remove_dir_all(&directory);
    }

    #[tokio::test]
    async fn an_upload_the_account_refuses_fails() {
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
        .await
        .unwrap_err();
        assert!(error.to_string().contains("full"), "{error}");
        let _ = fs::remove_dir_all(&directory);
    }

    #[tokio::test]
    async fn fetches_with_the_host_credential_checks_the_hash_and_keeps_the_file() {
        let directory = temporary_directory();
        let bytes = b"a photo of a whiteboard".as_slice();
        let (origin, seen) = relay(vec![ok(bytes)]);
        let wanted = attachments(&[(bytes, "whiteboard.png")]);
        let fetched = fetch_all(&source(&origin, &directory), &wanted)
            .await
            .unwrap();
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
        .await
        .unwrap();
        assert_eq!(fs::read(&again[0].path).unwrap(), bytes);
        assert_eq!(seen.lock().unwrap().len(), 1);
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[tokio::test]
    async fn only_the_persons_user_may_read_what_is_fetched_or_kept() {
        let directory = temporary_directory().join("assets");
        let fetched_bytes = b"a private photo".as_slice();
        let (origin, _) = relay(vec![
            ok(fetched_bytes),
            b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let source = source(&origin, &directory);
        let fetched = fetch_all(&source, &attachments(&[(fetched_bytes, "photo.png")]))
            .await
            .unwrap();
        let again = fetch_all(&source, &attachments(&[(fetched_bytes, "copy.png")]))
            .await
            .unwrap();
        let kept = upload(
            &source,
            b"a screenshot",
            AssetName::parse("screen.png".into()).unwrap(),
            AssetType::parse("image/png").unwrap(),
        )
        .await
        .unwrap();
        let kept = directory.join(kept.asset.hex()).join("screen.png");
        assert_eq!(mode(&directory), 0o700);
        for file in [&fetched[0].path, &again[0].path, &kept] {
            assert_eq!(mode(file.parent().unwrap()), 0o700, "{}", file.display());
            assert_eq!(mode(file), 0o600, "{}", file.display());
        }
        let _ = fs::remove_dir_all(directory.parent().unwrap());
    }

    #[test]
    fn what_an_older_axo_left_open_is_closed_and_links_are_not_followed() {
        let root = temporary_directory();
        let directory = root.join("assets");
        let folder = directory.join("abc");
        fs::create_dir_all(&folder).unwrap();
        let file = folder.join("photo.png");
        fs::write(&file, b"x").unwrap();
        let outside = root.join("outside.txt");
        fs::write(&outside, b"y").unwrap();
        std::os::unix::fs::symlink(&outside, folder.join("link")).unwrap();
        for path in [&directory, &folder] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        for path in [&file, &outside] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
        }
        make_private(&directory).unwrap();
        assert_eq!(mode(&directory), 0o700);
        assert_eq!(mode(&folder), 0o700);
        assert_eq!(mode(&file), 0o600);
        assert_eq!(
            mode(&outside),
            0o644,
            "a link's target is not ours to change"
        );
        make_private(&root.join("missing")).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn a_torn_copy_is_never_taken_for_the_asset() {
        let directory = temporary_directory();
        let bytes = b"the whole screenshot".as_slice();
        let wanted = attachments(&[(bytes, "screen.png")]);
        let folder = directory.join(wanted.iter().next().unwrap().asset.hex());
        fs::create_dir_all(&folder).unwrap();
        // What a killed in-place write left: under the name, and under another name.
        fs::write(folder.join("screen.png"), &bytes[..5]).unwrap();
        fs::write(folder.join("other.png"), &bytes[..7]).unwrap();
        let (origin, seen) = relay(vec![ok(bytes)]);
        let fetched = fetch_all(&source(&origin, &directory), &wanted)
            .await
            .unwrap();
        assert_eq!(fs::read(&fetched[0].path).unwrap(), bytes);
        assert_eq!(seen.lock().unwrap().len(), 1, "fetched again, not copied");
        let _ = fs::remove_dir_all(&directory);
    }

    #[tokio::test]
    async fn a_chunked_answer_is_read_and_checked() {
        let directory = temporary_directory();
        let bytes = b"chunked bytes arrive in pieces".as_slice();
        let (origin, _) = relay(vec![chunked(bytes)]);
        let fetched = fetch_all(
            &source(&origin, &directory),
            &attachments(&[(bytes, "a.png")]),
        )
        .await
        .unwrap();
        assert_eq!(fs::read(&fetched[0].path).unwrap(), bytes);
    }

    #[tokio::test]
    async fn bytes_that_do_not_match_leave_nothing_behind() {
        let directory = temporary_directory();
        // Same length, so only the hash can tell.
        let (origin, _) = relay(vec![ok(b"BBBBBBBBBB")]);
        let wanted = attachments(&[(b"AAAAAAAAAA", "a.png")]);
        let wanted_hex = wanted.iter().next().unwrap().asset.hex();
        assert!(matches!(
            fetch_all(&source(&origin, &directory), &wanted).await,
            Err(FetchError::Mismatch)
        ));
        assert_eq!(fs::read_dir(directory.join(wanted_hex)).unwrap().count(), 0);
    }

    #[tokio::test]
    async fn a_body_longer_than_the_attachment_is_refused_without_reading_it_all() {
        let directory = temporary_directory();
        let (origin, _) = relay(vec![chunked(&[1_u8; 64])]);
        let wanted = attachments(&[(&[1_u8; 8], "a.png")]);
        assert!(matches!(
            fetch_all(&source(&origin, &directory), &wanted).await,
            Err(FetchError::Mismatch)
        ));
    }

    #[tokio::test]
    async fn a_missing_asset_refuses_the_whole_prompt() {
        let directory = temporary_directory();
        let first = b"first".as_slice();
        let (origin, _) = relay(vec![
            ok(first),
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let wanted = attachments(&[(first, "one.png"), (b"second", "two.png")]);
        assert!(matches!(
            fetch_all(&source(&origin, &directory), &wanted).await,
            Err(FetchError::NotFound)
        ));
    }
}
