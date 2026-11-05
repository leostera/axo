//! Requests that outlive a single reply: shell commands, prompts with attachments, and sign-ins.
//! Each runs on its own thread, bounded per Mac, and replies on the socket it came from.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread;

use serde_json::Value;

use super::dispatch::map_operation_error;
use super::session::RelaySessionContext;
use super::wire::PromptParams;

/// Commands running at once on one Mac; more are refused until one ends.
const MAX_BASH_JOBS: usize = 16;
static BASH_JOBS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Starts a `bash` request on a thread of its own; its reply goes back on this socket only.
pub(super) fn start_bash(id: Value, params: &Value, context: &RelaySessionContext<'_>) {
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
    let spawned = thread::Builder::new()
        .name("axo-connections-bash".to_owned())
        .spawn(move || {
            log::info!("event=connections.bash_started call={}", params.call_id);
            let outcome = crate::bash::run(&params)
                .map(|result| serde_json::to_value(result).expect("a bash result serializes"));
            BASH_JOBS.fetch_sub(1, Ordering::SeqCst);
            log::info!(
                "event=connections.bash_finished call={} outcome={}",
                params.call_id,
                if outcome.is_ok() { "ok" } else { "error" }
            );
            replies.reply(&id, outcome);
        });
    if spawned.is_err() {
        BASH_JOBS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Prompts fetching their attachments on one Mac at once; more are refused until one ends.
const MAX_ATTACHMENT_FETCHES: usize = 4;
static ATTACHMENT_FETCHES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Fetches a prompt's attachments, all of them or none, then gives it to Pi; the reply goes back
/// on this socket once Pi has it, or with why it was refused (RFD0030).
pub(super) fn start_prompt_with_attachments(
    id: Value,
    params: &Value,
    context: &RelaySessionContext<'_>,
) {
    let request = match serde_json::from_value::<PromptParams>(params.clone()) {
        Ok(request) => request,
        Err(_) => {
            return context
                .replies
                .reply(&id, Err((-32602, "Invalid params".into())));
        }
    };
    if request.target.host_id != context.host_id
        || request.target.host_generation != context.host_generation
    {
        return context
            .replies
            .reply(&id, Err((-32002, "Stale host".into())));
    }
    if request.text.len() > 16_000 {
        return context
            .replies
            .reply(&id, Err((-32602, "Invalid params".into())));
    }
    let Some(source) = context.assets.clone() else {
        return context.replies.reply(
            &id,
            Err((-32003, "this Mac can't fetch attachments".into())),
        );
    };
    if ATTACHMENT_FETCHES.fetch_add(1, Ordering::SeqCst) >= MAX_ATTACHMENT_FETCHES {
        ATTACHMENT_FETCHES.fetch_sub(1, Ordering::SeqCst);
        return context.replies.reply(
            &id,
            Err((
                -32006,
                "too many prompts are fetching attachments on this Mac".into(),
            )),
        );
    }
    let replies = context.replies.clone();
    let sessions = Arc::clone(context.sessions);
    let spawned = thread::Builder::new()
        .name("axo-prompt-attachments".to_owned())
        .spawn(move || {
            let fetched = crate::assets::fetch_all(&source, &request.attachments);
            ATTACHMENT_FETCHES.fetch_sub(1, Ordering::SeqCst);
            let outcome = match fetched {
                Err(error) => Err((
                    -32010,
                    match error {
                        crate::assets::FetchError::NotFound => {
                            "an attachment is no longer in the account"
                        }
                        crate::assets::FetchError::Mismatch => {
                            "an attachment did not match its name"
                        }
                        crate::assets::FetchError::Failed(_) => {
                            "an attachment could not be fetched"
                        }
                    }
                    .to_owned(),
                )),
                Ok(fetched) => sessions
                    .remote_prompt_pi(
                        request.session_id,
                        &request.text,
                        request.command_id.as_ref(),
                        &fetched,
                    )
                    .map(|()| serde_json::json!({ "accepted": true }))
                    .map_err(|error| {
                        let (code, message) = map_operation_error(error);
                        (code, message.to_owned())
                    }),
            };
            replies.reply(&id, outcome);
        });
    if spawned.is_err() {
        ATTACHMENT_FETCHES.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Sign-ins waiting on one Mac at once: each holds a redirect port, and a service registers few.
const MAX_SIGN_INS: usize = 2;
static SIGN_INS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Starts a loopback sign-in on a thread of its own; its reply goes back on this socket only.
pub(super) fn start_sign_in(id: Value, params: &Value, context: &RelaySessionContext<'_>) {
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
    let spawned = thread::Builder::new()
        .name("axo-connections-sign-in".to_owned())
        .spawn(move || {
            // The code and the URL's parameters are never logged.
            log::info!("event=connections.sign_in_started call={}", params.call_id);
            let outcome = crate::signin::run(&params, axo_signin::open_in_browser)
                .map(|result| serde_json::to_value(result).expect("a sign-in result serializes"));
            SIGN_INS.fetch_sub(1, Ordering::SeqCst);
            log::info!(
                "event=connections.sign_in_finished call={} outcome={}",
                params.call_id,
                if outcome.is_ok() { "ok" } else { "error" }
            );
            replies.reply(&id, outcome);
        });
    if spawned.is_err() {
        SIGN_INS.fetch_sub(1, Ordering::SeqCst);
    }
}
