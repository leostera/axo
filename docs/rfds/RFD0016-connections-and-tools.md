# RFD0016 - Axo: connections and tools

- Feature Name: `axo-connections-and-tools`
- Status: Implemented, as apps (see Current state); the sections marked _(open)_ were never written
- Author: leostera
- Start Date: 2026-10-29
- Updated: 2026-11-10 (reconciled with the code)
- Document Type: Proposal
- Amended By: [RFD0028](RFD0028-computer-use.md) (Macs as an argument)

> **Renamed (2026-11-07, 0.23):** connections are now **apps** everywhere: tools `apps_*`, methods `axo.apps.*`, routes `/api/v1/account/apps`, code in `src/apps`, specs in `specs/apps`. This document keeps the old word. The OAuth paths `/api/v1/connections/oauth/*` and the `third_party_connections` table keep theirs, because provider settings and stored data hold them.

## Current state

Checked against `main` on 2026-11-10. The Goals and the Reference-level explanation describe what runs, under the new names:

- **Tools and methods.** `connections_list`, `_add`, `_remove`, `_search`, `_execute` and `_log` are `apps_list`, `apps_add`, `apps_remove`, `apps_search`, `apps_run` and `apps_log` (`crates/axo-mcp/src/lib.rs`). On the relay they are `axo.apps.list`, `.add`, `.remove`, `.search`, `.run` and `.log`; the Worker sends a Mac `axo.apps.bash`, `axo.apps.signIn` and `axo.apps.computer` ([RFD0028](RFD0028-computer-use.md)).
- **Where it runs.** Every app call, grant and the call log are in the account's `AxoAccountManager` (`packages/axo-api-worker/src/apps/account.ts`). Where this RFD and the code comments in `packages/axo-apps` say "the gateway", they mean that object: [RFD0020](RFD0020-account-gateway.md)'s separate gateway is not on `main`.
- **Apps.** The 22 apps in the table are those in `packages/axo-apps/src/catalog.ts`, with the tools listed, except that UniFi also has `list_clients` and `get_traffic`.
- **Limits** are `APPS_LIMITS` in `packages/axo-api/src/apps.ts`, the values in the Limits table. Fragments are as described: 64 KiB frames, messages up to 16 MiB, 4 partial messages per socket, 60 seconds (`crates/axo-relay/src/fragments.rs`).
- **Specs** moved with the rename: `specs/apps/apps.ts` (was `specs/connections/connections.ts`), `specs/apps/connection-sign-in.ts` and `specs/apps/tool-lists.ts`.
- **The Mac's socket** ends at `axo.leostera.dev/api/v1/accounts/:account/hosts/:host/daemon`. There is no `api.axo.leostera.dev`.

Motivation, Rationale and alternatives, Prior art, Unresolved questions and Future possibilities were left _(open)_ while this was a draft, and stay unwritten. What the Non-goals name as future possibilities (host MCP servers, an MCP endpoint for clients outside Axo, approvals) is not built.

## Summary

_(open)_ Axo gains connections: credentials and tool sources an Axo account adds once and its agents use from anywhere. The account's cloud Durable Object holds connections to remote services, its paired Macs contribute tools only they can provide, and agents reach both through one tool catalog.

## Motivation

_(open)_

## Goals

- An account adds a third-party connection (a remote MCP server) by URL once and its agents use that server's tools afterwards, with Axo running the upstream OAuth flow and keeping the grant.
- Each paired Mac is a host connection with one tool, `bash`, that any Session of the same account can call while that Mac is online, including Sessions on other Macs. Local apps are reached through their command-line interfaces; Axo does not need to know about them.
- Agents in Axo Sessions reach every connection through the existing `axod mcp` server (RFD0015).
- Axo provides apps itself that an account signs in to, with one or more provider accounts each, and its agents reach as `codemode.apps.<app>.*`: Google's (Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, Tasks, Meet, Google Cloud), GitHub, Spotify and Withings with OAuth, Hetzner, Octopus Energy, Wise, Telegram and Discord bots, Kraken and UniFi with a token the person pastes (Kraken's also signed in on the person's Mac), ChatGPT with a code the person enters at OpenAI, and 1Password through its command line on the person's Macs. Each asks for everything its own service allows, and can call any endpoint of its API. An app with a well-used official SDK that runs on Workers calls through it: GitHub through Octokit, Telegram through grammY, Discord through discord.js's REST client. The SDK is given the gateway's `fetch` (`ProviderApi.fetch`), which puts the credential on, keeps calls to the app's hosts and reports a 401 or a write that may have run as any call does; the gateway finds its own errors inside the SDK's. [docs/apps/catalog.md](../apps/catalog.md) is the plan for the rest.
- An agent finds what the account reaches without searching: the account's connections, and how a script calls each, are in the descriptions of the tools that reach them.

## Non-goals

- Sharing connections, credentials or tools between Axo accounts.
- Direct API providers that an account adds itself (REST APIs reached with API keys or OAuth without an MCP server), and tools authored by users. Both are future possibilities. The apps Axo provides (below) are the one exception: their tools are written in Axo.
- An MCP endpoint for clients outside Axo (other agents, chat apps, the phone). Future possibility.
- Host MCP servers, detection of local apps, and stateful host tools (for example a browser session kept open across calls). Future possibility, once `bash` shows what is missing.
- Approvals. In v1 every call to a connection runs without pausing; the limits are the upstream server's own authorization and the scopes granted at sign-in. Per-connection approval policies are a future possibility.

## Guide-level explanation

### Vocabulary

- **Connection:** a named source of tools attached to an Axo account. There are two kinds:
  - a **third-party connection** is a remote MCP server the account adds by URL; the account's cloud Durable Object reaches it;
  - a **host connection** is one of the account's paired Macs; its `axod` runs the host's tools, which in v1 is only `bash`.
- **App:** a service Axo provides itself, such as Gmail, with tools written in Axo that call the provider's API. An account signs in to an app; it does not add one.
- **Grant:** the stored OAuth tokens that let Axo call a third-party connection for the account.
- **Tool:** one operation a connection exposes.

### Reaching tools from a Session

Connection tools are not declared one by one. Like Cloudflare MCP server portals, `axod mcp` adds a few meta-tools:

- `connections_list` lists the account's connections, their kind, host and state.
- `connections_add` adds a third-party connection from a name and URL and returns a sign-in link for the person to open when the server needs OAuth; `connections_remove` removes a third-party connection and its grant.
- `connections_search` finds tools: given `query`, plain words such as "wise balance", it answers the best matches with how to call each, its inputs and what it answers; given `code`, it runs a JavaScript function over `codemode.tools()`, the typed definitions of every reachable tool, and returns what it selects.

A remote MCP server is added under any name the person types, such as "emdash: leostera.com". The connection's `name`, which scripts call (`codemode.emdash_leostera_com.*`), is that name's slug: lowercase letters, digits and underscores. Its `title` keeps the name as typed. The same server may be added any number of times under different names, one per account the person has with it, and each signs in on its own. Settings › Apps lists the remote servers Axo knows (GitHub, Cloudflare's, Hugging Face, Ahrefs, Strava, Stripe, PayPal), each with a page where it is added once per account. Servers that run on the person's computer (1Password's and Twilio's) are not remote servers and are not listed.

Every `axod mcp` tool answers JSON in `structuredContent` and declares its shape as an `outputSchema`, so an agent's codemode reads a script's value as `structuredContent.result` and never parses the text copy in `content`. `connections_list` gives an agent each app's name, state, accounts and tool names, and leaves out the description, permissions and sign-in set-up that only the Apps page shows. An app tool's `account` input names the app's accounts.
- `connections_execute` runs a JavaScript function with a `codemode` proxy whose methods call tools, so one call can chain several tools and return only what the agent needs.

Tools are grouped by service: a script calls `codemode.<service>.<tool_name>(input)`, for example `codemode.linear.list_issues({ team: "AXO" })`. Both parts are JavaScript-safe identifiers; each tool also keeps the upstream server's original name for display.

The service is the connection's name, chosen when it is added. The account's Macs are reached through namespaces that take the Mac as an argument (amended by [RFD0028](RFD0028-computer-use.md), Computer use from anywhere): `codemode.hosts.list()` lists them, and a script runs a command on one with `codemode.bash.run({ host: "studio", command: "op item get github --fields token" })`. A Mac's `name` is its label in Axo as a JavaScript-safe name, unique among the account's Macs.

Every paired Mac is a host connection from the moment it is paired; there is no separate switch. Unpairing or revoking the host (RFD0013) removes the connection, and while the Mac is offline its `bash` calls fail with a host-offline error.

`bash` runs one non-interactive command as the user `axod` runs as, with a working directory, a timeout and an output limit, and returns its exit status, standard output and standard error. Whatever that user can reach (installed CLIs, Keychain, a signed-in password-manager CLI, local servers on `127.0.0.1`) is reachable, and nothing else is set up for it.

Scripts run in the cloud, not on the calling Mac. `axod mcp` forwards `connections_search` and `connections_execute` over the host relay to the account's Durable Object, which runs the script in a Dynamic Worker. Third-party calls are made from the cloud with the account's grants; host-connection calls travel over the relay to the Mac that owns the connection and back. A script that only uses host tools still makes that round trip; that is the price of keeping grants in one place.

### Apps

An app is listed in the web app's Apps and by `connections_list` as `apps.<app>` (kind `app`, with its accounts and tool names) signed in or not. An OAuth app whose provider has no client set up yet is listed with `signIn.client.ready` false, and has no tools until one is. Its tools are in `codemode.tools()` with service `apps.<app>` and `call` saying how a script calls them: `codemode.apps.<app>.<tool>({ account, ... })`. `apps`, `hosts`, `computer` and `bash` are reserved: no connection is added under those names.

An app holds any number of provider accounts (at most 20), each named by its email; signing in again to one replaces its grant. **Every call names its account**, even when only one is signed in, so nothing is ever read or sent from a guessed account: `codemode.apps.gmail.search_messages({ account: "me@example.com", query: "is:unread" })`. A call naming an account that is not signed in fails, listing the accounts that are. A call to an app with no account yet fails with a sign-in link, which the agent gives to the person, as with `connections_add`. An account whose grant was refused stays listed as needing sign-in until the person signs in to it again or removes it. `connections_remove({ name: "apps.gmail", account })` or Apps removes one account, deleting its grant and revoking it at the provider.

In the web app, Apps is a settings page over the chats, at `/app/settings/apps`: filters (search, connected or not, category), a grid of every app and MCP server with Add MCP server (each app with its maker's logo, bundled with the page; each server with the icon it names for itself in `initialize`, or else the one its site's home page declares, which the Durable Object looks up when it lists the server's tools, at most weekly, and the browser loads), and recent activity with whether the log is intact. MCP servers are managed at `/app/settings/apps/mcp`, and everything Sessions used is at `/app/settings/apps/activity`. An app's page, `/app/settings/apps/<app>`, has the app's logo, maker, category and what it is for; its accounts with Add account and what a signed-in account lets Axo do, in plain words; and what Sessions did with it (`axo.connections.log` with `service`). A sign-in comes back to the page of what was signed in to, saying how it went; `/app/connections`, where it used to, opens Apps.

Every app signs in with everything its own service allows, and only it. Besides its named tools, every app has `request({ account, method, path, query, body | text, headers })`, which calls any endpoint of the app's API as the account and returns its answer (JSON, text, or base64, cut at about half a megabyte), so a script can do all the permissions allow. A call, `request` or not, only ever sends the grant over https to the app's own hosts (Google Cloud's: any `*.googleapis.com`); `Authorization`, `Cookie` and `Host` cannot be set.

| App | Scope | Tools |
| --- | --- | --- |
| `apps.gmail` | `https://mail.google.com/`, `.../auth/gmail.settings.basic`, `.../auth/gmail.settings.sharing` | `get_profile`, `search_messages`, `get_message`, `get_thread`, `list_labels`, `send_message`, `create_draft`, `modify_message`, `trash_message`, `delete_message`, `list_filters`, `create_filter`, `delete_filter`, `get_vacation`, `set_vacation`, `list_send_as` |
| `apps.calendar` | `.../auth/calendar` | `list_calendars`, `list_events`, `get_event`, `create_event`, `update_event`, `delete_event`, `free_busy` |
| `apps.drive` | `.../auth/drive` | `search_files`, `get_file`, `read_file`, `download_file`, `upload_file`, `create_folder`, `update_file`, `share_file`, `trash_file`, `delete_file` |
| `apps.docs` | `.../auth/documents` | `get_document`, `create_document`, `append_text`, `replace_text` |
| `apps.sheets` | `.../auth/spreadsheets` | `get_spreadsheet`, `read_range`, `write_range`, `append_rows`, `clear_range`, `create_spreadsheet` |
| `apps.slides` | `.../auth/presentations` | `get_presentation`, `create_presentation`, `add_slide`, `replace_text`, `delete_slide`, `batch_update`, `get_thumbnail` |
| `apps.contacts` | `.../auth/contacts`, `.../auth/contacts.other.readonly`, `.../auth/directory.readonly` | `search_contacts`, `search_other_contacts`, `search_directory`, `list_contacts`, `get_contact`, `create_contact`, `update_contact`, `delete_contact` |
| `apps.tasks` | `.../auth/tasks` | `list_tasklists`, `create_tasklist`, `list_tasks`, `create_task`, `update_task`, `delete_task`, `clear_completed` |
| `apps.meet` | `.../auth/meetings.space.created`, `.../auth/meetings.space.readonly` | `create_meeting`, `get_meeting`, `end_meeting`, `list_meetings`, `list_participants`, `list_recordings`, `get_transcript` |
| `apps.cloud` | `.../auth/cloud-platform` | `list_projects`, `list_services`, `enable_service`, `read_logs`, `query_bigquery`, `list_buckets`, `list_objects`, `read_object`, `list_run_services`, `list_instances` |
| `apps.hetzner` | a project's API token | `list_servers`, `get_server`, `server_action`, `server_metrics`, `get_action`, `list_zones`, `list_records`, `set_records`, `delete_records`, `list_firewalls`, `list_volumes`, `list_storage_boxes` |
| `apps.octopus` | an API key and the account number | `get_account`, `get_consumption`, `get_unit_rates`, `list_products` |
| `apps.wise` | a personal API token | `list_profiles`, `list_balances`, `get_rate`, `list_transfers`, `get_transfer`, `list_recipients`, `create_quote` |
| `apps.telegram` | the person's own account, signed in as a new device of theirs (MTProto, through GramJS) | `get_me`, `list_chats`, `read_messages`, `search`, `send_message`, `mark_read` |
| `apps.kraken` | an API key and private key, pasted or created by signing in on a Mac; each private call signed (HMAC-SHA512) | `get_balance`, `get_trade_balance`, `list_open_orders`, `list_closed_orders`, `list_trades`, `list_ledger`, `get_ticker`, `add_order`, `cancel_order`, `call` |
| `apps.github` | `repo`, `read:org`, `notifications` (an OAuth app with expiring user tokens) | `get_me`, `list_repos`, `search`, `list_issues`, `get_issue`, `create_issue`, `comment`, `get_pull`, `get_file`, `list_notifications` |
| `apps.discord` | a bot token (`Bot <token>`) | `list_guilds`, `list_channels`, `read_messages`, `send_message` |
| `apps.unifi` | a Site Manager API key (`X-API-KEY`) | `list_hosts`, `list_sites`, `list_devices`, `get_isp_metrics`, `list_clients`, `get_traffic` |
| `apps.spotify` | playback state and control, playlists (read, modify public and private, collaborative), library (read, modify), recently played, top items | `get_me`, `get_playback`, `now_playing`, `list_devices`, `play`, `pause`, `next`, `previous`, `seek`, `set_volume`, `set_shuffle`, `set_repeat`, `transfer_playback`, `get_queue`, `add_to_queue`, `search`, `list_playlists`, `get_playlist`, `create_playlist`, `add_to_playlist`, `list_saved_tracks`, `list_saved_albums`, `save_to_library`, `remove_from_library`, `recently_played`, `top_items` |
| `apps.withings` | `user.info`, `user.metrics`, `user.activity` | `get_measures`, `get_activity`, `list_workouts`, `get_sleep_summary`, `get_sleep`, `list_ecgs`, `list_devices` |
| `apps.chatgpt` | Codex's sign-in (`openid profile email offline_access`) | `respond`, `list_models`, `usage` |
| `apps.onepassword` | the 1Password app on each Mac | `list_accounts`, `list_vaults`, `list_items`, `get_item`, `read`, `get_otp`, `create_item`, `update_item`, `delete_item`, `op` |

Each Google app also asks for `openid email`, to learn the account's email, and needs every scope it asks for: a sign-in that grants fewer does not land. A tool that deletes for good (`delete_message`, `delete_file`) says to prefer its trash counterpart unless asked. Google Cloud gives as much as `gcloud` signed in as the account; a call about a project sends `x-goog-user-project`, so the project's quota, billing and enabled APIs apply rather than Axo's.

#### Other ways in

Not every service has an OAuth client Axo can register. An app says how its Add account works (`signIn` in its listing):

- **Token apps** (Hetzner): the person pastes what the service issued them (an API token, a key), on the app's page and nowhere else. Axo checks it with one read call, and only a token the service accepts is stored, sealed like a grant; it is never shown again. A service that does not name the account (a Hetzner token is one project's) has the person name it, such as `personal`. A call the service refuses with 401 drops the token, and the account stays listed as needing a new one. Removing the account forgets the token; the person deletes it at the service. How a token goes on a request (bearer, basic, a header of the service's own, or a signature over the request) is the app's; `request` still only reaches the app's hosts.
- **Phone sign-in** (Telegram): Telegram's Bot API only acts as a bot, so `apps.telegram` is the person's own account, spoken to in MTProto, Telegram's own protocol, with GramJS (`telegram` on npm). It signs in with an API client of the person's own: they create one at my.telegram.org and enter its `api_id` and `api_hash` once on the app's page, kept sealed as an OAuth client is, and until then the app has no tools. Add account takes their number; Telegram sends a code to their Telegram app (or by SMS), then asks for the account's password if it has one (SRP: the password itself never reaches Telegram). The account's Durable Object keeps Telegram's state between steps sealed in a flow that lasts ten minutes and allows five wrong codes or passwords; the page only holds its ID. The sign-in ends with a session, a new device in the person's Telegram (Settings › Devices), stored sealed as the account's credential and named by its @username, else its number. Every call opens the session over TCP (Workers' `node:net`), runs the tool and closes it, about a second; a session Telegram moved to another data centre is stored again. A session the person ended on another device is dropped and asks for sign-in again; a send that got no answer may have run. Removing the account, or signing it in again, logs the old session out. Secret chats live only on the person's phones, so no tool sees them. `apps.telegram` was a bot app before; the bots' accounts were removed once (`app_migrations`).
- **Device sign-in** (ChatGPT): Codex's client (`app_EMoamEEZ73f0CkXaXp7hrann`, public; openai/codex `codex-rs/login`) only returns a browser to `localhost`, so Axo signs in the way `codex login --device-auth` does. Add account asks OpenAI for a user code, shows it with a link to `auth.openai.com/codex/device`, and the page asks Axo every few seconds whether the person entered it; Axo asks OpenAI at most once per the interval OpenAI named, for at most fifteen minutes. OpenAI then hands over an authorization code and the PKCE verifier it made, which Axo redeems once. The grant is stored under the account's email with its ChatGPT account ID, sent as `chatgpt-account-id` on every call. OpenAI rotates refresh tokens, so, as with third-party grants, a renewal that gets no answer drops the grant. `respond` is one turn of the Responses API at `chatgpt.com/backend-api/codex/responses`, streamed and not stored (`store: false`), read to its end in the Durable Object and returned whole. The person's ChatGPT security settings must allow device sign-in for Codex.
- **Mac apps** (1Password): the app runs a program on one of the account's Macs, signed in there already, and its accounts are the Macs, by their connection names: `codemode.apps.onepassword.get_item({ account: "studio", item: "GitHub" })`. Nothing is stored in the cloud. A tool's command goes to the Mac as `bash` does, but is logged once, as the app's call. Every argument is quoted for the shell, and values a command reads on standard input (a new item's fields) are piped from a shell builtin, so they are never on its command line or in the Mac's process list. 1Password is reached this way because it has no OAuth, and its service accounts, the only way in without a person, can never open a Private or Personal vault; the CLI, integrated with the desktop app, can. The first command of a session asks for Touch ID on that Mac, and the session then stays unlocked for ten minutes of quiet, at most twelve hours. What a tool returns (a revealed password) passes through the calling script, as any command's output does.

### Finding tools

`axod mcp` lists the account's connections when a Session's agent initializes it and when it lists its tools, waiting at most three seconds, and adds one line per connection, saying how a script calls it, to its instructions and to the descriptions of `connections_execute`, `connections_search` and `connections_list`: for example "`codemode.apps.gmail.<tool>({ account, ... })`: Gmail; pass `account` as one of me@example.com. Tools: search_messages, …". An agent searching its tools for "email" then finds `connections_execute` and knows the call to make. When the Mac is not linked or the account does not answer in time, the tools are listed as declared.

### Adding a third-party connection

Third-party connections are managed on the web app's Connections page or by agents. An agent that needs Linear mid-task calls `connections_add({ name: "linear", url: "https://mcp.linear.app/mcp" })` and gives the person the returned sign-in link; once they finish in the browser, `codemode.linear.*` is available to every Session of the account. An agent never asks for a secret in chat: a manual client ID and secret are entered only on the Connections page.

_(open)_

## Reference-level explanation

### Transport

All traffic between a Mac and its account uses the existing host relay WebSocket (RFD0013), extended with an `axo.connections.*` request/response namespace. A Session's `axod mcp` asks the local `axod` over `axod.sock`; `axod` forwards the request on its relay and returns the Durable Object's answer. In the other direction the Durable Object sends `bash` requests to the target Mac on that Mac's relay. Each request carries an ID and a deadline; both ends track in-flight requests, and a relay disconnect fails every in-flight request on that relay with a host-offline error rather than retrying it, because a command or tool call may already have run.

Relay frames stay at 64 KiB. A message larger than one frame (a script's source, a `bash` output, a script's result, a long transcript line) is split by the sender into `axo.transport.fragment` notifications `{ messageId, index, count, data }` and reassembled by the receiver before it is parsed, so `axo.connections.*` handlers never see fragments. A reassembled message is at most 16 MiB, and a receiver keeps at most 4 partly received messages per socket; a partial message dies with its socket.

Everything for a Mac shares its one relay socket (RFD0018): durable transcript upload, ephemeral progress, commands and connections calls. There are no delivery credits (RFD0018, Flow control). On the Mac, threads queue messages with a priority class (control and replies, then durable upload, then ephemeral), and the relay loop sends one frame at a time from the highest class, continuing the message that class started. Fragments therefore interleave across classes, so a large upload never holds back a `bash` reply, and at most one message per class is partly sent. A sender that gives up on a message part-way sends an `axo.transport.discard` notice; a receiver also drops a partial that gets no fragment for 60 seconds, and ignores late fragments of a message it dropped. Every request carries an ID and a deadline; when a socket closes, the requests waiting on it fail, and replies meant for it are dropped rather than sent on the next socket.

Connections require a paired Mac. On an unpaired Mac, or while the relay is down, every `connections_*` tool fails with an error saying so.

### Third-party connection sign-in

When a third-party MCP server requires OAuth, the account's Durable Object is the OAuth client. It discovers the server's authorization server from its protected resource metadata and registers a client automatically when the server supports dynamic client registration. When it does not, the person adding the connection enters a client ID and, if the provider requires one, a client secret for an OAuth application they registered with the provider. The client secret is encrypted with the account's credential key and never returned by any API. Discovery (RFC 9728, RFC 8414), registration (RFC 7591) and the token requests are the official MCP SDK's (`@modelcontextprotocol/sdk/client/auth`), which bends where servers do; Axo keeps the fixed callback, the resource indicator, and treats a 4xx from the token endpoint as a refusal and anything else as a failure. Calls to the server go through the same SDK's client over streamable HTTP, which negotiates the protocol version and keeps the server's session. Axo's `fetch` around it adds the bearer token, refuses redirects and answers over 4 MiB, reports a 401 as needing sign-in and a request that got no answer as may-have-run, and answers the SDK's long-lived notification stream with 405, so the account's Durable Object holds no connection open per server. Tool lists and results are read as sent, not checked against the SDK's schemas.

Every third-party sign-in returns to one fixed callback, `https://axo.leostera.dev/api/v1/connections/oauth/callback`, the only redirect URI a provider ever needs. A sign-in link (what `connections_add` returns, or the Connections page's Sign in button) points at Axo's own start page, `/api/v1/connections/oauth/start?flow=<nonce>`, never at the provider: it works once, within ten minutes, and only in a browser signed in to the account that owns the connection, so a link passed to someone else does nothing. The start page sets a flow cookie and sends the browser to the provider; the PKCE verifier stays in the account's Durable Object, and the account and nonce are sealed into `state`. The callback accepts the provider's answer only from a browser signed in to that account that presents the flow cookie, and redeems the code once. A sign-in completed this way lands on Settings › Apps, on the page of what was signed in to. A completed sign-in stores the grant on the connection; the Durable Object refreshes it before expiry and marks the connection as needing sign-in when refresh fails.

Each stored grant carries a generation that goes up with every completed sign-in, and every refresh names the generation it renews. A refresh answer or failure for an older generation is ignored: two quick sign-ins and a refresh can otherwise interleave so that the rejection of the first grant's refresh drops the second, newer grant (the model found this). A refresh that gets no answer drops the grant, because a rotated refresh token may already be spent.

### App sign-in

An app's provider client is one the person registered with the provider (Google Cloud, a GitHub OAuth app, a Spotify app), with the fixed callback as its only redirect URI. They enter its ID and secret once on the app's page; the account's Durable Object keeps the secret sealed with the account's key, never returns it, and uses one client for every app of its provider (all of Google's). It can be replaced at any time, to rotate a secret; grants from the old client keep working while the provider honours them, and a renewal it refuses asks for sign-in again. Until a provider has a client, its apps are listed as waiting for one, with the provider's page for registering it, and have no tools. (Google's client from the Worker's environment, `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, is still used while an account has set up none of its own.) Each provider is a config in `@axo/apps` (`packages/axo-apps/src/oauth/`), and the token endpoint is spoken with `oauth4webapi`: code redemption, renewal, client authentication (basic or in the form), and checking the ID token Google's email comes from (its issuer, audience and expiry; not its signature, since it comes straight from Google over TLS). A config holds its endpoints, extra authorize parameters, how the token request carries the client, an adapter for an answer out of the standard (GitHub refuses with HTTP 200 and `{ error }`, Withings wraps everything in `{ status, body }`), whether refresh tokens rotate (GitHub's and Spotify's do, so a renewal that got no answer drops the grant), how the account is named (Google's email, a GitHub login, a Spotify ID, a Withings user ID) and how a grant is revoked. Withings' token endpoint is an API action (`action=requesttoken`) without PKCE. ChatGPT's device sign-in and its token requests stay hand-written: OpenAI's device endpoints are not RFC 8628's, and its token answers carry no `token_type`. A service that answers errors with HTTP 200 (Withings' `status`, Slack's `ok: false`) says how to read them (`answerError`), for every call, `request` included: its "bad token" renews the grant once, as a 401 does. The redirect URI is the same fixed callback, and an app's sign-in uses the same start page, flow cookie, sealed state and one-time, ten-minute nonce as a third-party sign-in; app flows and third-party flows are kept apart but never share a nonce. Google is asked for offline access with forced consent, so every sign-in returns a refresh token. A sign-in that did not grant the app's required scopes (a person can untick them on Google's consent page) does not land: its grant is revoked and the app stays signed out.

App grants are sealed with the account's key, carry a generation like third-party grants, and are renewed before expiry; a renewal lands only on the generation it renewed. Google does not rotate refresh tokens, so a renewal that gets no answer keeps the grant and fails the call; a refused renewal drops it. A provider 401 renews once and sends the call again, since it did not run. A call to a tool that is not safe to repeat (sending, creating, appending, sharing) that gets no answer or a server error fails as may-have-run and is logged as `unknown`. Grants are kept per provider account: renewing or dropping one never touches another. A grant stored before apps held several accounts became that account's, under its email. A grant that lacks a scope the app now requires (Gmail's moved from `gmail.modify` to full access) is not used: a call asks for sign-in again, with a link.

#### Sign-in on a Mac

A service that sends sign-ins back only to `http://localhost` cannot redirect to the cloud. Kraken lets only approved partners register OAuth clients, and the public client it publishes for kraken-cli (`230dc4f672711a31e0ae01db611cf68c`, PKCE, no secret) has `http://localhost:27461`–`27463` `/callback` as its only redirects. Such a token app has a sign-in on a Mac (`TokenSignIn.mac`) beside pasting a key. The person picks one of their online Macs and what Axo may do (Kraken: "Read only" or "Read and trade"), and the account's Durable Object sends `axo.connections.signIn` down that Mac's socket (`callHost`). The request carries the authorize URL without `redirect_uri`, the ports and path, the state and a timeout of at most 10 minutes (5 for Kraken). `axod` (`crates/axo-signin`, served from `axo-relay`'s `signin.rs`) binds the first free port on the loopback interface only. It adds `redirect_uri=http://localhost:<port><path>`, opens the page in the Mac's browser and answers with the first redirect that carries the right state: the redirect it used, and the code or the service's error. Other paths get a 404 and a wrong state a 400. `axod` runs at most 2 sign-ins at once, and logs only their call ID and outcome, never a URL or code. Older `axod`s answer "method not found", which reads as "update Axo there".

The PKCE verifier never leaves the Durable Object. It redeems the code with the redirect `axod` reported, using `oauth4webapi`. A grant whose scope differs from what was asked, in either direction, is refused and creates nothing. For Kraken it then creates a Fast API key named `axo-<random>`, with exactly the chosen permissions and Kraken's longest lifetime (90 days). Kraken gives no withdrawal permission this way. A key whose name, expiry or permissions differ from the request is deleted and refused. The key is checked with one read call, as a pasted one is, and stored sealed with when it expires and the OAuth tokens that can delete it. A call after expiry asks for a new sign-in. Removing the account, or replacing its key, deletes the key at Kraken, renewing the 4-hour OAuth token first if it has expired. The sign-in runs in the background (`POST .../apps.<app>/mac-sign-in`) and the web app polls `.../mac-sign-in/poll` until it is done or failed. A Mac has one waiting sign-in at a time.

### Tool lists

The Durable Object keeps each third-party connection's tool definitions. It fetches them when the connection is added or signed in again, and refreshes them in the background when a search reads a list older than one hour or the server sends a tool-list-changed notification. At most one refresh per connection is in flight; a change heard during it queues exactly one more, so notifications cannot pile up requests. Notifications are best effort (a server may not send one, or it may be lost), and the hourly ageing is what bounds staleness. Searches always answer from the stored lists, so a slow or failing server goes stale instead of delaying the search; the connection's state records when it was last synced and the last sync error. The host `bash` tool is fixed and needs no sync.

### Call log

The Durable Object records every tool call: time, calling Session and Mac, connection and tool, the target Mac for `bash`, duration, outcome, and the call's input (for `bash`, the command text, working directory and timeout). Outputs are never recorded. Inputs are encrypted with the account's credential key. Records are kept for 30 days and shown in Settings › Apps (all of them, or one app's) and through `connections_log`. Because inputs are kept, a secret passed as a tool input or written into a command line is retained with the record for that window.

Every call is made by the account's `AxoAccountManager` Durable Object, the one that writes its record: a script runs in a Dynamic Worker with no network of its own, and each `codemode.*` call comes back to the account's Durable Object, which calls the app's API or the MCP server with the grant it holds, or sends `bash` to the Mac through its `AxoHostDO`. So one place sees every call, and records it before sending it.

The log is also a hash chain (`call_chain`): each call's start and finish is an event whose hash is SHA-256 of the previous event's hash and its own contents, including the sealed input. `GET /api/v1/account/connections/log/integrity` replays the chain from its anchor and checks every row of the log against its events, so a record that was changed, added or removed shows as broken from that point on; Settings › Apps says whether the log is intact. Past 30 days, whole calls and their events are dropped and the hash of the last dropped event becomes the anchor. The chain is tamper-evident only against changes to what is stored, not against whoever can rewrite the Durable Object entirely, chain included; keeping the head somewhere else (on the Macs, or in write-once storage) would close that, and is not done yet.

### Limits

| Limit | Value |
| --- | --- |
| `connections_execute` script wall time | 5 minutes |
| Tool calls per script | 100 |
| Concurrent tool calls per script | 4 |
| Script source size | 64 KiB |
| `bash` default timeout | 60 seconds |
| `bash` maximum timeout | 10 minutes, capped by the script's remaining time |
| `bash` output kept per stream | 1 MiB, then truncated with a marker |
| Script result returned to the Session | 1 MiB |

Exceeding a limit fails the call with an error that names the limit. Values are never cut silently; `bash` output is the one exception, and it carries a truncation marker.

### Model

[`specs/apps/apps.ts`](../../specs/apps/apps.ts) models a Session running scripts over third-party and host connections: the relay, the account's Durable Object, the script Worker and a third-party MCP server, with relay drops, lost messages and restarts. Each Mac's socket ends in its own Durable Object, `HostDO`: `axod` connects to `axo.leostera.dev`, and the Worker routes the socket to `HostDO` by host ID (RFD0018). Connections state lives only in the account's `AxoAccountManager`, one Durable Object RPC away: the socket owner forwards a Mac's `axo.connections.*` calls to it (`connectionsCall`) and sends `bash` down the Mac's socket for it (`callHost`, which waits for the Mac's reply, never retries, and fails as may-have-run when the socket closes, the Mac is revoked or its deadline passes), and holds nothing but sockets, what it forwarded and the `callHost` calls waiting on a socket. The model keeps the two apart. It also models `axod` running each command on a thread of its own, tied to the relay socket it came on (a command's output never goes back on a later socket), the script's wall time and call limit, and unpairing a Mac mid-command. Its properties are the invariants below plus: a waiting Session always gets an answer; a third-party call reaches the service at most once; a command runs at most once; a Mac is an online connection only while paired; no script exceeds its call limit; an unpaired Mac runs no command dispatched after it was unpaired; the socket owner holds no connections state.

[`specs/relay/relay-fragments.ts`](../../specs/relay/relay-fragments.ts) models the fragment transport: the parser only sees whole messages from one socket, each at most once, and never one its sender gave up on; at most one message per priority class is partly sent, so an honest sender is never refused; the receiver's partials stay bounded and always drain; and everything queued is in the end sent, given up on, or dropped with its socket.

[`specs/apps/connection-sign-in.ts`](../../specs/apps/connection-sign-in.ts) models adding a third-party connection: client registration or a client typed on the Connections page, the sealed-state and flow-cookie callback, code redemption and refresh with revocation. Its properties: a grant only lands in the account of the person who approved it, even when a consent page is passed to someone else; no browser or agent holds a refresh token or client secret; secrets are stored sealed; a ready connection holds a grant; a code is redeemed at most once.

[`specs/apps/tool-lists.ts`](../../specs/apps/tool-lists.ts) models tool-list sync: searches never wait on a server, a list not marked stale matches the server unless a change went unannounced, and a refresh in flight always ends.

The specs point at their code (sources, locked in `feynman.lock`): the host-connection path of `specs/apps/apps.ts`, and the sign-in and tool-list specs. Third-party calls in `specs/apps/apps.ts` and the Linear stand-ins are model only. Run them with `pnpm exec feynman check`.

### Invariants

- **Account isolation.** A connection belongs to exactly one Axo account. Only that account's clients, Sessions and hosts can list, use, change or remove it. No route, relay message or tool call resolves a connection across accounts.
- **Per-account credential keys.** Credential material is encrypted with a key specific to the owning account, so a defect that reads another account's rows cannot decrypt them.
- **Credentials stay where they were issued.** Third-party connection and app grants are held by the account's cloud Durable Object and never sent to a Mac or a Session. A host connection's commands use credentials already on its Mac (a password-manager CLI, Keychain, browser profile, local files); Axo neither stores nor transports them, though a command's output can contain whatever the command prints. Calls travel to the credential, never the reverse.
- **Unique service names.** A connection name is a JavaScript-safe identifier unique within its account across third-party and host connections, and never `apps`. A host connection's name is its Mac's host name. Adding a duplicate name fails; nothing is renamed automatically. Apps are `apps.<app>`, outside that namespace.
- **One execution place.** `connections_execute` scripts run only in the account's cloud Dynamic Worker. The script sandbox has no network access of its own; its only way out is a tool call through the `codemode` proxy, which the Durable Object dispatches.

## Drawbacks

- **Account-wide remote shell.** Every paired Mac accepts `bash` from every Session and cloud script of the account, with no approval and no per-Mac opt-in. A compromised account session, or an agent misreading its task in a Session on one Mac, can run commands on every other online Mac. RFD0013 already gives the account terminal control of its hosts, so the authority is not new, but it becomes reachable from agent scripts without a person at a terminal.
- **The call log keeps inputs.** A secret placed in a tool input or a command line is stored, encrypted, for 30 days.
- **Command output can carry secrets.** Axo does not store or move host credentials, but a command such as `op item get ... --fields token` prints a secret, which then passes through the cloud script and into the calling Session's context.
- **A leaked callback URL is a grant.** The flow cookie stops someone completing another person's sign-in in their own browser, but if Mallory gets Alice to approve Mallory's consent page and then obtains the callback URL from Alice's redirect, Mallory's browser holds the cookie and Alice's grant lands in Mallory's account. This is the general OAuth authorization-code risk; PKCE does not help because the verifier is Axo's. The model treats callback URLs as reaching only the browser that was redirected.

_(open)_

## Rationale and alternatives

_(open)_

## Prior art

_(open)_ Executor v2 (providers, accounts, app links, credential handles); Cloudflare MCP server portals (one Access-authenticated endpoint, per-user upstream OAuth, shared callback, Code Mode).

## Unresolved questions

_(open)_

## Future possibilities

_(open)_
