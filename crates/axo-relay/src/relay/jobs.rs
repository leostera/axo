//! Requests that outlive a single reply: shell commands, computer use, prompts, and sign-ins.
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
static BASH_JOBS: JobLimit = JobLimit::new(16, "too many commands running on this Mac");
/// Computer calls: they wait on the person, and drive one screen.
static COMPUTER_JOBS: JobLimit = JobLimit::new(4, "too many computer calls running on this Mac");
/// Sign-ins: each holds a redirect port, and a service registers few.
static SIGN_INS: JobLimit =
    JobLimit::new(2, "another sign-in is waiting on this Mac; finish it first");

/// Starts a `bash` request as a task of its own; its reply goes back on this socket only.
pub(super) fn start_bash(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::bash::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let place = match BASH_JOBS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    tokio::spawn(async move {
        log::info!("event=apps.bash_started call={}", params.call_id);
        let outcome = crate::bash::run(&params)
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
        let outcome = match sessions.remote_computer(params).await {
            // Its images are uploaded over blocking HTTPS.
            Ok(result) => Ok(crate::blocking(move || {
                crate::computer::to_account(result, assets.as_ref(), &tool)
            })
            .await),
            Err(error) => Err(error),
        };
        drop(place);
        log::info!(
            "event=apps.computer_finished call={call_id} outcome={}",
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}

/// Gives a prompt to the host on a task of its own: it is answered once its attachments are
/// fetched and Pi has it in its log, which may take seconds, so it must not hold up the calls
/// answered in order. The reply goes back on this socket only.
pub(super) fn start_prompt(request: Value, context: &RelaySessionContext) {
    let replies = context.replies.clone();
    let sessions = Arc::clone(&context.sessions);
    tokio::spawn(async move {
        if let Some(reply) = super::forward::answer(&request, sessions.as_ref()).await {
            match serde_json::to_string(&reply) {
                Ok(text) => replies.send(text),
                Err(error) => log::warn!("event=relay.reply_unserializable error={error}"),
            }
        }
    });
}

/// Starts a loopback sign-in; its reply goes back on this socket only.
pub(super) fn start_sign_in(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::signin::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let place = match SIGN_INS.admit() {
        Ok(place) => place,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    let replies = context.replies.clone();
    tokio::spawn(async move {
        // The code and the URL's parameters are never logged.
        log::info!("event=apps.sign_in_started call={}", params.call_id);
        let call_id = params.call_id.clone();
        // The loopback listener is a blocking one for now.
        let outcome = crate::blocking(move || {
            crate::signin::run(&params, axo_signin::open_in_browser)
                .map(|result| serde_json::to_value(result).expect("a sign-in result serializes"))
        })
        .await;
        drop(place);
        log::info!(
            "event=apps.sign_in_finished call={call_id} outcome={}",
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}
