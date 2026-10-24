//! Axo's local JSON-RPC transport: newline-delimited requests and responses over a Unix socket.
//!
//! Invariant: the executor never blocks. Each connection is its own task, each request its own
//! task, and synchronous handlers (SQLite, process control, the catalog mutex) run on tokio's
//! blocking pool via `add_blocking_method`. Waiting requests such as `axo.session.events.next`
//! are plain futures, so thousands of them cost no threads and never delay unrelated requests.

use std::io;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler, Params, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{Semaphore, mpsc};

/// Largest accepted request line; larger requests close the connection.
const MAX_REQUEST_BYTES: u64 = 8 * 1024 * 1024;
/// Requests one connection may have in flight before its reader waits.
const MAX_IN_FLIGHT_PER_CONNECTION: usize = 64;
/// How often the accept loop checks for shutdown.
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(20);
/// Grace period for in-flight blocking handlers when the daemon stops.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);
/// Requests slower than this are logged once with their method and duration. Long-polls
/// (`axo.session.events.next`) wait by design and are excluded.
const SLOW_REQUEST: Duration = Duration::from_millis(100);

/// Registers synchronous handlers so they run off the executor.
pub(crate) trait BlockingMethods {
    fn add_blocking_method<F>(&mut self, name: &str, method: F)
    where
        F: Fn(Params) -> jsonrpc_core::Result<Value> + Send + Sync + 'static;
}

impl BlockingMethods for IoHandler {
    fn add_blocking_method<F>(&mut self, name: &str, method: F)
    where
        F: Fn(Params) -> jsonrpc_core::Result<Value> + Send + Sync + 'static,
    {
        let method = Arc::new(method);
        self.add_method(name, move |params: Params| {
            let method = Arc::clone(&method);
            async move {
                // Outside a runtime (unit tests using `handle_request_sync`) run inline.
                match tokio::runtime::Handle::try_current() {
                    Ok(runtime) => runtime
                        .spawn_blocking(move || method(params))
                        .await
                        .unwrap_or_else(|_| Err(handler_failed())),
                    Err(_) => method(params),
                }
            }
        });
    }
}

fn handler_failed() -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
        message: "request handler failed".to_owned(),
        data: None,
    }
}

/// Serves `handler` on `listener` until `stop` is set. Blocks the calling thread.
pub(crate) fn serve(
    listener: StdUnixListener,
    handler: IoHandler,
    stop: Arc<AtomicBool>,
) -> io::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("axo-rpc")
        .enable_all()
        .build()?;
    let result = runtime.block_on(accept_until_stopped(listener, Arc::new(handler), stop));
    runtime.shutdown_timeout(SHUTDOWN_GRACE);
    result
}

async fn accept_until_stopped(
    listener: StdUnixListener,
    handler: Arc<IoHandler>,
    stop: Arc<AtomicBool>,
) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let listener = tokio::net::UnixListener::from_std(listener)?;
    while !stop.load(Ordering::Relaxed) {
        // Accept wakes immediately on a connection; the timeout only bounds the shutdown check.
        match tokio::time::timeout(STOP_POLL_INTERVAL, listener.accept()).await {
            Err(_) => {}
            Ok(Ok((stream, _))) => {
                tokio::spawn(serve_connection(stream, Arc::clone(&handler)));
            }
            Ok(Err(error)) => {
                log::warn!("event=ipc.accept_failed error_kind={:?}", error.kind());
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
    Ok(())
}

/// Reads newline-delimited requests and answers each as soon as it completes. Responses may be
/// written out of order; JSON-RPC ids correlate them.
async fn serve_connection(stream: UnixStream, handler: Arc<IoHandler>) {
    let (reader, mut writer) = stream.into_split();
    let (responses, mut outgoing) = mpsc::channel::<String>(MAX_IN_FLIGHT_PER_CONNECTION);
    let writer_task = tokio::spawn(async move {
        while let Some(mut response) = outgoing.recv().await {
            response.push('\n');
            if writer.write_all(response.as_bytes()).await.is_err() {
                break;
            }
        }
    });

    let in_flight = Arc::new(Semaphore::new(MAX_IN_FLIGHT_PER_CONNECTION));
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = (&mut reader)
            .take(MAX_REQUEST_BYTES + 1)
            .read_until(b'\n', &mut line)
            .await;
        match read {
            Ok(0) => break,
            Ok(_) if line.len() as u64 > MAX_REQUEST_BYTES => {
                log::warn!("event=ipc.request_rejected reason=too_large");
                break;
            }
            Ok(_) => {}
            Err(error) => {
                log::debug!("event=ipc.read_failed error_kind={:?}", error.kind());
                break;
            }
        }
        let Ok(request) = std::str::from_utf8(&line) else {
            log::warn!("event=ipc.request_rejected reason=not_utf8");
            break;
        };
        let request = request.trim();
        if request.is_empty() {
            continue;
        }
        let Ok(permit) = Arc::clone(&in_flight).acquire_owned().await else {
            break;
        };
        let request = request.to_owned();
        let handler = Arc::clone(&handler);
        let responses = responses.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let started = std::time::Instant::now();
            let response = handler.handle_request(&request).await;
            log_if_slow(&request, started.elapsed());
            if let Some(response) = response {
                let _ = responses.send(response).await;
            }
        });
    }
    // In-flight requests keep their own sender; the writer finishes after the last response.
    drop(responses);
    let _ = writer_task.await;
}

#[derive(serde::Deserialize)]
struct MethodName<'a> {
    #[serde(borrow)]
    method: Option<&'a str>,
}

fn log_if_slow(request: &str, elapsed: Duration) {
    if elapsed < SLOW_REQUEST {
        return;
    }
    // Only the method name is logged: parameters can carry terminal input or paths.
    let method = serde_json::from_str::<MethodName>(request)
        .ok()
        .and_then(|name| name.method)
        .filter(|method| method.len() <= 64 && method.bytes().all(|b| b.is_ascii_graphic()));
    if method == Some("axo.session.events.next") {
        return;
    }
    log::warn!(
        "event=ipc.slow_request method={} elapsed_ms={}",
        method.unwrap_or("unknown"),
        elapsed.as_millis()
    );
}
