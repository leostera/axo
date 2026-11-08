//! Requests that outlive a single reply: shell commands, prompts, and sign-ins.
//! Each runs on tokio's blocking pool, bounded per Mac, and replies on the socket it came from.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde_json::Value;

use super::session::RelaySessionContext;

/// Commands running at once on one Mac; more are refused until one ends.
const MAX_BASH_JOBS: usize = 16;
static BASH_JOBS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Starts a `bash` request as a task of its own; its reply goes back on this socket only.
pub(super) fn start_bash(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::bash::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    if BASH_JOBS.fetch_add(1, Ordering::SeqCst) >= MAX_BASH_JOBS {
        BASH_JOBS.fetch_sub(1, Ordering::SeqCst);
        return context.replies.reply(
            &id,
            Err((-32006, "too many commands running on this Mac".into())),
        );
    }
    let replies = context.replies.clone();
    tokio::spawn(async move {
        log::info!("event=apps.bash_started call={}", params.call_id);
        let outcome = crate::bash::run(&params)
            .await
            .map(|result| serde_json::to_value(result).expect("a bash result serializes"));
        BASH_JOBS.fetch_sub(1, Ordering::SeqCst);
        log::info!(
            "event=apps.bash_finished call={} outcome={}",
            params.call_id,
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}

/// Computer calls running at once on one Mac: they wait on the person, and drive one screen.
const MAX_COMPUTER_JOBS: usize = 4;
static COMPUTER_JOBS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Starts a computer call from another Mac on the blocking pool: the host runs it (asking the
/// person if it must), then its images go to the account's assets. Replies on this socket only.
pub(super) fn start_computer(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::computer::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    if COMPUTER_JOBS.fetch_add(1, Ordering::SeqCst) >= MAX_COMPUTER_JOBS {
        COMPUTER_JOBS.fetch_sub(1, Ordering::SeqCst);
        return context.replies.reply(
            &id,
            Err((-32006, "too many computer calls running on this Mac".into())),
        );
    }
    let replies = context.replies.clone();
    let sessions = Arc::clone(&context.sessions);
    let assets = context.assets.clone();
    tokio::task::spawn_blocking(move || {
        log::info!(
            "event=apps.computer_started call={} tool={}",
            params.call_id,
            params.tool
        );
        let outcome = sessions
            .remote_computer(&params)
            .map(|result| crate::computer::to_account(result, assets.as_ref(), &params.tool));
        COMPUTER_JOBS.fetch_sub(1, Ordering::SeqCst);
        log::info!(
            "event=apps.computer_finished call={} outcome={}",
            params.call_id,
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
    tokio::task::spawn_blocking(move || {
        let reply = super::forward::answer(&request, |request| sessions.answer_remote(request));
        if let Some(reply) = reply {
            match serde_json::to_string(&reply) {
                Ok(text) => replies.send(text),
                Err(error) => log::warn!("event=relay.reply_unserializable error={error}"),
            }
        }
    });
}

/// Sign-ins waiting on one Mac at once: each holds a redirect port, and a service registers few.
const MAX_SIGN_INS: usize = 2;
static SIGN_INS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Starts a loopback sign-in on the blocking pool; its reply goes back on this socket only.
pub(super) fn start_sign_in(id: Value, params: &Value, context: &RelaySessionContext) {
    let params = match crate::signin::parse(params, &context.account_id) {
        Ok(params) => params,
        Err(error) => return context.replies.reply(&id, Err(error)),
    };
    if SIGN_INS.fetch_add(1, Ordering::SeqCst) >= MAX_SIGN_INS {
        SIGN_INS.fetch_sub(1, Ordering::SeqCst);
        return context.replies.reply(
            &id,
            Err((
                -32006,
                "another sign-in is waiting on this Mac; finish it first".into(),
            )),
        );
    }
    let replies = context.replies.clone();
    tokio::task::spawn_blocking(move || {
        // The code and the URL's parameters are never logged.
        log::info!("event=apps.sign_in_started call={}", params.call_id);
        let outcome = crate::signin::run(&params, axo_signin::open_in_browser)
            .map(|result| serde_json::to_value(result).expect("a sign-in result serializes"));
        SIGN_INS.fetch_sub(1, Ordering::SeqCst);
        log::info!(
            "event=apps.sign_in_finished call={} outcome={}",
            params.call_id,
            if outcome.is_ok() { "ok" } else { "error" }
        );
        replies.reply(&id, outcome);
    });
}
