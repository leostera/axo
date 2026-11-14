//! Shared containment transport for Axo's embedded native runtimes.
//! Native work stays on the caller's current-thread executor; only kill/reap proves quiescence.
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub fn watch_owner() -> Result<(), String> {
    if std::env::var_os("AXO_INFER_LIFELINE_STDIN").as_deref() == Some(std::ffi::OsStr::new("1")) {
        std::thread::Builder::new()
            .name("inference-lifeline".into())
            .spawn(|| {
                use std::io::Read;
                let _ = std::io::stdin().read(&mut [0_u8]);
                // SAFETY: EOF revokes ownership. Stop all native threads without racing destructors.
                unsafe {
                    libc::_exit(0);
                }
            })
            .map_err(|_| "could not start native owner watch")?;
    }
    Ok(())
}

async fn exchange<F>(
    stream: &mut tokio::net::UnixStream,
    max_request: u64,
    handler: &mut F,
) -> Result<(), String>
where
    F: FnMut(&[u8]) -> Result<Value, String>,
{
    let mut body = Vec::new();
    tokio::time::timeout(
        Duration::from_secs(5),
        (&mut *stream).take(max_request + 1).read_to_end(&mut body),
    )
    .await
    .map_err(|_| "worker request read timed out")?
    .map_err(|e| e.to_string())?;
    if body.len() as u64 > max_request {
        return Err("worker request exceeds its byte budget".into());
    }
    let response = match handler(&body) {
        Ok(value) => value,
        Err(error) => json!({"error": error}),
    };
    let bytes = serde_json::to_vec(&response).map_err(|e| e.to_string())?;
    if bytes.len() > 1024 * 1024 {
        return Err("worker response exceeds 1 MiB".into());
    }
    tokio::time::timeout(Duration::from_secs(5), stream.write_all(&bytes))
        .await
        .map_err(|_| "worker response write timed out")?
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn serve<F>(socket: &Path, max_request: u64, mut handler: F) -> Result<(), String>
where
    F: FnMut(&[u8]) -> Result<Value, String>,
{
    // Bind only after model initialization. The locked parent alone retires stale sockets.
    let listener = tokio::net::UnixListener::bind(socket).map_err(|e| e.to_string())?;
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    loop {
        let (mut stream, _) =
            match tokio::time::timeout(Duration::from_secs(600), listener.accept()).await {
                Ok(result) => result.map_err(|e| e.to_string())?,
                Err(_) => return Ok(()),
            };
        if exchange(&mut stream, max_request, &mut handler)
            .await
            .is_err()
        {
            // Never log prompts, features, images, output or native request contents.
            eprintln!("event=infer.native_protocol_error");
        }
    }
}
