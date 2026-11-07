//! Axo's local JSON-RPC transport: newline-delimited requests and responses over a Unix socket.
//!
//! Invariant: the executor never blocks. Each connection is its own task, each request its own
//! task, and synchronous handlers (SQLite, process control, the catalog mutex) run on tokio's
//! blocking pool via `add_blocking_method`. Waiting requests such as `axo.session.events.next`
//! are plain futures, so thousands of them cost no threads and never delay unrelated requests.

use std::collections::HashMap;
use std::io;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use std::future::Future;

use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler, Params, Value};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{Semaphore, mpsc};

use crate::cancel::Cancellation;
use crate::peer::Signer;

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

/// Registers handlers that take typed parameters and return typed results. Parameters are parsed
/// before the handler runs (absent parameters count as `{}`); a parse failure is answered with
/// `InvalidParams` and `expected`, describing the accepted shape.
pub trait TypedMethods {
    /// A synchronous handler, run on the blocking pool.
    fn add_typed<P, R, F>(&mut self, name: &str, expected: &'static str, method: F)
    where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Result<R, RpcError> + Send + Sync + 'static;

    /// [`Self::add_typed`] for one kind of caller: anyone else is refused with `only`'s error
    /// before the parameters are read, and the handler never runs.
    fn add_typed_only<P, R, F>(
        &mut self,
        only: Only,
        name: &str,
        expected: &'static str,
        method: F,
    ) where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Result<R, RpcError> + Send + Sync + 'static;

    /// An asynchronous handler for requests that wait (long-polls), run on the executor.
    fn add_typed_async<P, R, F, Fut>(&mut self, name: &str, expected: &'static str, method: F)
    where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<R, RpcError>> + Send + 'static;
}

impl TypedMethods for IoHandler {
    fn add_typed<P, R, F>(&mut self, name: &str, expected: &'static str, method: F)
    where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Result<R, RpcError> + Send + Sync + 'static,
    {
        self.add_blocking_method(name, move |params: Params| {
            let params = parse_params::<P>(params, expected)?;
            method(params).and_then(encode_result)
        });
    }

    fn add_typed_only<P, R, F>(&mut self, only: Only, name: &str, expected: &'static str, method: F)
    where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Result<R, RpcError> + Send + Sync + 'static,
    {
        let method_name = name.to_owned();
        self.add_blocking_method(name, move |params: Params| {
            only.admit(&method_name)?;
            let params = parse_params::<P>(params, expected)?;
            method(params).and_then(encode_result)
        });
    }

    fn add_typed_async<P, R, F, Fut>(&mut self, name: &str, expected: &'static str, method: F)
    where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<R, RpcError>> + Send + 'static,
    {
        let method = Arc::new(method);
        self.add_method(name, move |params: Params| {
            let method = Arc::clone(&method);
            async move {
                let params = parse_params::<P>(params, expected)?;
                method(params).await.and_then(encode_result)
            }
        });
    }
}

/// The one kind of caller a method answers, and what everyone else is told.
#[derive(Clone, Copy, Debug)]
pub struct Only {
    pub signer: Signer,
    pub code: i64,
    pub message: &'static str,
}

impl Only {
    /// Whether the request being handled comes from `signer`; the refusal if not.
    pub fn admit(&self, method: &str) -> Result<(), RpcError> {
        if crate::peer::current().is(self.signer) {
            return Ok(());
        }
        log::warn!(
            "event=rpc.refused method={method} required={:?}",
            self.signer
        );
        Err(RpcError {
            code: ErrorCode::ServerError(self.code),
            message: self.message.to_owned(),
            data: None,
        })
    }
}

fn parse_params<P: DeserializeOwned>(
    params: Params,
    expected: &'static str,
) -> Result<P, RpcError> {
    let parsed = match params {
        Params::None => serde_json::from_value(Value::Object(Default::default())),
        Params::Map(map) => serde_json::from_value(Value::Object(map)),
        Params::Array(array) => serde_json::from_value(Value::Array(array)),
    };
    parsed.map_err(|_| RpcError {
        code: ErrorCode::InvalidParams,
        message: expected.to_owned(),
        data: None,
    })
}

fn encode_result<R: Serialize>(result: R) -> Result<Value, RpcError> {
    serde_json::to_value(result).map_err(|_| RpcError {
        code: ErrorCode::InternalError,
        message: "could not encode the result".to_owned(),
        data: None,
    })
}

/// Registers synchronous handlers so they run off the executor.
trait BlockingMethods {
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
                    Ok(runtime) => {
                        let peer = crate::peer::current();
                        let cancellation = crate::cancel::current();
                        runtime
                            .spawn_blocking(move || {
                                crate::cancel::on_this_thread(cancellation, || {
                                    crate::peer::on_this_thread(peer, || method(params))
                                })
                            })
                            .await
                            .unwrap_or_else(|_| Err(handler_failed()))
                    }
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
pub fn serve(
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
    let peer = crate::peer::Peer::of(&stream);
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
    // Each unanswered request's cancellation, so the connection's end can cancel them.
    let unanswered: Arc<std::sync::Mutex<HashMap<u64, Cancellation>>> = Arc::default();
    let mut next_request = 0u64;
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
        let cancellation = Cancellation::default();
        next_request += 1;
        let key = next_request;
        lock(&unanswered).insert(key, cancellation.clone());
        let unanswered = Arc::clone(&unanswered);
        tokio::spawn(async move {
            let _permit = permit;
            let started = std::time::Instant::now();
            let handled = crate::peer::scope(peer, handler.handle_request(&request));
            let response = crate::cancel::scope(cancellation, handled).await;
            lock(&unanswered).remove(&key);
            log_if_slow(&request, started.elapsed());
            if let Some(response) = response {
                let _ = responses.send(response).await;
            }
        });
    }
    // The caller has gone (AXP §5: its unanswered requests have an unknown outcome): whatever
    // still waits for it gives up.
    let given_up: Vec<Cancellation> = lock(&unanswered)
        .drain()
        .map(|(_, cancellation)| cancellation)
        .collect();
    if !given_up.is_empty() {
        log::info!("event=ipc.connection_closed unanswered={}", given_up.len());
    }
    for cancellation in given_up {
        cancellation.cancel();
    }
    // In-flight requests keep their own sender; the writer finishes after the last response.
    drop(responses);
    let _ = writer_task.await;
}

fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream as StdUnixStream;

    /// A handler that waits until its request is cancelled, and says so on `cancelled`.
    fn serving(
        name: &str,
    ) -> (
        std::path::PathBuf,
        std::sync::mpsc::Receiver<&'static str>,
        Arc<AtomicBool>,
    ) {
        // Under /tmp: socket paths are limited to 104 bytes, and Bazel's TMPDIR is long.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let directory = std::path::PathBuf::from("/tmp").join(format!(
            "axo-ipc-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let socket = directory.join("s.sock");
        let listener = StdUnixListener::bind(&socket).unwrap();
        let (seen, cancelled) = std::sync::mpsc::channel();
        let mut handler = IoHandler::new();
        handler.add_typed("wait", "expected {}", move |_: Value| {
            let (woken, wake) = std::sync::mpsc::channel();
            crate::cancel::current().on_cancel(move || {
                let _ = woken.send(());
            });
            let outcome = match wake.recv_timeout(Duration::from_secs(10)) {
                Ok(()) => "cancelled",
                Err(_) => "timed out",
            };
            let _ = seen.send(outcome);
            Ok(outcome)
        });
        handler.add_typed("quick", "expected {}", |_: Value| {
            Ok(crate::cancel::current().is_cancelled())
        });
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        std::thread::spawn(move || serve(listener, handler, stopping));
        (socket, cancelled, stop)
    }

    fn send(stream: &mut StdUnixStream, method: &str) {
        writeln!(
            stream,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{method}\",\"params\":{{}}}}"
        )
        .unwrap();
    }

    #[test]
    fn a_connection_that_closes_cancels_what_it_still_waits_for() {
        let (socket, cancelled, stop) = serving("closes");
        let mut stream = StdUnixStream::connect(&socket).unwrap();
        send(&mut stream, "wait");
        std::thread::sleep(Duration::from_millis(100));
        drop(stream);
        assert_eq!(
            cancelled.recv_timeout(Duration::from_secs(5)),
            Ok("cancelled")
        );
        stop.store(true, Ordering::Relaxed);
    }

    #[test]
    fn a_method_for_one_caller_refuses_others_before_reading_their_parameters() {
        let mut handler = IoHandler::new();
        let ran = Arc::new(AtomicBool::new(false));
        let running = Arc::clone(&ran);
        handler.add_typed_only(
            Only {
                signer: Signer::AxoApp,
                code: -32099,
                message: "only Axo.app",
            },
            "only",
            "expected {answer}",
            move |_: serde_json::Map<String, Value>| {
                running.store(true, Ordering::Relaxed);
                Ok(true)
            },
        );
        // Outside a connection nobody is Axo.app; malformed parameters are not reached.
        let reply = handler
            .handle_request_sync(r#"{"jsonrpc":"2.0","id":1,"method":"only","params":[1]}"#)
            .unwrap();
        assert!(
            reply.contains("-32099") && reply.contains("only Axo.app"),
            "{reply}"
        );
        assert!(!ran.load(Ordering::Relaxed));
    }

    #[test]
    fn a_request_answered_on_an_open_connection_is_not_cancelled() {
        let (socket, _cancelled, stop) = serving("open");
        let mut stream = StdUnixStream::connect(&socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        send(&mut stream, "quick");
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line).unwrap();
        assert!(line.contains("\"result\":false"), "{line}");
        stop.store(true, Ordering::Relaxed);
    }
}
