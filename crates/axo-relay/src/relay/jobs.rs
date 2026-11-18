//! Requests that outlive a single reply: shell commands, computer use, inference and sign-ins.
//! Each runs as a task of its own, bounded per Mac, and replies on the socket it came from.

use std::sync::Arc;

use axo_protocol::rpc::MethodError;
use axo_protocol::rpc::error_code::BUSY;
use serde_json::Value;
use tokio::sync::{Semaphore, SemaphorePermit};

use super::session::RelaySessionContext;

/// How many of one kind of job run at once on this Mac; more are refused until one ends.
struct JobLimit {
    running: Semaphore,
    /// What a refused caller is told.
    refusal: &'static str,
}

impl JobLimit {
    const fn new(jobs: usize, refusal: &'static str) -> Self {
        Self {
            running: Semaphore::const_new(jobs),
            refusal,
        }
    }

    /// A place for one more job, held until it ends; refused when every place is taken.
    fn admit(&'static self) -> Result<SemaphorePermit<'static>, MethodError> {
        self.running
            .try_acquire()
            .map_err(|_| MethodError::new(BUSY, self.refusal))
    }
}

/// Commands: each holds a process group.
static AI_JOBS: JobLimit = JobLimit::new(1, "another ai operation is running on this Mac");

static BASH_JOBS: JobLimit = JobLimit::new(16, "too many commands running on this Mac");
/// Computer calls: they wait on the person, and drive one screen.
static COMPUTER_JOBS: JobLimit = JobLimit::new(4, "too many computer calls running on this Mac");
/// Sign-ins: each holds a redirect port, and a service registers few.
static SIGN_INS: JobLimit =
    JobLimit::new(2, "another sign-in is waiting on this Mac; finish it first");

/// Inference and model installation never hold up the relay's ordered host requests.
pub(super) fn start_ai(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::ai::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let mut job = match context.jobs.start(&params.call_id) {
        Ok(job) => job,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let place = match AI_JOBS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    let sessions = Arc::clone(&context.sessions);
    tokio::spawn(async move {
        let cancel = axo_ipc::Stop::default();
        let operation = sessions.remote_ai(params, cancel.clone());
        tokio::pin!(operation);
        let outcome = tokio::select! {
            biased;
            _ = job.cancelled() => {
                cancel.stop();
                // Keep the future, admission slot and job until native retirement/reaping ends.
                operation.await
            },
            outcome = &mut operation => outcome,
        };
        drop(place);
        replies.reply(&id, outcome);
    });
}

/// Starts a `bash` request as a task of its own; its reply goes back on this socket only.
pub(super) fn start_bash(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::bash::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let mut job = match context.jobs.start(&params.call_id) {
        Ok(job) => job,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let place = match BASH_JOBS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    tokio::spawn(async move {
        log::info!("event=apps.bash_started call={}", params.call_id);
        let outcome = crate::bash::run_cancellable(&params, job.cancelled())
            .await
            .map(|result| serde_json::to_value(result).expect("a bash result serializes"));
        drop(place);
        log::info!(
            "event=apps.bash_finished call={} outcome={}",
            params.call_id,
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}

/// Starts a computer call from another Mac: the host runs it (asking the person if it must),
/// then its images go to the account's assets. Replies on this socket only.
pub(super) fn start_computer(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::computer::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let mut job = match context.jobs.start(&params.call_id) {
        Ok(job) => job,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let place = match COMPUTER_JOBS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    let sessions = Arc::clone(&context.sessions);
    let assets = context.assets.clone();
    tokio::spawn(async move {
        let call_id = params.call_id.clone();
        let tool = params.tool.clone();
        log::info!("event=apps.computer_started call={call_id} tool={tool}");
        let action = async {
            match sessions.remote_computer(params).await {
                Ok(result) => Ok(crate::computer::to_account(result, assets.as_ref(), &tool).await),
                Err(error) => Err(error),
            }
        };
        let outcome = tokio::select! {
            biased;
            _ = job.cancelled() => Err(MethodError::new(-32004, "Computer call cancelled; the action may have run")),
            outcome = action => outcome,
        };
        drop(place);
        log::info!(
            "event=apps.computer_finished call={call_id} outcome={}",
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}

/// Asks the person whether an app call may run (RFD0070): the host asks in the calling Session.
/// Replies `{ outcome: "accept" }` only on their accept, on this socket only.
pub(super) fn start_consent(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::consent::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let mut job = match context.jobs.start(&params.call_id) {
        Ok(job) => job,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    // Waiting on the person, as a computer call does.
    let place = match COMPUTER_JOBS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    let sessions = Arc::clone(&context.sessions);
    tokio::spawn(async move {
        let call_id = params.call_id.clone();
        log::info!("event=apps.consent_asked call={call_id}");
        let outcome = tokio::select! {
            biased;
            _ = job.cancelled() => Err(MethodError::new(-32004, "Cancelled before the person answered")),
            outcome = sessions.remote_consent(params) => outcome,
        };
        drop(place);
        log::info!(
            "event=apps.consent_answered call={call_id} outcome={}",
            if outcome.is_ok() { "accept" } else { "refused" }
        );
        replies.reply(&id, outcome.map(|()| serde_json::json!({ "outcome": "accept" })));
    });
}

/// A cancellation is scoped to the linked account and this relay session's own call IDs.
/// Bash/AI retain ownership through cleanup. A receipt never proves rollback of an action;
/// non-interruptible computer work may already have been dispatched.
pub(super) fn start_cancel(id: Value, params: &Value, context: &RelaySessionContext) {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Cancel {
        account_id: String,
        call_id: String,
    }
    let parsed = serde_json::from_value::<Cancel>(params.clone());
    let request = match parsed {
        Ok(p)
            if p.account_id == context.account_id
                && !p.call_id.is_empty()
                && p.call_id.len() <= 64 =>
        {
            p
        }
        _ => {
            return context.replies.reply(
                &id,
                Err(MethodError::new(
                    -32602,
                    "invalid account or cancellation call ID",
                )),
            );
        }
    };
    let jobs = Arc::clone(&context.jobs);
    let replies = context.replies.clone();
    tokio::spawn(async move {
        let requested = jobs.cancel(&request.call_id).await;
        replies.reply(&id, Ok(serde_json::json!({ "cancelRequested": requested })));
    });
}

/// Starts a loopback sign-in; its reply goes back on this socket only. Like every job it belongs
/// to the socket: a cancel or the socket's end gives it up and frees its redirect port.
pub(super) fn start_sign_in(id: Value, params: &Value, context: &RelaySessionContext) {
    start_sign_in_with(id, params, context, axo_signin::open_in_browser);
}

/// [`start_sign_in`], opening the sign-in page with `open_browser`.
fn start_sign_in_with<F>(
    id: Value,
    params: &Value,
    context: &RelaySessionContext,
    open_browser: impl FnOnce(String) -> F + Send + 'static,
) where
    F: std::future::Future<Output = std::io::Result<()>> + Send + 'static,
{
    let request = match crate::signin::parse(params, &context.account_id) {
        Ok(request) => request,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let mut job = match context.jobs.start(&request.call_id) {
        Ok(job) => job,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let place = match SIGN_INS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    tokio::spawn(async move {
        // The code and the URL's parameters are never logged.
        let call_id = &request.call_id;
        log::info!("event=apps.sign_in_started call={call_id}");
        let outcome = tokio::select! {
            biased;
            _ = job.cancelled() => Err(MethodError::new(-32004, "Sign-in cancelled")),
            outcome = crate::signin::run(&request, open_browser) => outcome,
        };
        drop(place);
        log::info!(
            "event=apps.sign_in_finished call={call_id} outcome={}",
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use serde_json::json;

    use super::super::test_support::{ACCOUNT, RecordingHost, context, sent};
    use super::*;

    fn free_port() -> u16 {
        std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port()
    }

    fn sign_in(call_id: &str, port: u16) -> Value {
        json!({
            "accountId": ACCOUNT,
            "callId": call_id,
            "authorizeUrl": "https://example.com/oauth/authorize?state=0123456789abcdef",
            "ports": [port],
            "path": "/callback",
            "state": "0123456789abcdef",
            "timeoutMs": 600_000,
        })
    }

    /// The port is free again: nothing answers on it.
    async fn released(port: u16) {
        for _ in 0..100 {
            if tokio::net::TcpListener::bind(("127.0.0.1", port))
                .await
                .is_ok()
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("port {port} is still held");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_cancel_or_the_sockets_end_gives_a_sign_in_up_and_frees_its_port() {
        let (context, mut outgoing) = context(RecordingHost::new(|_| Duration::ZERO));
        let (opened, mut browser) = tokio::sync::mpsc::unbounded_channel();

        let port = free_port();
        let opening = opened.clone();
        start_sign_in_with(
            json!(1),
            &sign_in("kraken-1", port),
            &context,
            move |url| async move { opening.send(url).map_err(std::io::Error::other) },
        );
        browser.recv().await.unwrap();
        start_cancel(
            json!(2),
            &json!({ "accountId": ACCOUNT, "callId": "kraken-1" }),
            &context,
        );
        let (first, second) = (sent(&mut outgoing).await, sent(&mut outgoing).await);
        let (cancelled, receipt) = if first["id"] == 1 {
            (first, second)
        } else {
            (second, first)
        };
        assert_eq!(receipt["result"]["cancelRequested"], true, "{receipt}");
        assert_eq!(
            cancelled["error"]["message"], "Sign-in cancelled",
            "{cancelled}"
        );
        released(port).await;

        let port = free_port();
        start_sign_in_with(
            json!(3),
            &sign_in("kraken-2", port),
            &context,
            move |url| async move { opened.send(url).map_err(std::io::Error::other) },
        );
        browser.recv().await.unwrap();
        context.jobs.close();
        assert_eq!(
            sent(&mut outgoing).await["error"]["message"],
            "Sign-in cancelled"
        );
        released(port).await;
    }
}
