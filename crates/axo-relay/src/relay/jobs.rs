//! Requests that outlive a single reply: shell commands, prompts, and sign-ins.
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
        .name("axo-apps-bash".to_owned())
        .spawn(move || {
            log::info!("event=apps.bash_started call={}", params.call_id);
            let outcome = crate::bash::run(&params)
                .map(|result| serde_json::to_value(result).expect("a bash result serializes"));
            BASH_JOBS.fetch_sub(1, Ordering::SeqCst);
            log::info!(
                "event=apps.bash_finished call={} outcome={}",
                params.call_id,
                if outcome.is_ok() { "ok" } else { "error" }
            );
            replies.reply(&id, outcome);
        });
    if spawned.is_err() {
        BASH_JOBS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Computer calls running at once on one Mac: they wait on the person, and drive one screen.
const MAX_COMPUTER_JOBS: usize = 4;
static COMPUTER_JOBS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Starts a computer call from another Mac on a thread of its own: the host runs it (asking the
/// person if it must), then its images go to the account's assets. Replies on this socket only.
pub(super) fn start_computer(id: Value, params: &Value, context: &RelaySessionContext<'_>) {
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
    let sessions = Arc::clone(context.sessions);
    let assets = context.assets.clone();
    let spawned = thread::Builder::new()
        .name("axo-apps-computer".to_owned())
        .spawn(move || {
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
    if spawned.is_err() {
        COMPUTER_JOBS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Prompts on their way to Pi on one Mac at once; more are refused until one ends.
const MAX_PROMPTS: usize = 16;
static PROMPTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Fetches a prompt's attachments, all of them or none (RFD0030), then gives it to Pi; the reply
/// goes back on this socket once Pi has written it to its log (RFD0033), or with why it was
/// refused.
pub(super) fn start_prompt(id: Value, params: &Value, context: &RelaySessionContext<'_>) {
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
    if request.text.is_empty() && request.attachments.is_empty() {
        return context
            .replies
            .reply(&id, Err((-32602, "Invalid params".into())));
    }
    let source = context.assets.clone();
    if source.is_none() && !request.attachments.is_empty() {
        return context.replies.reply(
            &id,
            Err((-32003, "this Mac can't fetch attachments".into())),
        );
    }
    if PROMPTS.fetch_add(1, Ordering::SeqCst) >= MAX_PROMPTS {
        PROMPTS.fetch_sub(1, Ordering::SeqCst);
        return context.replies.reply(
            &id,
            Err((
                -32006,
                "too many prompts are on their way on this Mac".into(),
            )),
        );
    }
    let replies = context.replies.clone();
    let sessions = Arc::clone(context.sessions);
    let spawned = thread::Builder::new()
        .name("axo-prompt".to_owned())
        .spawn(move || {
            let fetched = match &source {
                Some(source) if !request.attachments.is_empty() => {
                    crate::assets::fetch_all(source, &request.attachments)
                }
                _ => Ok(Vec::new()),
            };
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
                        request.delivery,
                    )
                    .map(|()| serde_json::json!({ "accepted": true }))
                    .map_err(|error| {
                        let (code, message) = map_operation_error(error);
                        (code, message.to_owned())
                    }),
            };
            PROMPTS.fetch_sub(1, Ordering::SeqCst);
            replies.reply(&id, outcome);
        });
    if spawned.is_err() {
        PROMPTS.fetch_sub(1, Ordering::SeqCst);
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
        .name("axo-apps-sign-in".to_owned())
        .spawn(move || {
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
    if spawned.is_err() {
        SIGN_INS.fetch_sub(1, Ordering::SeqCst);
    }
}
