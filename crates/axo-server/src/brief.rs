//! `axo.session.brief`: what a Session's agent can do through Axo, for pi-axo to put in its
//! system prompt (`axo_mcp::brief`).

use std::sync::Arc;
use std::time::Duration;

use axo_ipc::{Extension, TypedMethods};
use axo_mcp::brief::{Account, AccountApps, Reach, brief};
use axo_protocol::rpc::{self, method};
use axo_relay::{HostLinkStore, Priority, RelayChannel};
use jsonrpc_core::IoHandler;
use serde_json::json;

/// Listing the account's apps may not hold up an agent's first turn for long. Past this the
/// brief says the account does not answer, and pi-axo asks again after the turn.
const ACCOUNT_TIMEOUT: Duration = Duration::from_secs(3);

/// The brief, with what it needs to reach the account; without a relay, there is no account in it.
pub(crate) struct Brief {
    account: Option<AccountRoute>,
}

/// Where the brief learns of the account: whether this Mac is linked, and the relay's channel
/// to ask the account what it reaches.
#[derive(Clone)]
pub(crate) struct AccountRoute {
    pub(crate) links: Arc<dyn HostLinkStore>,
    pub(crate) channel: Arc<RelayChannel>,
}

impl Brief {
    pub(crate) fn new(account: Option<AccountRoute>) -> Self {
        Self { account }
    }
}

impl Extension for Brief {
    fn name(&self) -> &'static str {
        "brief"
    }

    fn register(&self, methods: &mut IoHandler) {
        let route = self.account.clone();
        methods.add_typed(
            method::SESSION_BRIEF,
            "expected {sessionId}",
            move |request: rpc::SessionBriefRequest| {
                let route = route.clone();
                async move {
                    let account = account(route.as_ref(), request.session_id).await;
                    Ok(rpc::SessionBrief {
                        brief: brief(&Reach {
                            computer: axo_computer::AVAILABLE,
                            account,
                        }),
                    })
                }
            },
        );
    }
}

/// What the account reaches now, as `axo.apps.list` says, asked for as the Session's agent. A Mac
/// that is not linked has no account to mention.
async fn account(route: Option<&AccountRoute>, session: axo_protocol::SessionId) -> Account {
    let Some(route) = route else {
        return Account::Absent;
    };
    match route.links.load_link().await {
        Ok(link) if link.account().is_none() => return Account::Absent,
        Ok(_) => {}
        Err(error) => log::info!("event=brief.link_unread error={error}"),
    }
    let listed = route
        .channel
        .request(
            method::APPS_LIST,
            json!({ "sessionId": session }),
            Priority::Control,
            ACCOUNT_TIMEOUT,
        )
        .await;
    match listed {
        Ok(listed) => AccountApps::parse(&listed).map_or(Account::Unreachable, Account::Listed),
        Err(error) => {
            log::info!("event=brief.account_unreachable error={error:?}");
            Account::Unreachable
        }
    }
}
