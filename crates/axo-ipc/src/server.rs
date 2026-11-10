//! Axo's local JSON-RPC transport: newline-delimited requests and responses over a Unix socket.
//!
//! Invariant: the executor never blocks. Each connection is its own task, each request its own
//! task. Handlers are futures; any truly blocking work must be explicitly isolated by its
//! owner. Waiting requests and upgraded streams cost no threads and never delay unrelated requests.

use std::collections::HashMap;
use std::io;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::sync::Arc;
use std::time::Duration;

use std::future::Future;

use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler, Params, Value};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{Semaphore, mpsc};

use crate::cancel::Cancellation;
use crate::peer::Caller;

/// Largest accepted request line; larger requests close the connection.
const MAX_REQUEST_BYTES: u64 = 8 * 1024 * 1024;
/// Requests one connection may have in flight before its reader waits.
const MAX_IN_FLIGHT_PER_CONNECTION: usize = 64;
/// Requests slower than this are logged once with their method and duration.
const SLOW_REQUEST: Duration = Duration::from_millis(100);

/// Registers handlers that take typed parameters and return typed results. Parameters are parsed
/// before the handler runs (absent parameters count as `{}`); a parse failure is answered with
/// `InvalidParams`, `expected` describing the accepted shape, and what was wrong with these.
pub trait TypedMethods {
    /// An asynchronous handler, run on the executor: it must never block.
    fn add_typed<P, R, F, Fut>(&mut self, name: &str, expected: &'static str, method: F)
    where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<R, RpcError>> + Send + 'static;

    /// [`Self::add_typed`] for one kind of caller; refuses others before parsing parameters.
    fn add_typed_only<P, R, F, Fut>(
        &mut self,
        only: Only,
        name: &str,
        expected: &'static str,
        method: F,
    ) where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<R, RpcError>> + Send + 'static;
}

impl TypedMethods for IoHandler {
    fn add_typed<P, R, F, Fut>(&mut self, name: &str, expected: &'static str, method: F)
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

    fn add_typed_only<P, R, F, Fut>(
        &mut self,
        only: Only,
        name: &str,
        expected: &'static str,
        method: F,
    ) where
        P: DeserializeOwned + 'static,
        R: Serialize + 'static,
        F: Fn(P) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<R, RpcError>> + Send + 'static,
    {
        let method = Arc::new(method);
        let method_name = name.to_owned();
        self.add_method(name, move |params: Params| {
            let method = Arc::clone(&method);
            let method_name = method_name.clone();
            async move {
                // Checked when the call runs, within its peer's scope.
                only.admit(&method_name)?;
                let params = parse_params::<P>(params, expected)?;
                method(params).await.and_then(encode_result)
            }
        });
    }
}

/// The one kind of caller a method answers, and what everyone else is told.
#[derive(Clone, Copy, Debug)]
pub struct Only {
    pub caller: Caller,
    pub code: i64,
    pub message: &'static str,
}

impl Only {
    /// Whether the request being handled comes from `caller`; the refusal if not.
    pub fn admit(&self, method: &str) -> Result<(), RpcError> {
        if crate::peer::current().is_caller(self.caller) {
            return Ok(());
        }
        log::warn!(
            "event=rpc.refused method={method} required={:?}",
            self.caller
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
    // The parameters' own types say what was wrong (a bound, a malformed ID), so the caller is
    // told that too; it only repeats what the caller sent.
    parsed.map_err(|error| RpcError {
        code: ErrorCode::InvalidParams,
        message: format!("{expected}: {error}"),
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

/// A connection taken over by its first request: an [`Upgrades`] method, such as the MCP server
/// that `axod mcp` opens. From then on the connection carries what the upgrade speaks, not
/// axod's requests.
pub struct Upgraded {
    id: Value,
    /// The first request's parameters.
    pub params: Value,
    /// What the client sends from here on; what it sent after its first request comes first.
    pub reader: UpgradedReader,
    pub writer: tokio::net::unix::OwnedWriteHalf,
    /// axod's methods, called as this connection's peer.
    pub local: crate::local::Local,
}

/// The read side of an upgraded connection.
pub type UpgradedReader =
    BufReader<tokio::io::Chain<std::io::Cursor<Vec<u8>>, tokio::net::unix::OwnedReadHalf>>;

impl Upgraded {
    /// Answers the first request; call it once, before anything else is written.
    pub async fn answer(&mut self, result: Result<Value, RpcError>) -> io::Result<()> {
        let response = match result {
            Ok(result) => serde_json::json!({ "jsonrpc": "2.0", "id": self.id, "result": result }),
            Err(error) => serde_json::json!({ "jsonrpc": "2.0", "id": self.id, "error": error }),
        };
        let mut line = response.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes()).await?;
        self.writer.flush().await
    }
}

type Upgrade =
    Arc<dyn Fn(Upgraded) -> std::pin::Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

/// Methods that take over the connection they arrive on, when they are its first request. Each
/// runs as the connection's task for as long as it keeps the connection.
#[derive(Clone, Default)]
pub struct Upgrades(HashMap<String, Upgrade>);

impl Upgrades {
    pub fn add<F, Fut>(&mut self, method: &str, upgrade: F)
    where
        F: Fn(Upgraded) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        self.0.insert(
            method.to_owned(),
            Arc::new(move |upgraded| Box::pin(upgrade(upgraded))),
        );
    }

    fn get(&self, request: &str) -> Option<(Upgrade, Value, Value)> {
        if self.0.is_empty() {
            return None;
        }
        let mut request: Value = serde_json::from_str(request).ok()?;
        let upgrade = self.0.get(request.get("method")?.as_str()?)?;
        Some((
            Arc::clone(upgrade),
            request["id"].take(),
            request["params"].take(),
        ))
    }
}

/// Serves `handler` on `listener`, on `runtime`, until `stop`. Blocks the calling thread, which
/// must not be one of the runtime's. Requests still running when it returns are the runtime
/// owner's to wait for or cut short.
pub fn serve(
    runtime: &tokio::runtime::Handle,
    listener: StdUnixListener,
    handler: IoHandler,
    upgrades: Upgrades,
    stop: crate::Stop,
) -> io::Result<()> {
    runtime.block_on(accept_until_stopped(
        listener,
        Arc::new(handler),
        Arc::new(upgrades),
        stop,
    ))
}

async fn accept_until_stopped(
    listener: StdUnixListener,
    handler: Arc<IoHandler>,
    upgrades: Arc<Upgrades>,
    stop: crate::Stop,
) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let listener = tokio::net::UnixListener::from_std(listener)?;
    loop {
        let accepted = tokio::select! {
            () = stop.stopped() => return Ok(()),
            accepted = listener.accept() => accepted,
        };
        match accepted {
            Ok((stream, _)) => {
                let (handler, upgrades) = (Arc::clone(&handler), Arc::clone(&upgrades));
                tokio::spawn(serve_connection(stream, handler, upgrades));
            }
            Err(error) => {
                log::warn!("event=ipc.accept_failed error_kind={:?}", error.kind());
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// One request line into `line`; `false` when the connection ends or misbehaves.
async fn read_request<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    line: &mut Vec<u8>,
) -> bool {
    line.clear();
    match reader
        .take(MAX_REQUEST_BYTES + 1)
        .read_until(b'\n', line)
        .await
    {
        Ok(0) => false,
        Ok(_) if line.len() as u64 > MAX_REQUEST_BYTES => {
            log::warn!("event=ipc.request_rejected reason=too_large");
            false
        }
        Ok(_) => true,
        Err(error) => {
            log::debug!("event=ipc.read_failed error_kind={:?}", error.kind());
            false
        }
    }
}

/// Reads newline-delimited requests and answers each as soon as it completes. Responses may be
/// written out of order; JSON-RPC ids correlate them. A first request that names an upgrade
/// hands the connection to it instead.
async fn serve_connection(stream: UnixStream, handler: Arc<IoHandler>, upgrades: Arc<Upgrades>) {
    let peer = crate::peer::Peer::of(&stream);
    let (reader, writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    if !read_request(&mut reader, &mut line).await {
        return;
    }
    if let Some((upgrade, id, params)) = std::str::from_utf8(&line)
        .ok()
        .and_then(|request| upgrades.get(request.trim()))
    {
        let pending = std::io::Cursor::new(reader.buffer().to_vec());
        let reader = BufReader::new(pending.chain(reader.into_inner()));
        let local = crate::local::Local::new(handler, peer);
        let upgraded = Upgraded {
            id,
            params,
            reader,
            writer,
            local,
        };
        upgrade(upgraded).await;
        return;
    }
    let mut writer = writer;
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
    // The first request is in `line` already.
    let mut read = true;
    while read {
        let Ok(request) = std::str::from_utf8(&line) else {
            log::warn!("event=ipc.request_rejected reason=not_utf8");
            break;
        };
        let request = request.trim();
        if !request.is_empty() {
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
        read = read_request(&mut reader, &mut line).await;
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
    log::warn!(
        "event=ipc.slow_request method={} elapsed_ms={}",
        method.unwrap_or("unknown"),
        elapsed.as_millis()
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::Signer;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream as StdUnixStream;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// A handler that waits until its request is cancelled, and says so on `cancelled`.
    fn serving(
        name: &str,
    ) -> (
        std::path::PathBuf,
        std::sync::mpsc::Receiver<&'static str>,
        crate::Stop,
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
            let seen = seen.clone();
            async move {
                let cancellation = crate::cancel::current();
                let outcome =
                    match tokio::time::timeout(Duration::from_secs(10), cancellation.cancelled())
                        .await
                    {
                        Ok(()) => "cancelled",
                        Err(_) => "timed out",
                    };
                let _ = seen.send(outcome);
                Ok(outcome)
            }
        });
        handler.add_typed("quick", "expected {}", |_: Value| async {
            Ok(crate::cancel::current().is_cancelled())
        });
        let stop = crate::Stop::default();
        let stopping = stop.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();
            let served = serve(runtime.handle(), listener, handler, upgraded(), stopping);
            // Handlers still waiting are not waited for.
            runtime.shutdown_background();
            served
        });
        (socket, cancelled, stop)
    }

    /// `shout.open` answers with its parameters, then shouts each line back, and says whether
    /// axod's own `quick` answers it in process.
    fn upgraded() -> Upgrades {
        let mut upgrades = Upgrades::default();
        upgrades.add("shout.open", |mut upgraded: Upgraded| async move {
            let params = upgraded.params.clone();
            upgraded.answer(Ok(params)).await.unwrap();
            let quick = upgraded
                .local
                .call(
                    "quick",
                    Value::Null,
                    Duration::from_secs(1),
                    &Cancellation::default(),
                )
                .await;
            let mut out = upgraded.writer;
            out.write_all(format!("quick={quick:?}\n").as_bytes())
                .await
                .unwrap();
            let mut lines = upgraded.reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                out.write_all(format!("{}\n", line.to_uppercase()).as_bytes())
                    .await
                    .unwrap();
            }
        });
        upgrades
    }

    #[test]
    fn refused_parameters_say_the_expected_shape_and_what_was_wrong() {
        #[derive(Debug, serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Bounded {
            #[allow(dead_code)]
            count: u8,
        }
        let mut map = serde_json::Map::new();
        map.insert("count".into(), serde_json::json!(300));
        let refused = parse_params::<Bounded>(Params::Map(map), "expected {count}").unwrap_err();
        assert_eq!(refused.code, ErrorCode::InvalidParams);
        assert!(
            refused
                .message
                .starts_with("expected {count}: invalid value: integer `300`"),
            "{}",
            refused.message
        );
        let missing = parse_params::<Bounded>(Params::None, "expected {count}").unwrap_err();
        assert_eq!(missing.message, "expected {count}: missing field `count`");
    }

    #[test]
    fn a_first_request_that_names_an_upgrade_takes_the_connection_over() {
        let (socket, _, stop) = serving("upgrade");
        let mut stream = StdUnixStream::connect(&socket).unwrap();
        // The client may write on before the answer; nothing it sent is lost.
        write!(
            stream,
            "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"shout.open\",\"params\":{{\"who\":\"me\"}}}}\nhello\n"
        )
        .unwrap();
        let mut lines = BufReader::new(stream.try_clone().unwrap()).lines();
        let opened: Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
        assert_eq!(
            opened,
            serde_json::json!({ "jsonrpc": "2.0", "id": 5, "result": { "who": "me" } })
        );
        assert_eq!(lines.next().unwrap().unwrap(), "quick=Ok(Bool(false))");
        assert_eq!(lines.next().unwrap().unwrap(), "HELLO");
        writeln!(stream, "{{\"method\":\"quick\"}}").unwrap();
        assert_eq!(
            lines.next().unwrap().unwrap(),
            "{\"METHOD\":\"QUICK\"}",
            "no longer axod's requests"
        );
        stop.stop();
    }

    #[test]
    fn an_upgrade_named_later_is_an_ordinary_request() {
        let (socket, _, stop) = serving("not-first");
        let mut stream = StdUnixStream::connect(&socket).unwrap();
        send(&mut stream, "quick");
        send(&mut stream, "shout.open");
        let mut lines = BufReader::new(stream.try_clone().unwrap()).lines();
        // Answers come as they finish, in any order.
        let mut answers: Vec<Value> = (0..2)
            .map(|_| serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap())
            .collect();
        answers.sort_by_key(|answer| answer.get("error").is_some());
        assert_eq!(answers[0]["result"], false);
        assert_eq!(answers[1]["error"]["code"], -32601, "{}", answers[1]);
        stop.stop();
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
        stop.stop();
    }

    #[test]
    fn a_method_for_one_caller_refuses_others_before_reading_their_parameters() {
        let mut handler = IoHandler::new();
        let ran = Arc::new(AtomicBool::new(false));
        let running = Arc::clone(&ran);
        handler.add_typed_only(
            Only {
                caller: Caller::Signed(Signer::AxoApp),
                code: -32099,
                message: "only Axo.app",
            },
            "only",
            "expected {answer}",
            move |_: serde_json::Map<String, Value>| {
                running.store(true, Ordering::Relaxed);
                std::future::ready(Ok(true))
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
        stop.stop();
    }
}
