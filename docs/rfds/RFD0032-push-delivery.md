# RFD0032 - Axo: Push Delivery

- Feature Name: `axo-push-delivery`
- Status: Accepted; host sync from the index, release P and release 3 for the web app are implemented (2026-11-08)
- Author: leostera
- Start Date: 2026-11-05
- Updated: 2026-11-08
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md), [RFD0022](RFD0022-sessions-across-macs.md), [RFD0031](RFD0031-durable-objects-wake-on-demand.md)

## Summary

A client holds a WebSocket on each Mac's HostDO, and the HostDO pushes it the records it commits, straight from the append it has in hand. This is protocol 3. Frames a Durable Object sends on its own sockets are free. A call from one Durable Object to another is a billed request. So the billed work per record drops to the one SessionDO append, and the SessionDO is read only when the HostDO doesn't hold what a client is missing.

Five changes:

1. **Host sockets.** In protocol 3 a client opens Sessions on the HostDO of the Mac that owns them, over a socket to that HostDO. The HostDO delivers records, progress and resets on it. No ClientDO sits between them, and no `notify`, `watch` or `subscribe` is called.
2. **Push from the append.** When the SessionDO confirms an append, the HostDO sends the record to every socket with that Session open, and keeps recent records in memory. It reads the SessionDO only after it has forgotten them (it hibernated or was reset), or for a client that is behind.
3. **Open at the head for free.** Opening a Session the client already holds up to the index's head is answered from the index, with no read. A Mac following another Mac's Sessions (RFD0022) costs nothing to reconnect.
4. **Host sync from the index.** The HostDO answers axod's `axo.host.sync` handshake from its index when the index agrees with axod's manifest, instead of asking every SessionDO for its head. Two rules make that safe: rows are distrusted while a write is in flight, and SessionDO writes are fenced.
5. **The account socket stays.** The ClientDO keeps the client's account socket, for the host list and account events. In protocol 3 it follows no HostDO.

Protocol 2 keeps working, unchanged on the wire, for every client that hasn't updated. It ships in two releases: a preparatory one that makes rolling back safe, then protocol 3.

## Motivation

RFD0031 took Axo from about 25k Durable Object requests an hour to about 4.3k. Here is the hour after it was deployed (2026-11-04, 21:00 UTC), as measured in Workers Observability:

| Call | Per hour | Why it remains |
|---|---|---|
| `AxoClientDO.notify` | 748 | Each committed record or progress batch is one call per watching ClientDO. |
| `AxoAccountDirectory.touchHost` | 235 | A bug: the heartbeat throttle is kept in memory and lost on every hibernation. It is fixed separately. |
| `AxoSessionDO.read` | 228 | A ClientDO that receives a notice reads the records back, although the HostDO had them in hand. |
| `AxoHostDO.watch` | 126 | On every connect, axod's peer sync opens and watches about 150 of the other Mac's Sessions (`crates/axo-relay/src/peers/follower.rs`, `open_more`). |
| HostDO WebSocket frames | ~1,740 | Incoming frames, billed 20:1: about 87 requests. |

At about 1.2M requests a month, this is at the 1M included in Workers Paid. It grows with every client and every Session a client follows, because every hop between the record and the client is a billed call.

Measured again on 2026-11-08, by the ops-cost review, the case is stronger. Over the 24 hours to 14:00 UTC, about 112k billable requests a day, or 3.4M a month against the 1M included. Most of it is `AxoClientDO.notify` (about 73k a day, roughly 70% of RPC calls), then SessionDO `read` and `head` (about 10k a day each; `head` is the host-sync handshake) and `append` (4.6k). A busy hour (13:00 UTC) had 18.4k raw requests and about 10.4k billable; an idle one (07:00) about 570 billable. Under protocol 3 what is left is the appends, the account, and incoming frames at 1:20: about 12–15k a day, or 0.4M a month.

`touchHost` was about 2–3k a day where its throttle allows about 300: the throttle was kept in memory and lost on every eviction. It is now kept in the HostDO's SQLite, and registering counts as a touch (`tests/release-p.test.ts`). In idle hours the AccountDirectory and SessionDOs still answer about 130 requests an hour each that no traffic explains; that is not found yet.

Also, each reconnect of axod costs 300 to 600 requests. Its host-sync handshake asks every SessionDO of the Mac for its head (307 Sessions on the main Mac), although the HostDO's index already holds every head.

The shape is the problem. Today a record goes axod → HostDO → SessionDO (append) → HostDO → ClientDO (`notify`) → SessionDO (`read`) → ClientDO → client. Only the first SessionDO call is needed. The HostDO has the record, and the client could be listening on the HostDO itself.

## Guide-level explanation

### A reply streams in

The tab has the Session open on the Mac's HostDO. axod sends progress snapshots, and the HostDO sends each one on the tab's socket. axod appends the record. The SessionDO confirms it, and the HostDO sends the record on the socket, then clears the progress it completes. The tab acknowledges. One billed request (the append) delivered the record to every tab watching it.

### The HostDO hibernates mid-reply

Nothing is in flight, so the HostDO leaves memory. Its sockets stay connected, and its `client_opens` rows stay in SQLite. The next append wakes it. It pushes the new record from the append in hand. If a client's row says it is missing an earlier record the HostDO no longer holds, it reads that record from the SessionDO once.

### Opening the web app

The tab connects its account socket and gets the host list. For each Mac it opens a socket on that Mac's HostDO and says hello, and the HostDO answers with its index. The tab opens a Session with what it already holds (`have: { epoch, cursor }`). If that is the index's head, the HostDO answers at once, with no read. Otherwise it reads the window from the SessionDO.

### A Mac following another Mac

axod on Mac B keeps a socket on Mac A's HostDO and follows its index. It opens a Session only to show it, or to archive it. Reconnecting costs one hello, not 150 opens.

### axod reconnects

axod sends its manifest: every Session with the count and chain it last uploaded. The HostDO answers each one from its index when the row agrees and is verified. Only a Session where they differ costs a SessionDO call. A quiet reconnect of a 307-Session Mac drops from 300 to 600 requests to none.

### A forced code update

A Durable Object that doesn't hibernate within the deadline after a deploy is reset on the new code, and its sockets close. The clients and axod reconnect, as they do after any dropped socket. A deploy never strands anyone. See "Migration".

## Reference-level explanation

### What the HostDO keeps, and where

| Where | What | Survives hibernation | Survives a reset |
|---|---|---|---|
| SQLite | The index (head, epoch, count, chain, `verified` per Session), the fence, `client_opens` rows | yes | yes |
| Memory | Recent committed records per Session, progress snapshots, reads in flight | no | no |
| The platform | The client and axod sockets, with a serialized attachment (client id, connection number, protocol) | yes | no |

```sql
CREATE TABLE IF NOT EXISTS client_opens (
  socket_id TEXT NOT NULL,      -- the connection id in the socket's attachment
  session_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  sent INTEGER NOT NULL,        -- the last cursor sent on this socket
  acked INTEGER NOT NULL,       -- the last cursor the client acknowledged
  PRIMARY KEY (socket_id, session_id)
);
```

A pending call keeps the object in memory, so the HostDO hibernates only with nothing in flight. Memory is a cache: every decision can be rebuilt from SQLite and the SessionDO.

### The host socket (protocol 3)

Route: `GET /api/v1/account/hosts/:host/client`, a WebSocket upgrade signed in like `/api/v1/account/client`. The Worker checks that the host belongs to the caller's account, then forwards it to `AxoHostDO` with `X-Axo-Role: client`. `AxoHostDO` extends `AxoHostRelay`, which already accepts `client` sockets with a serialized `Peer` attachment, so this extends that role.

| Frame | Direction | Meaning |
|---|---|---|
| `axo.client.hello { protocolVersion: 3, clientId, connection }` | client → HostDO | `connection` grows with each connection the client makes. The HostDO keeps the newest socket per client and closes an older one with code 4000. It refuses a hello with a lower `connection` that arrives late. It deletes `client_opens` rows whose socket is gone. |
| index (the hello reply) | HostDO → client | Every Session's head, epoch and title, presence, and the progress of nothing. |
| `axo.client.session.open { sessionId, have }` | client → HostDO | Answered from the index if `have` is at the head, in the index's epoch. Otherwise the window is read from the SessionDO. The window carries `keep` when the epoch moved. |
| `axo.client.session.records { epoch, records, cursor }` | HostDO → client | One batch at a time per Session, sent only once the previous one is acknowledged. |
| `axo.client.session.ack { sessionId, cursor }` | client → HostDO | Moves `acked`, and sends the next batch. |
| `axo.client.session.progress { snapshot }` | HostDO → client | Sent only to sockets with the Session open. The client hides a snapshot once it holds the record the snapshot previews. A HostDO that hibernated can't clear it. |
| `axo.client.session.reset { epoch, keep }` | HostDO → client | The Session was cut back. The client drops what is past `keep`. |
| `axo.client.session.older`, `close`, `command` | client → HostDO | As in RFD0018 and RFD0024. `older` reads the SessionDO. |

`setWebSocketAutoResponse` answers client pings without waking the HostDO.

### Delivery rules

These are the rules `specs/sessions/push-delivery.ts` checks. Each one breaks a property when turned off.

- **pushFromAppend.** A confirmed append is sent to every socket whose row is at the record before it, from the line in hand. The record also goes into memory, so later acknowledgements can be served from it.
- **openAtHead.** An open whose `have` equals the index's head, in the index's epoch, writes a row and answers with no read.
- **retryAtOnce.** A read that throws is made again at once, while the object is awake.
- **staleReadsAreRedone.** A read answered in an older epoch than the index's is thrown away and made again. A truncate landed while it was in flight.
- **learnTheCut.** A row in an older epoch than the index's gets one read in its own epoch. The SessionDO answers with where the Session was cut. The HostDO doesn't always know this itself, because a truncate's answer can be lost.
- **sweepStaleRows.** A hello deletes the rows of sockets that no longer exist, so a row left by a forced reset never stands in for a live socket.
- **tabDropsRecordedProgress.** As above.
- **fenceOnVerify.** See the next section. It is also needed here: without it, an append sent by an instance that a reset ended can land after the new instance read the head, and that record never reaches the client.
- **Memory is per epoch.** When a head read shows that the epoch moved, recent records and progress are dropped. The model found that, without this, a record from before a cut could be pushed as a record after it.

### Host sync from the index

`axo.host.sync` today asks the SessionDO for the head of every Session in the manifest. In protocol 3 (and for every host, since the axod wire doesn't change) the HostDO answers a Session from its index when:

- the row is `verified`, and
- its count and chain equal the manifest's.

Otherwise it asks the SessionDO, and refreshes and verifies the row from the answer.

The hazard is an index that lags the SessionDO. A commit lands, then the HostDO is reset or loses the answer before it updates the row. If the Mac's file then shrinks back to exactly what the index says, the row agrees with the manifest while the SessionDO holds more. Nothing would ever ask the SessionDO again. `specs/sessions/sync-from-index.ts` found this. Two rules close it:

- **distrustWhileWriting.** Before a write (append or truncate) goes to the SessionDO, the row is marked unverified in SQLite. Only the SessionDO's answer verifies it again, whatever the outcome. A lost answer or a reset leaves the row distrusted, so the next handshake asks.
- **fenceOnVerify.** A write sent before a reset can still land after the new instance read the head. So the HostDO keeps a fence counter in SQLite, raises it on every head read, and passes it with every write. The SessionDO keeps the highest fence a head read carried, and refuses a write with an older one. axod hears such a refusal as the `conflict` (or `mismatch`) it already handles, by handshaking again.

A row is verified only by an answer that carries the SessionDO's fence. An answer from a SessionDO still on older code has no fence, and verifies nothing. During a rollout, Sessions whose SessionDO hasn't adopted the new code are asked, as today.

**Built (2026-11-08),** ahead of the rest, since it needs no new wire and no preparatory release: a rollback to code without it asks every SessionDO, as before, and ignores the new columns.

- `session_index.verified` and a `sync_fence` counter on the HostDO; `write_fence` on the SessionDO. Rows start distrusted, so the first handshake after the deploy asks every Session once.
- The handshake reads through `AxoSessionDO.syncHead(binding, fence)`, which raises the fence and answers the head with it, so an empty Session (whose `head` is null) can be verified too. A SessionDO still on older code had no `syncHead`, so during the rollout the HostDO fell back to `head`, which verified nothing. Once every SessionDO ran fenced code, that fallback was removed, and every write now carries a fence.
- Appends and truncates carry the HostDO's fence. A write with an older fence, or with none once any head read fenced, is answered `fenced`, which axod hears as `conflict` (append) or `mismatch` (truncate). The check runs again inside the commit transaction, because a head read can land while an append awaits its hashes.
- Every write's answer carries the SessionDO's fence. If it is above the HostDO's, the HostDO adopts it. A SessionDO only ever holds a fence its HostDO gave it, so this changes nothing unless the HostDO lost its counter. If it had, every write would be refused while the index kept answering.
- An answer from the index carries no `heads`: the index doesn't keep them, and axod doesn't read them (`Uploader::handshake`).
- `host_sync` events now say how many Sessions were `read`, so the saving shows in Workers Observability.
- Tests (`tests/session-sync.test.ts`): a quiet reconnect raises no fence; a lagging, distrusted row is read rather than trusted; a write from before a head read is refused as a conflict, and the next one lands.

### The ClientDO in protocol 3

`hello { protocolVersion: 3 }` on the account socket answers with the host list only. The ClientDO follows the account, as in RFD0031, and passes on pairing changes. It does not subscribe to HostDOs, read Sessions or relay records. In protocol 2 it behaves as today.

### Mac peers (RFD0022)

axod's peer sync connects to each other Mac's HostDO with its host credential (`/api/v1/accounts/:account/hosts/:host/peers/:target/client`), and follows the index. It still keeps a copy of every Session that isn't archived (RFD0022), but it opens each one with `have`, so a Session it already holds to the head costs no read. Commands go to the HostDO of the Mac they name. This Mac's own HostDO is opened only to fetch back an archived Session (RFD0027).

### Cost

Per record: one SessionDO append, plus a read only after hibernation or for a lagging client. Per reconnect: one hello per Mac, with reads only for Sessions behind. Per axod reconnect: SessionDO calls only for Sessions that changed while it was away. Based on the hour above, `notify`, `watch` and most reads go away, about 1,100 of the 1,330 RPC calls. The total falls under 1,000 requests an hour while Macs are active, and near zero when idle.

Measured on 2026-11-08, by hour (UTC), from GraphQL `durableObjectsInvocationsAdaptiveGroups` split by `type`, with incoming WebSocket frames (`hibernation`) billed at 1:20. Protocol 3 reached every client by 18:00: release 0.38 moved axod's peer sync, and phone builds 28 and 29 moved the phone, on top of the web app's release 3.

| Hour | Raw requests | Billable | ClientDO RPC | SessionDO RPC |
|---|---:|---:|---:|---:|
| 13 (protocol 2) | 18,395 | 9,595 | 6,183 | 2,436 |
| 14 (protocol 2) | 22,846 | 11,745 | 8,226 | 2,043 |
| 17 (protocol 2) | 13,613 | 6,722 | 4,884 | 865 |
| 18 | 5,912 | 862 | 23 | 182 |
| 20 | 7,719 | 787 | 23 | 176 |
| 21 | 3,188 | 355 | 14 | 91 |

HostDO frames were about as many before and after (5–7k an hour), so the activity is comparable. Billable requests fell by about 90%, to roughly 15k a day, or 0.45M a month, under the 1M included. What is left, per hour: HostDO frames (about 250 billable), SessionDO appends and translation alarms (about 200), and the account directory (about 100: `touchHost` once per 10 minutes per Mac, and the `authorizeHost`, `verifySession`, `follow` and `unfollow` of each socket opened).

## Migration

Durable Objects adopt a deploy one by one. Each takes the new code when it next wakes after hibernating, or is reset onto it after the deadline (5 minutes by default). A hibernated WebSocket survives the switch, and its next frame goes to whatever code the object runs then. A rollback works the same way. Clients update when they update: a tab runs the JavaScript it loaded, and the Mac and iPhone apps run the build they have. `specs/sessions/push-migration.ts` models this mix.

### Release P (preparatory)

Ships first, and is the oldest release a rollback may go to once protocol 3 has run.

- The HostDO tolerates the new SQLite state. It creates `client_opens` and the fence and `verified` columns idempotently, and ignores them.
- When it wakes, a HostDO closes every client socket it doesn't own: one whose attachment says protocol 3. Without this, a rollback leaves protocol 3 clients on sockets that nothing writes to (the model's `closeUnknownSockets`).
- Schema changes are gated behind a stored schema version, applied once per object instead of on every wake (from the RFD0031 backlog). Every change is additive, so release P and release 3 read each other's tables.

**Built (2026-11-08).**

- `src/schema.ts` `migrate` applies a Durable Object's schema steps once each and stores how many in `schema_version`. The HostDO and SessionDO use it. Each step is idempotent, so an object from before the version existed runs them all once and keeps what it holds. A stored version past a release's steps was written by a newer release and applies nothing.
- The HostDO's third step creates `client_opens`. Nothing reads it yet.
- `AxoHostRelay.owns(attachment)` says which sockets an object serves. The HostDO serves only its daemon's. A socket it doesn't serve is closed with 4010 "Protocol not served" (`UNOWNED_CLOSE`) when the object is constructed, and ignored until then: its frames get no answer, and it never counts as a socket for presence, routes or alarms. Before this, one socket with an attachment the strict `peerSchema` refused made every socket lookup throw, so the Mac's own calls failed with "Outcome unknown".
- Tests (`tests/release-p.test.ts`, with `tests/fixtures/foreign-sockets.ts` standing in for release 3): a daemon keeps syncing with two foreign client sockets on its HostDO, and a wake closes them and keeps the daemon's; the schema is applied once, again after its version is lost, and not at all under a newer version.

### Release 3

- The HostDO serves host sockets, pushes, and answers host sync from the index. The SessionDO keeps and checks the fence.
- The ClientDO accepts `hello` 3, and keeps protocol 2 unchanged.
- The web app tries protocol 3, and falls back to protocol 2 for that connection when:
  - the account socket answers `hello` 3 with invalid params (old code), or
  - the host socket is refused or closes before its index arrives.
- Protocol 2 frames keep their exact shape. The web app's schemas are strict, so a field added for protocol 3 would break every tab still on protocol 2 (the model's `frozenWire`).

**Built (2026-11-08).**

- `src/host-clients.ts` `HostClients` serves protocol 3's client sockets on the HostDO. The Worker's `GET /api/v1/account/hosts/:host/client?clientId=` checks that the signed-in account owns the host (one account call, as protocol 2's `subscribe` was) and forwards with `X-Axo-Role: direct-client`. The relay base leaves such sockets to the subclass (`keeps`).
- The host socket carries protocol 2's frames unchanged (`sessions`, `session.open`, `records`, `ack`, `older`, `progress`, `reset`, `close`, `command`, `axo.elicitation.*`), plus `hello { protocolVersion: 3, clientId, connection }`, whose answer is the index and presence, and two notifications: `axo.client.host.presence` and `axo.client.host.label`.
- One `pump` per socket and Session sends the next batch once the last is acknowledged: from `RecentRecords` when they hold it (the append just committed puts its records there first), else read from the SessionDO. A cut this HostDO made resets the rows in the epoch before it with no read; a row further behind reads once in its own epoch. A failed read is made once more at once; a read answered in an older epoch than the index's is made again.
- `client_opens` is created again by a fourth schema step, with a nullable epoch (a Session with no records yet) and `sent_at` for `SYNC.stallMs`. Release P's table was never written.
- The account socket answers `hello 3` with the hosts, each listed offline, and no Sessions; it follows no HostDO, and refuses what the host sockets carry with -32601.
- `@axo/app`'s `AccountConnection` speaks protocol 3 by default, behind the same calls and events. It opens a socket per host, merges each one's presence and name into the host list, routes each call to the host it names, and closes the whole connection when any socket closes. It falls back to protocol 2 when the account socket refuses `hello 3` with -32602 or a host socket fails before its index arrives. Each connection is numbered above the last, from the clock, so a late hello of an old one is refused.
- A paired Mac reaches another Mac's HostDO at `GET /api/v1/accounts/:account/hosts/:host/peers/:target/client`, signed in with its host credential as `/peers` is, and checked against the account's hosts; its own host is allowed, for reading back its archived Sessions (RFD0027). Its socket is not a person's (`person: false` in the attachment): it never hears what a Mac asks, and its answers are refused with `notAPerson` (RFD0029).
- axod's peer sync speaks protocol 3 (`crates/axo-relay/src/peers/follower.rs`). The account socket says `hello 3` and lists the Macs; the follower opens a socket per Mac on the peer route (`peers/socket.rs`: one task per socket, each rate-limited to 30 frames a second), merges each HostDO's presence and name into `peers.json`, stamps the HostDO's rows with its Mac, and routes opens, acknowledgements, closes and commands by Mac. Any socket closing ends the connection, which reconnects. A connection that fails before every Mac has said hello falls back to protocol 2 for ten minutes (`RELAYED_AFTER_REFUSAL`), then tries 3 again; one that fails to connect at all doesn't count, so a network outage never demotes it.
- The phone speaks protocol 3 (`apple/AxoClient/Sources/AxoClient/Remote/AccountConnection.swift`), as `@axo/app` does: `hello 3` on the account socket, then a socket per host on the client route, each said hello with a connection number from the clock. Each host's presence and name are merged into the listing, and opens, acknowledgements, closes, commands and answers go to the host they name. A question asked while the indexes come in waits for the listing. A command for a host with no socket answers -32005, as the ClientDO does for one it can't reach. Any socket ending ends the connection. A refused `hello 3` (-32602), or a host socket failing before its index, sends the connection back to protocol 2 for ten minutes. The Mac app doesn't use the account socket: it sees other Macs through axod's peer sync.
- Tests: `apple/AxoClient/Tests/AxoClientTests/DirectAccountConnectionTests.swift`, with fake account and host sockets: the merged listing, numbered connections, routing, presence and names, questions held for the listing, the offline answer, both fallbacks, and a host socket ending the connection.
- Tests: `tests/axod-peers.test.ts` runs the real axod against the Worker. It checks that axod reaches protocol 3 (`event=peers.direct_ready`), keeps the copies and fetches its own archived Session back, and that a command reaches the Mac it names and is answered. With `tests/fixtures/without-peer-route.ts`, a Worker without the peer route, it falls back to protocol 2 and keeps the copy.
- Tests: `tests/push-delivery.test.ts` against the Worker, with `tests/fixtures/counting-reads.ts` counting SessionDO reads: an open at the head and every pushed record read nothing; a tab that opens behind reads once; a cut arrives as a reset with no read; protocol 2 and 3 tabs both get the record and protocol 2's frames keep their keys; commands, newest-connection-wins, ownership, reconnect after a reset, what a Mac asks, and presence. `packages/axo-app/test/remote-api.test.mjs` covers routing, merging and both fallbacks.

### Order

1. Deploy release P from `main`. Wait until every HostDO has adopted it: axod's heartbeats wake each HostDO within seconds, and a reset follows within 5 minutes.
2. Deploy release 3. Clients move to protocol 3 as they reconnect. The deploy itself disconnects no one, except objects that the deadline resets.
3. Update axod's peer sync (done) and the phone (done) to protocol 3 in their own releases. Until then they use protocol 2 against the same HostDO index.
4. Remove protocol 2 only after no client has said `hello` 2 for a set period. That is a later RFD.

### Rolling back

Go back to release P. HostDOs that adopt it close their protocol 3 sockets. Those clients reconnect, find protocol 3 refused, and fall back to protocol 2. SessionDOs on release P ignore the fence. Host sync on release P asks every SessionDO, as today, so the index is never trusted without the fence.

## Testing

### Specs

| Spec | What it checks | Result |
|---|---|---|
| `specs/sessions/push-delivery.ts` | One tab and one Session on a HostDO that hibernates, is reset, and loses answers. Properties: noGapsNoDuplicates, holdsWhatTheCloudHolds, oneBatchOutstanding, progressEndsWithItsRecord, catchesUp, readsOnlyAfterForgetting, opensAtHeadReadNothing. 6 scenarios. | Every safety property holds in every state within 24 events with no faults (28M states), and within 14 events with one fault (15.5M states). `catchesUp` holds as far as those depths reach. These are bounded checks, not proofs. With one fault, at depth 16, nothing broke in the 37M states explored before the memory limit. Each rule is needed except sweepStaleRows and tabDropsRecordedProgress. For those two, the search stopped before it could show whether they are needed. |
| `specs/sessions/sync-from-index.ts` | axod, HostDO and SessionDO through rewrites, lost answers and resets mid-write. Properties: believesOnlyWhatIsThere, converges, quietHandshakesAskNothing. | Proved with up to two faults on a path (250k states, every path explored). Each rule is needed. |
| `specs/sessions/push-migration.ts` | Deploy and rollback across the ClientDO and HostDO adopting code at different times, with clients on protocol 2 or 3, and a forced update. Properties: neverBroken, keepsHearing. | Proved with one fault (3.4M states). closeUnknownSockets, fallBackToTwo and frozenWire are each needed. |

### Worker tests

In `packages/axo-api-worker/tests/`, each against the real Worker in the harness:

- a protocol 3 tab gets a committed record with no SessionDO read (count the calls);
- a reopen at the head reads nothing;
- a protocol 2 tab and a protocol 3 tab both get the record, and the protocol 2 frames match today's byte for byte;
- host sync on a quiet reconnect makes no SessionDO call;
- a write with a stale fence is refused, and axod's handshake recovers;
- a HostDO restarted with `h.restart` (a reset) mid-append converges;
- release P closes a socket whose attachment says protocol 3.

### Rollout checks

After each deploy, check that:

- Worker errors stay at zero;
- `client_stalled` and `sync.diverged` don't rise;
- total Durable Object requests per hour fall as clients reconnect;
- protocol 2 clients still receive records.

## Drawbacks

- **More sockets per client.** A client holds one socket per Mac, plus the account socket. Each is a hibernated WebSocket, which costs nothing while quiet. The client handles reconnecting for each one.
- **The HostDO does more.** It serves every client of its Mac. One person's clients are a handful, far from a single object's limits. An account with many viewers per Mac would need fan-out, which is out of scope here.
- **Two protocols until the native clients update.** Protocol 2 code stays, tested, for a while.
- **Cold SessionDOs translate again.** Protocol 3 keeps the HostDO warm, but a SessionDO is touched only to append, so between replies it is often evicted. An append to an evicted SessionDO rebuilds its ATXF stream in an alarm (RFD0035): one more request, and a read of the whole Session. So "one append per record" is slightly low for large Sessions with pauses of minutes: at worst about +4% requests, well inside the included GB-s and rows read.
- **The fence adds a write.** Every head read during host sync writes the fence on the HostDO and the SessionDO. Head reads happen only for rows that aren't verified, so this is rare.

## Rationale and alternatives

- **Keep protocol 2, and put records in notices.** This removes the reads but keeps one billed `notify` per record per watcher, and the ClientDO hops.
- **One socket per account on an account-level object.** That object would hear every Mac's traffic and become the bottleneck. It would also need its own copy of each Mac's index.
- **Let the ClientDO hold a socket to each HostDO.** Traffic between two Durable Objects is billed whichever way it travels, so this keeps a billed hop per record. It is today's design with a different transport.
- **Answer host sync from the index without the fence.** The model shows a reset mid-write leaves a Session that never converges.

## Unresolved questions

- Should axod's heartbeat become a fixed frame, so that `setWebSocketAutoResponse` answers it without waking the HostDO? This would make an idle Mac free too. Presence would then come from the auto-response timestamp. Measured, not yet: a quiet Mac's HostDO takes 600–700 frames an hour, its heartbeats every 10 seconds and its peers' traffic, which is 30–35 billable requests. The lease renews on any frame, so the change would save only that much and would move presence onto a timestamp the code doesn't read today. It is worth revisiting if the number of Macs grows.
- How long should protocol 2 be kept after the native apps update? Until a week of evidence says nothing speaks it: [RFD0036](RFD0036-retiring-protocol-2.md).
