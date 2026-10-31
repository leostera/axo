# RFD0016 - Axo: connections and tools

- Feature Name: `axo-connections-and-tools`
- Status: Draft
- Author: leostera
- Start Date: 2026-10-29
- Updated: 2026-10-31
- Document Type: Proposal

> Drafting in progress. Sections marked _(open)_ are not yet decided.

## Summary

_(open)_ Axo gains connections: credentials and tool sources an Axo account adds once and its agents use from anywhere. The account's cloud Durable Object holds connections to remote services, its paired Macs contribute tools only they can provide, and agents reach both through one tool catalog.

## Motivation

_(open)_

## Goals

- An account adds a third-party connection (a remote MCP server) by URL once and its agents use that server's tools afterwards, with Axo running the upstream OAuth flow and keeping the grant.
- Each paired Mac is a host connection with one tool, `bash`, that any Session of the same account can call while that Mac is online, including Sessions on other Macs. Local apps are reached through their command-line interfaces; Axo does not need to know about them.
- Agents in Axo Sessions reach every connection through the existing `axod mcp` server (RFD0015).
- Axo provides a few apps itself, starting with Gmail, that an account signs in to once and its agents reach as `codemode.apps.<app>.*`.

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
- `connections_search` runs a JavaScript function over `codemode.tools()`, the typed definitions of every reachable tool, and returns what it selects.
- `connections_execute` runs a JavaScript function with a `codemode` proxy whose methods call tools, so one call can chain several tools and return only what the agent needs.

Tools are grouped by service: a script calls `codemode.<service>.<tool_name>(input)`, for example `codemode.linear.list_issues({ team: "AXO" })`. Both parts are JavaScript-safe identifiers; each tool also keeps the upstream server's original name for display.

The service is the connection's name. A third-party connection's name is chosen when it is added; a host connection's name is its Mac's host name in Axo (for example `studio`), so a script runs a command on that Mac with `codemode.studio.bash({ command: "op item get github --fields token" })`. Names are unique within the account across both kinds: adding a third-party connection named like a Mac is refused.

Every paired Mac is a host connection from the moment it is paired; there is no separate switch. Unpairing or revoking the host (RFD0013) removes the connection, and while the Mac is offline its `bash` calls fail with a host-offline error.

`bash` runs one non-interactive command as the user `axod` runs as, with a working directory, a timeout and an output limit, and returns its exit status, standard output and standard error. Whatever that user can reach (installed CLIs, Keychain, a signed-in password-manager CLI, local servers on `127.0.0.1`) is reachable, and nothing else is set up for it.

Scripts run in the cloud, not on the calling Mac. `axod mcp` forwards `connections_search` and `connections_execute` over the host relay to the account's Durable Object, which runs the script in a Dynamic Worker. Third-party calls are made from the cloud with the account's grants; host-connection calls travel over the relay to the Mac that owns the connection and back. A script that only uses host tools still makes that round trip; that is the price of keeping grants in one place.

### Apps

An app is listed on the Connections page and by `connections_list` as `apps.<app>` (kind `app`) whenever the deployment has a client for the app's provider, signed in or not. Its tools are in `codemode.tools()` with service `apps.<app>`, and a script calls them as `codemode.apps.<app>.<tool>(input)`, for example `codemode.apps.gmail.search_messages({ query: "is:unread" })`. `apps` is reserved: no connection is added under that name, and a Mac labelled "apps" gets a suffix.

The person signs in on the Connections page. An agent that calls an app before that gets an error carrying a sign-in link, which it gives to the person, as with `connections_add`. `connections_remove({ name: "apps.gmail" })` or the page's sign-out button deletes the grant and revokes it at the provider.

Gmail is the first app. It signs in to Google with `openid email https://www.googleapis.com/auth/gmail.modify`, so it can read, search, send, draft, label and trash mail but not delete it for good, and shows the Google account's email once signed in. Its tools are `get_profile`, `search_messages`, `get_message`, `get_thread`, `list_labels`, `send_message`, `create_draft`, `modify_message` and `trash_message`.

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

When a third-party MCP server requires OAuth, the account's Durable Object is the OAuth client. It discovers the server's authorization server from its protected resource metadata and registers a client automatically when the server supports dynamic client registration. When it does not, the person adding the connection enters a client ID and, if the provider requires one, a client secret for an OAuth application they registered with the provider. The client secret is encrypted with the account's credential key and never returned by any API.

Every third-party sign-in returns to one fixed callback, `https://axo.leostera.dev/api/v1/connections/oauth/callback`, the only redirect URI a provider ever needs. A sign-in link (what `connections_add` returns, or the Connections page's Sign in button) points at Axo's own start page, `/api/v1/connections/oauth/start?flow=<nonce>`, never at the provider: it works once, within ten minutes, and only in a browser signed in to the account that owns the connection, so a link passed to someone else does nothing. The start page sets a flow cookie and sends the browser to the provider; the PKCE verifier stays in the account's Durable Object, and the account and nonce are sealed into `state`. The callback accepts the provider's answer only from a browser signed in to that account that presents the flow cookie, and redeems the code once. A sign-in completed this way lands on the Connections page (`/app/connections`). A completed sign-in stores the grant on the connection; the Durable Object refreshes it before expiry and marks the connection as needing sign-in when refresh fails.

Each stored grant carries a generation that goes up with every completed sign-in, and every refresh names the generation it renews. A refresh answer or failure for an older generation is ignored: two quick sign-ins and a refresh can otherwise interleave so that the rejection of the first grant's refresh drops the second, newer grant (the model found this). A refresh that gets no answer drops the grant, because a rotated refresh token may already be spent.

### App sign-in

An app's provider client is Axo's own: one OAuth client per provider, registered by the operator, whose ID and secret are Worker secrets (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` for Google). Without them the provider's apps are not listed. The client's only redirect URI is the same fixed callback, and an app's sign-in uses the same start page, flow cookie, sealed state and one-time, ten-minute nonce as a third-party sign-in; app flows and third-party flows are kept apart but never share a nonce. Google is asked for offline access with forced consent, so every sign-in returns a refresh token. A sign-in that did not grant the app's required scopes (a person can untick them on Google's consent page) does not land: its grant is revoked and the app stays signed out.

App grants are sealed with the account's key, carry a generation like third-party grants, and are renewed before expiry; a renewal lands only on the generation it renewed. Google does not rotate refresh tokens, so a renewal that gets no answer keeps the grant and fails the call; a refused renewal drops it. A provider 401 renews once and sends the call again, since it did not run. A call to a tool that is not safe to repeat (`send_message`, `create_draft`) that gets no answer or a server error fails as may-have-run and is logged as `unknown`.

### Tool lists

The Durable Object keeps each third-party connection's tool definitions. It fetches them when the connection is added or signed in again, and refreshes them in the background when a search reads a list older than one hour or the server sends a tool-list-changed notification. At most one refresh per connection is in flight; a change heard during it queues exactly one more, so notifications cannot pile up requests. Notifications are best effort (a server may not send one, or it may be lost), and the hourly ageing is what bounds staleness. Searches always answer from the stored lists, so a slow or failing server goes stale instead of delaying the search; the connection's state records when it was last synced and the last sync error. The host `bash` tool is fixed and needs no sync.

### Call log

The Durable Object records every tool call: time, calling Session and Mac, connection and tool, the target Mac for `bash`, duration, outcome, and the call's input (for `bash`, the command text, working directory and timeout). Outputs are never recorded. Inputs are encrypted with the account's credential key. Records are kept for 30 days and shown on the Connections page and through `connections_log`. Because inputs are kept, a secret passed as a tool input or written into a command line is retained with the record for that window.

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

[`specs/connections.ts`](../../specs/connections.ts) models a Session running scripts over third-party and host connections: the relay, the account's Durable Object, the script Worker and a third-party MCP server, with relay drops, lost messages and restarts. Each Mac's socket ends in its own Durable Object, `HostDO`: `axod` connects to `api.axo.leostera.dev`, and the Worker routes the socket to `HostDO` by host ID (RFD0018). Connections state lives only in the account's `AxoAccountManager`, one Durable Object RPC away: the socket owner forwards a Mac's `axo.connections.*` calls to it (`connectionsCall`) and sends `bash` down the Mac's socket for it (`callHost`, which waits for the Mac's reply, never retries, and fails as may-have-run when the socket closes, the Mac is revoked or its deadline passes), and holds nothing but sockets, what it forwarded and the `callHost` calls waiting on a socket. The model keeps the two apart. It also models `axod` running each command on a thread of its own, tied to the relay socket it came on (a command's output never goes back on a later socket), the script's wall time and call limit, and unpairing a Mac mid-command. Its properties are the invariants below plus: a waiting Session always gets an answer; a third-party call reaches the service at most once; a command runs at most once; a Mac is an online connection only while paired; no script exceeds its call limit; an unpaired Mac runs no command dispatched after it was unpaired; the socket owner holds no connections state.

[`specs/relay-fragments.ts`](../../specs/relay-fragments.ts) models the fragment transport: the parser only sees whole messages from one socket, each at most once, and never one its sender gave up on; at most one message per priority class is partly sent, so an honest sender is never refused; the receiver's partials stay bounded and always drain; and everything queued is in the end sent, given up on, or dropped with its socket.

[`specs/connection-sign-in.ts`](../../specs/connection-sign-in.ts) models adding a third-party connection: client registration or a client typed on the Connections page, the sealed-state and flow-cookie callback, code redemption and refresh with revocation. Its properties: a grant only lands in the account of the person who approved it, even when a consent page is passed to someone else; no browser or agent holds a refresh token or client secret; secrets are stored sealed; a ready connection holds a grant; a code is redeemed at most once.

[`specs/tool-lists.ts`](../../specs/tool-lists.ts) models tool-list sync: searches never wait on a server, a list not marked stale matches the server unless a change went unannounced, and a refresh in flight always ends.

The specs point at their code (sources, locked in `feynman.lock`): the host-connection path of `specs/connections.ts`, and the sign-in and tool-list specs. Third-party calls in `specs/connections.ts` and the Linear stand-ins are model only. Run them with `npx feynman check`.

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
