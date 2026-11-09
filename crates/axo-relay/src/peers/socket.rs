//! One socket of the follower, on its own task: it reads whole messages into the follower's
//! channel, writes what the follower queues at most `FRAMES_PER_SECOND`, and pings. The
//! follower talks to every socket the same way (RFD0032), whether it is the account's or a
//! Mac's HostDO's.

use std::collections::VecDeque;
use std::io;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::time::Instant;
use tungstenite::Message;

use crate::fragments::Reassembler;
use crate::relay::{RelaySink, RelayStream, receive, send_json};

/// Frames sent per second on one socket, half what the cloud allows a client.
const FRAMES_PER_SECOND: usize = 30;
const PING_INTERVAL: Duration = Duration::from_secs(30);

/// Where a message goes, or came from: the account's socket, or a Mac's HostDO.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) enum Route {
    Account,
    Host(String),
}

/// What a socket hands the follower: a whole message, or why it ended.
pub(super) type Incoming = (Route, io::Result<Value>);

/// The follower's end of one socket. Dropping it ends the socket.
pub(super) struct SocketHandle {
    outgoing: mpsc::UnboundedSender<Value>,
    task: tokio::task::JoinHandle<()>,
}

impl SocketHandle {
    /// Queues a message; it goes out in order, within the rate limit.
    pub(super) fn send(&self, value: Value) -> io::Result<()> {
        self.outgoing
            .send(value)
            .map_err(|_| io::Error::new(io::ErrorKind::ConnectionAborted, "the socket has ended"))
    }
}

impl Drop for SocketHandle {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Starts a socket's task. It ends, saying why on `incoming`, when the socket does.
pub(super) fn spawn(
    route: Route,
    sink: RelaySink,
    stream: RelayStream,
    incoming: mpsc::UnboundedSender<Incoming>,
) -> SocketHandle {
    let (outgoing, queued) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        let ended = run(sink, stream, queued, &incoming, &route).await;
        let error = ended.err().unwrap_or_else(|| {
            io::Error::new(io::ErrorKind::ConnectionAborted, "the socket was closed")
        });
        let _ = incoming.send((route, Err(error)));
    });
    SocketHandle { outgoing, task }
}

async fn run(
    mut sink: RelaySink,
    mut stream: RelayStream,
    mut queued: mpsc::UnboundedReceiver<Value>,
    incoming: &mpsc::UnboundedSender<Incoming>,
    route: &Route,
) -> io::Result<()> {
    let mut reassembler = Reassembler::default();
    let mut sent: VecDeque<Instant> = VecDeque::new();
    let mut ping = tokio::time::interval_at(Instant::now() + PING_INTERVAL, PING_INTERVAL);
    loop {
        tokio::select! {
            _ = ping.tick() => {
                sink.send(Message::Ping(Vec::new().into())).await.map_err(io::Error::other)?;
            }
            value = queued.recv() => {
                let Some(value) = value else {
                    let _ = sink.close().await;
                    return Ok(());
                };
                // The cloud closes a client that sends faster.
                while sent.front().is_some_and(|at| at.elapsed() >= Duration::from_secs(1)) {
                    sent.pop_front();
                }
                if sent.len() >= FRAMES_PER_SECOND {
                    let first = *sent.front().expect("full");
                    tokio::time::sleep_until(first + Duration::from_secs(1)).await;
                    sent.pop_front();
                }
                sent.push_back(Instant::now());
                send_json(&mut sink, &value).await?;
            }
            message = stream.next() => {
                let Some(text) = receive(&mut sink, message, &mut reassembler).await? else {
                    continue;
                };
                let value: Value = serde_json::from_str(&text).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidData, "the cloud sent invalid JSON")
                })?;
                if incoming.send((route.clone(), Ok(value))).is_err() {
                    return Ok(());
                }
            }
        }
    }
}
