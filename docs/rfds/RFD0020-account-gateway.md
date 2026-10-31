# RFD0020 - Axo: The account gateway

- Feature Name: `axo-account-gateway`
- Status: Draft
- Author: leostera
- Start Date: 2026-10-31
- Updated: 2026-10-31
- Document Type: Proposal

## Summary

I propose a Durable Object class, `AxoGateway`, one per Axo account, that holds every credential the account has given Axo for other services and makes every call to them. It runs connections scripts. It calls Google and every app Axo provides with the account's grants, and calls remote MCP servers with theirs. It sends `bash` to the account's Macs through each Mac's `AxoHostDO`. It writes the call log and its hash chain before any call goes out.

Today all of this runs inside `AxoAccountManager`, which is also the account's identity object: profile, browser sign-ins, login codes and paired Macs. `AxoAccountManager` keeps those jobs and loses the connections. The two objects talk over RPC:

- The gateway asks the account manager which Macs the account has.
- The account manager tells the gateway when that changes.

Existing accounts move their connections state once, the first time the gateway is used. The gateway copies it from the account manager, stores it, and then confirms. Only then does the account manager delete its copy, so nothing is lost or held by both after the move completes. The hash chain moves unchanged, and the gateway verifies it after the move.

Three rules hold:

- **One account, one gateway, one place for credentials.** Grants, tokens and client secrets are stored, sealed, only in the account's gateway. No browser, Mac, Session or other Durable Object ever holds one.
- **Every call goes through the gateway and is logged first.** Nothing reaches a service or a Mac on the account's behalf except from the gateway, and the gateway writes the call to the log before sending it.
- **The account manager stays small.** It holds who the account is and which devices may act for it, and nothing that calls the outside world.

## Motivation

RFD0016 put connections in the account's Durable Object because there was one, and it was the natural owner of an account's state. That decision is right about *one object per account*. It is wrong about *which* object. `AxoAccountManager` started as the account's identity, and it still is:

- every signed-in request from the web or the phone calls its `verifySession` (`src/auth/account-access.ts`);
- it issues login codes and holds the browser sessions;
- it registers and revokes Macs.

Since RFD0016, the same object also:

- holds sealed Google grants for ten apps, MCP grants and client secrets (`src/connections/apps/`, `src/connections/third-party.ts`);
- runs scripts in a Dynamic Worker and serves their tool calls (`src/connections/runner.ts`, `src/connections/account.ts`);
- calls Google, Google Cloud and any MCP server, and parses their answers. These are up to 1 MiB of JSON per call, base64 downloads, BigQuery rows and server-sent event streams.
- writes the call log and its hash chain (`src/connections/call-log.ts`).

That mixes two jobs with different risks:

- **Shared failure.** A Durable Object is one thread in one isolate with 128 MB of memory. Awaiting a fetch lets other requests run, so a slow call does not block sign-in checks. But CPU and memory are shared. A burst of large app answers competes with `verifySession` for the thread. If it runs out of memory or throws outside a handler, the object resets, and every request in flight fails, sign-in checks included.
- **Exposure.** The code that parses untrusted answers from the internet runs in the same object, with the same storage, as the account's sign-in records and login codes. A bug in a Gmail MIME parser or an MCP stream reader should not be in the same room as a login code.
- **Change rate.** Apps change weekly: new apps, new tools, token apps (Hetzner, 1Password), a browser bridge later. Identity should change rarely. Today every app change is a change to the identity object.
- **Ownership.** "Which object holds the Hetzner token, and which object makes the call?" should have a one-word answer. Today the answer is "the account manager, in a module it composes", which is how this proposal started.

## Goals

- One Durable Object class per account that owns every outside credential and makes every outside call.
- `AxoAccountManager` holds identity, sign-ins, login codes and Macs, and none of the connections state.
- Existing accounts move without losing a grant, a log record or the chain, and without signing in again.
- No change to what a Session, the web app or the phone sees: same RPC methods, same HTTP routes, same errors.
- The call log and its hash chain stay with the calls they record, in the gateway.

## Non-goals

- New apps, token apps or a browser bridge. Those land in the gateway afterwards.
- Changing how a script runs, how tools are found, or the RFD0016 limits.
- Moving Macs' sockets. They stay in `AxoHostDO` (RFD0018); the gateway calls them as the account manager does today.
- Anchoring the chain head outside the gateway. RFD0016 notes that this is not done; it remains a separate decision.
- Sharding one account's calls over several objects.

## Guide-level explanation

### Mental model

```
                ┌──────────────────────────┐
 browser/phone ─▶│ AxoAccountManager        │  who the account is:
 (sign-in check) │  profile, sign-ins,      │  profile, sessions, login codes, Macs
                 │  login codes, Macs       │
                 └────────────┬─────────────┘
                     Macs of the account │ ▲ Macs changed
                                         ▼ │
 Session ─axod─▶ AxoHostDO ─connections─▶ ┌──────────────────────────┐ ─▶ Google, Google Cloud
 web app ─HTTP (Apps)────────────────────▶│ AxoGateway               │ ─▶ MCP servers
                                          │  grants, tokens, secrets │ ─▶ (later) Hetzner, 1Password, …
                                          │  runs scripts            │
                                          │  call log + hash chain   │ ─bash─▶ AxoHostDO ─▶ a Mac
                                          └──────────────────────────┘
```

There is one rule to remember: **if it touches another service, it is the gateway.**

### A Session reads Gmail

An agent on the Studio runs `codemode.apps.gmail.search_messages({ account: "ada@ostera.io", query: "is:unread" })`:

1. axod sends `axo.connections.execute` over its relay. `AxoHostDO` forwards it to the account's gateway, where today it forwards to the account manager.
2. The gateway starts the script in a Dynamic Worker, which has no network. The script's call comes back to the gateway.
3. The gateway writes a `start` record and its chain event, unseals Ada's Gmail grant and calls Gmail. It then writes `finish` and returns the answer.

The account manager takes no part.

### The person adds a Google account

The web app's **Add account** posts to `/api/v1/account/connections/apps.gmail/sign-in`, as today:

- The Worker checks the browser's session with the account manager, then asks the gateway for a sign-in link.
- The callback goes to the gateway, which redeems the code and seals the grant.
- The callback's browser check (signed in, flow cookie) still uses the account manager.

### A Session runs `bash` on another Mac

The gateway keeps the account's Mac list, which it gets from the account manager. The account manager tells it when a Mac is paired or revoked. The gateway sends the command to that Mac's `AxoHostDO`, exactly as the account manager does today.

A revoked Mac runs nothing new, even if the gateway's list is stale: `AxoHostDO` refuses a revoked host's socket, as today (RFD0013).

### Moving an existing account

Nobody does anything. After the deploy, the first connections request for an account goes to its gateway. The gateway finds it has never imported, and asks the account manager for its connections state:

- grants and flows;
- MCP servers, their clients and grants;
- the call log, the chain and its anchor.

It stores what it gets in one transaction and verifies the chain, then confirms to the account manager with the chain's head. The account manager deletes its copy only when that head matches what it exported. The request then proceeds.

If anything fails along the way, the request fails with "try again". The next request starts the move again, and nothing is lost: the account manager deletes nothing until it is confirmed.

## Reference-level explanation

### Components and ownership

| Object | Key | Owns | Calls out to |
|---|---|---|---|
| `AxoAccountManager` (deployed as `AxoAccountDirectory`) | account ID | `account`, `profile`, `sessions`, `login_codes`, `hosts` (paired Macs), `handoff` (gateway move tombstone) | `AxoHostDO` (revoke), `AxoGateway` (Macs changed, export) |
| `AxoGateway` (new) | account ID | `app_accounts`, `app_flows`, `third_party_connections`, `connection_flows`, `connection_calls`, `call_chain`, `call_chain_anchor`, `gateway_macs`, `gateway_meta` | Dynamic Worker (`LOADER`), Google APIs, MCP servers, `AxoHostDO.callHost`, `AxoAccountManager` (Macs, export) |
| `AxoHostDO` | host ID | a Mac's socket | `AxoGateway.connectionsCall` (was `AxoAccountManager.connectionsCall`) |

The gateway's code is today's `AccountConnections` and what it composes (`AppConnections`, `ThirdPartyConnections`, `CallLog`, `runScript`), moved, not rewritten. Its storage tables keep their names and shapes, so the move is a copy.

Sealing keys do not change. Grants and inputs are sealed with keys derived from the Worker's secret and the account ID, with purposes such as `apps-grant\0<accountId>`. These do not depend on which object holds them, so copied rows unseal in the gateway as they did in the account manager.

### RPC surface

`AxoGateway` exposes what `AxoAccountManager` exposes today for connections, with the same names and results:

- `connectionsCall(call)`: `axo.connections.*` from a Session, through `AxoHostDO`.
- `listConnections()`, `addConnection(name, url)`, `removeConnection(name, account?)`, `setConnectionClient(...)`.
- `connectionSignInLink(name)`, `openConnectionFlow(nonce)`, `completeConnectionFlow(nonce, code)`.
- `connectionsLog(limit?, before?, service?)`, `connectionsLogIntegrity()`.
- `macsChanged(version, macs)`: from the account manager; replaces the gateway's Mac list if `version` is newer.

`AxoAccountManager` keeps its identity methods and gains:

- `gatewayMacs()`: `{ version, macs: [{ hostId, name }] }`, the account's paired Macs, named as connections, with a version that increases on every pair, rename or revoke.
- `exportConnections()`: the move's snapshot, described below.
- `confirmConnectionsMoved(head)`.

It loses every `connections*` method. A call to one after the deploy is a bug and fails.

### Routing

| Caller | Before | After |
|---|---|---|
| `/api/v1/account/connections/*` (web app) | `requireAccount` → `AxoAccountManager` | `requireAccount` → `AxoGateway` |
| `/api/v1/connections/oauth/start`, `/callback` | `AxoAccountManager` | `requireAccount` (account manager), then `AxoGateway` for the flow |
| `AxoHostDO` relaying `axo.connections.*` | `AxoAccountManager.connectionsCall` | `AxoGateway.connectionsCall` |
| bash to a Mac | `AxoAccountManager` → `AxoHostDO.callHost` | `AxoGateway` → `AxoHostDO.callHost` |

`requireAccount` stays with the account manager: a gateway never decides who is signed in.

### The account's Macs

A Mac is a connection named by its label (`studio`), with one tool, `bash`. The gateway needs the account's Macs to list connections and to route `bash`. It stores `gateway_macs(host_id, name)` and `gateway_meta.macs_version`.

- On every pair, rename or revoke, the account manager bumps its version and calls `gateway.macsChanged(version, macs)`. The gateway ignores any version not newer than its own.
- That push can be lost: a failed RPC, or the gateway restarting. So when the gateway serves a request whose list is older than a minute, it pulls `gatewayMacs()` again. A request naming a Mac it does not know also pulls once before failing with "no connection named".
- Revocation does not depend on the list. `revokeHost` closes the Mac's socket and marks it revoked in `AxoHostDO`, which refuses a revoked host's socket, as today. A stale list at most sends a command that `AxoHostDO` answers with "host offline; nothing sent".

### Moving connections state

`gateway_meta.imported` is false in a new gateway. The first request to a gateway whose `imported` is false runs the move inside `blockConcurrencyWhile`, so no other request runs until it ends:

1. **Export.** The gateway calls `accountManager.exportConnections()`. The account manager answers one of three ways:
   - `{ state: "snapshot", tables, head }`: every row of the connections tables, plus `head`, the hash of the newest chain event (or of the anchor, or null when there is no chain);
   - `{ state: "moved", head }`: it already handed off, recorded in `handoff`;
   - `{ state: "none" }`: an account that never had connections.

   Exporting changes nothing: the account manager keeps serving nothing, and keeps its rows.
2. **Store.** On `snapshot`, the gateway writes every row in one storage transaction, along with `imported = true` and `imported_head = head`. It then replays the chain (`CallLog.verify`). A chain that does not verify still lands, because the gateway does not discard records. It is reported in the log integrity result as broken at the point it broke, and logged as an error.
3. **Confirm.** The gateway calls `accountManager.confirmConnectionsMoved(head)`:
   - If `head` matches what the account manager would export now, it deletes its connections tables and records `handoff = { at, head }`, in one transaction.
   - If it does not match, it deletes nothing and answers `mismatch`. That can only happen if its rows changed after the export, which nothing should do; the gateway logs it.
   - A confirmation that fails or is lost is retried on the gateway's next request, from `imported_head`, until it is acknowledged. The gateway records the acknowledgement as `gateway_meta.confirmed = true`.
4. **Moved or none.** On `moved`, a gateway with `imported = false` has lost its storage, which Durable Objects do not do. It refuses connections requests with an error and logs the event, rather than starting empty and hiding the loss. On `none`, it sets `imported = true` and `confirmed = true` with no rows.

Failures:

- **Export fails or times out.** The request fails with "connections are moving; try again", and nothing has changed.
- **The gateway crashes before step 2 commits.** Nothing has changed.
- **The gateway crashes after step 2 commits.** It has the rows. The account manager still has its copy, but serves nothing from it. The confirmation retries.
- **The account manager crashes during confirm.** Its delete and its `handoff` record are one transaction: it has either both or neither.

At no point is a credential in neither object. After confirmation it is in exactly one.

### Failure semantics

- **The account manager is unreachable.** Sign-in checks fail, as today. Connections requests already past `requireAccount` still run in the gateway, using its cached Mac list.
- **The gateway is unreachable or resets.** Connections requests fail with "connections are unavailable" (HTTP 503), and RPC calls fail. Sign-in, login codes and Macs are unaffected. Scripts and calls in flight have unknown outcomes, as RFD0016 already says for a reset.
- **The Mac list is stale.** A newly paired Mac is unknown until the next push or pull, at most a minute. A revoked Mac is refused by its `AxoHostDO`.

### Invariants

1. **Credentials have one home.** After an account's move is confirmed, its sealed grants, tokens and client secrets are only in its `AxoGateway`. Before that, they are in the account manager, or in both during the move.
2. **Nothing is lost in the move.** Every row the account manager exported is in the gateway before the account manager deletes it. The gateway's chain after the move has the same head the account manager exported.
3. **Only the gateway calls out.** No other object holds a grant or calls a service on an account's behalf. The account manager makes no outside call.
4. **Logged before sent.** As RFD0016: a call's `start` record and chain event exist before it is sent.
5. **A revoked Mac runs nothing new.** It does not depend on the gateway's Mac list.
6. **One gateway per account.** It is named by the account ID. A gateway acts only for its own account: every grant it holds is sealed with that account's purpose, and every Mac it calls is one the account manager listed for it.

### Observability

- A `gateway.move` log line for each account, with its outcome (`imported`, `none`, `failed`, `mismatch`, `lost`), row counts, the chain head, and whether the chain verified.
- Gateway calls keep their RFD0016 traces. Each span gains `axo.gateway=true`.
- A count of requests that pulled the Mac list because a push was missing.

## Security and privacy

- **Smaller blast radius.** Code that parses untrusted service answers no longer shares storage with sign-in records and login codes. A bug in a gateway parser cannot read a login code, and a gateway reset does not drop sign-in checks.
- **The gateway decides nothing about identity.** `requireAccount` runs in the account manager, and the gateway trusts the account ID the Worker routed by. That is the same trust the account manager's connections code has today.
- **The move copies sealed rows only.** Nothing is unsealed in transit. RPC between Durable Objects of one Worker does not leave Cloudflare.
- **Inputs stay sealed in the call log.** The chain's tamper evidence carries over unchanged, with the same limit: it does not protect against someone who can rewrite the gateway's storage.

## Rollout

1. Add `AxoGateway: exports.durableObject({ storage: "sqlite" })` beside the other classes in `sites/axo.leostera.dev/cloudflare.config.ts`, and export it from `packages/axo-api-worker/src/index.ts` and `sites/axo.leostera.dev/src/index.ts`. `AxoAccountManager` keeps its deployed name, `AxoAccountDirectory` (`src/index.ts` exports it under that alias), so its objects and storage are untouched.
2. Move the code: `AccountConnections` and its parts into the gateway; the account manager keeps identity and gains `exportConnections`, `confirmConnectionsMoved` and `gatewayMacs`.
3. Switch routing, as in the table above, in the same deploy. There is no period where both objects serve connections: after the deploy, only the gateway does, and it imports first.
4. Deploy. Watch `gateway.move` lines until every active account has `imported`.
5. Next release: drop `exportConnections` once every account has confirmed. Keep `handoff` for good, as the record of the move.

Rollback before step 5 is a revert. An account the new code moved has its state only in its gateway, which the old code does not read. So a rollback after any account moved needs the reverse export. I'd rather not build that. Instead:
- deploy to a preview with a copy of an account's data first;
- keep step 5 for a later release, so a fix-forward can still export again if needed.

## Testing

- **Spec.** `specs/account-gateway.ts` models the move and routing, checking every invariant above under lost messages and crashes.
- **Moving an account.** A test signs in Gmail, adds an MCP server, makes calls, then restarts the runtime with the new code. The first request moves the account, and the test checks that:
  - grants still work;
  - the log and its integrity check are unchanged (same head, verified);
  - the account manager's tables are empty and it has a `handoff` record.
- **Move failures.**
  - Export failing leaves both sides unchanged.
  - A gateway crash after storing retries the confirmation.
  - A mismatched head deletes nothing.
  - `moved` with an empty gateway refuses.
- **Macs.**
  - A paired Mac is callable after the push.
  - A lost push is caught by the pull.
  - A revoked Mac with a stale list is refused by `AxoHostDO`.
- **Isolation.** The account manager's storage holds no `app_accounts` or `call_chain` after the move, and `verifySession` still answers while the gateway is mid-move or reset.
- **Existing suites.** The RFD0016 suites (`apps`, `third-party`, `connections`, `host-calls`) are pointed at the gateway and pass unchanged in behaviour.

## Drawbacks

- **One more hop for routing.** Paths that start at the account manager now take an extra RPC: the `bash` Mac list on a cache miss, and sign-in callbacks.
- **A Mac list in two places.** The account manager is the source, and the gateway holds a cache that can be up to a minute stale for new Macs.
- **A one-time move with its own failure modes, and no automatic rollback** once accounts have moved.
- **More surface to deploy and observe.** One more class, one more migration.

## Rationale and alternatives

### Do nothing

Connections stay in the account manager. The property the gateway is for, one place per account that holds credentials and makes calls, already holds. What does not hold is separation from identity, and every app we add widens the gap: more parsing, more memory, more code beside the login codes. Cheap now, and only harder later.

### A module boundary inside the account manager

Keep one object, but forbid connections code from touching identity tables, by lint rule or interface. This addresses ownership on paper, but not shared failure or memory, and nothing enforces it at runtime.

### A gateway per app or per provider

`AxoGoogleGateway`, `AxoMcpGateway`, and so on. This gives finer isolation, but:
- a script that calls Gmail and then Linear spans objects;
- the call log either splits per object or needs a coordinator;
- each object needs the Mac list.

The chain's "one sequence per account" becomes several chains. Not worth it before there is a reason.

### Stateless Worker with credentials in KV or D1

Calls would run in the request's Worker, with grants fetched from storage. That loses the single writer: refresh races, generation fencing and the ordered chain all depend on one object per account serializing writes.

### Move the Macs too

The gateway could own the account's Mac list outright, so it never asks. But pairing and revocation are identity decisions: who may act for the account. RFD0013 put them with the account. The gateway caching a list it does not own keeps that line clear.

### Move by dual-writing during a transition

Write to both objects for a release, then switch reads. That has more moving parts than a single copy-then-confirm, and the chain cannot be written in two places without two chains.

## Prior art

- **RFD0016** put connections in the account's Durable Object, and introduced the call log, and later its hash chain. This RFD keeps those decisions and moves where they run.
- **RFD0018** split the Mac socket out of the account manager into `AxoHostDO` for similar reasons: different load, different failure, different rate of change. It found the RPC hop cheap.
- **Credential brokers** such as HashiCorp Vault and AWS's credential providers keep secrets in a service that makes or signs calls, so callers never hold them. The gateway is that broker for one account, with the call log as its audit trail.

## Unresolved questions

### Before acceptance

- The class name: `AxoGateway`, `AxoAppGateway` or `AxoConnections`. This RFD uses `AxoGateway`, because it will also call token apps and Macs, not only apps.
- Should the gateway call `verifySession` itself for its HTTP routes, so a request cannot reach it unauthenticated even if the Worker's routing is wrong? That is defence in depth at the cost of one RPC per request. This RFD keeps `requireAccount` in the Worker, as today.

### During implementation

- The pull interval for the Mac list (one minute proposed), and whether to pull on every `connections_list` instead.
- Whether `exportConnections` needs paging. Thirty days of call log with sealed inputs can be several megabytes, near RPC message limits.

### Out of scope

- Anchoring the chain head outside the gateway.
- Per-app gateways.
- The token-app framework, which is the next RFD and lands in the gateway.

## Future possibilities

These are non-binding.

- Token apps (Hetzner, 1Password, Octopus Energy, Wise), a generic REST app and an OpenAPI bridge, all with credentials in the gateway.
- A browser bridge whose sessions live on a Mac, while the gateway holds which Mac and logs each step.
- Publishing the chain head to every Mac on each call, so tampering with the gateway's storage shows on the Macs too.
- A per-account budget for outside calls, enforced in the gateway.
