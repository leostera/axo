//! `axo.session.events.stream`: axod pushes events to a client on their own connection
//! (RFD0037, step 4).
//!
//! The stream is the connection's first request, as `axo.mcp.open` is. It subscribes, answers
//! with the subscription, then writes every batch as an `axo.session.events` notification the
//! moment there is one. The subscription lives exactly as long as the connection: when the
//! client closes it, the subscription goes. A subscription that fell behind gets its lag marker
//! and the stream ends; the client subscribes again and relists, as it would on a lagged poll.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use axo_ipc::Upgraded;
use axo_protocol::{Event, rpc};
use jsonrpc_core::{Error as RpcError, ErrorCode};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::SessionManager;
use super::events::SharedEvent;

/// The method that opens a stream.
pub const STREAM: &str = "axo.session.events.stream";
/// Each batch, as a notification.
pub const EVENTS: &str = "axo.session.events";

/// How long one wait for events lasts before it is simply waited again: not a poll, nothing is
/// sent when it ends empty.
const WAIT: Duration = Duration::from_secs(3600);

/// Serves one stream until the client closes its connection or the subscription lags.
pub async fn serve(sessions: Arc<SessionManager>, mut upgraded: Upgraded) {
    let request: rpc::Subscribe = match serde_json::from_value(upgraded.params.take()) {
        Ok(request) => request,
        Err(_) => {
            let _ = upgraded
                .answer(Err(RpcError {
                    code: ErrorCode::InvalidParams,
                    message: "expected {sessionId?, includeTerminalOutput?}".into(),
                    data: None,
                }))
                .await;
            return;
        }
    };
    let subscribing = Arc::clone(&sessions);
    let subscribed = tokio::task::spawn_blocking(move || {
        subscribing.subscribe(request.session_id, request.include_terminal_output)
    })
    .await
    .unwrap_or_else(|error| Err(io::Error::other(error)));
    let subscription_id = match subscribed {
        Ok(id) => id,
        Err(error) => {
            let _ = upgraded
                .answer(Err(RpcError {
                    code: if error.kind() == io::ErrorKind::NotFound {
                        ErrorCode::InvalidParams
                    } else {
                        ErrorCode::InternalError
                    },
                    message: error.to_string(),
                    data: None,
                }))
                .await;
            return;
        }
    };
    if upgraded
        .answer(Ok(json!({ "subscriptionId": subscription_id })))
        .await
        .is_ok()
    {
        if let Err(error) = stream(&sessions, &subscription_id, &mut upgraded).await {
            log::debug!("event=session.event_stream_ended reason={error}");
        }
    }
    if let Err(error) = sessions.unsubscribe(&subscription_id) {
        log::debug!("event=session.event_stream_unsubscribe_failed reason={error}");
    }
}

async fn stream(
    sessions: &SessionManager,
    subscription_id: &str,
    upgraded: &mut Upgraded,
) -> io::Result<()> {
    let mut ignored = [0_u8; 1024];
    loop {
        let events = tokio::select! {
            events = sessions.next_events_async(subscription_id, WAIT, rpc::MAX_EVENTS_PER_BATCH) => events?,
            // The client says nothing more on this connection; its closing ends the stream.
            read = upgraded.reader.read(&mut ignored) => match read? {
                0 => return Ok(()),
                _ => continue,
            },
        };
        if events.is_empty() {
            continue;
        }
        let lagged = events
            .iter()
            .any(|event| matches!(**event, Event::SubscriptionLagged));
        let events: Vec<SharedEvent> = events.into_iter().map(SharedEvent).collect();
        let mut line = serde_json::to_string(&json!({
            "jsonrpc": "2.0",
            "method": EVENTS,
            "params": { "events": events },
        }))
        .map_err(io::Error::other)?;
        line.push('\n');
        upgraded.writer.write_all(line.as_bytes()).await?;
        upgraded.writer.flush().await?;
        if lagged {
            return Ok(());
        }
    }
}
