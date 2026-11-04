# RFD0031 - Axo: Durable Objects Wake on Demand

- Feature Name: `axo-durable-objects-wake-on-demand`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-04
- Updated: 2026-11-04
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md), [RFD0019](RFD0019-planned-restarts.md)

## Summary

A Durable Object runs only when something asks it to: a frame on one of its sockets, or a call from another object. None of them wakes itself to renew, poll or re-check. Four changes make delivery work that way:

1. **No leases.** A ClientDO subscribes to a HostDO once, when its client says hello, and stays subscribed until its socket closes. The ClientDO has no alarm.
2. **Read only what's new.** A ClientDO reads a Session from its SessionDO only when a notice says the Session's head is past what the client already has, or when the client asks for something.
3. **Notices go where they're needed.** A HostDO sends progress and epoch notices only to the ClientDOs that have that Session open. A failed notice is retried at once, then the full index is sent on the next one.
4. **Heartbeats stay on the HostDO.** A HostDO answers a host's heartbeat itself, and tells the account at most every ten minutes.

The account tells the ClientDOs following it when a Mac is paired or revoked, so the host list no longer depends on a renewal either.

## Motivation

On 2026-11-03 Axo made about 572k Durable Object requests for one person with two Macs and up to 17 clients. That is 17M a month, against 1M included in Workers Paid. Most of them did nothing new. Callee-side RPC calls that day, from Workers Observability:

| Call | Per day | What causes it |
|---|---|---|
| `AxoSessionDO.read` | 318k | Every ClientDO alarm (every 30 s) reads every open Session. Each sampled alarm made 6 to 24 reads, each with a row write first. There are 44 reads for every append. |
| `AxoClientDO.notify` | 123k | Every notice batch goes to every subscribed ClientDO, including progress for Sessions the client does not have open. |
| `AxoAccountDirectory.touchHost` | 17k | Every heartbeat (every 10 s per Mac) is a call and a row write on the account. |
| `subscribe` + `clientHosts` + ClientDO alarms | 21k | The 30 s lease renewal. |

The alarm also keeps every connected client's ClientDO awake 2,880 times a day, which is 63% of all Durable Object active time.

The renewal was there to heal what a lost message could leave behind: a lost notice, a lost acknowledgement, a lost subscription, a Mac paired after hello. Those are real, but each one has a cause someone can see, so each can be healed when it happens instead of every 30 seconds:

- A call between Durable Objects either returns or throws. The caller sees the failure, so it can retry while it is still awake.
- A WebSocket does not lose one frame and carry on. When a frame is lost, the socket is gone, both ends see it close, and the client reconnects and reopens what it holds.
- The account knows when a Mac is paired or revoked. It can say so.

## Guide-level explanation

### A client that is just watching

A tab has a Session open and nothing happens for an hour. Before this change its ClientDO woke every 30 seconds to renew its lease and read every open Session again. Now nothing runs: the socket hibernates, the ClientDO is not in memory, and nothing is billed.

### A reply streams in

axod sends a progress snapshot. The HostDO sends a notice only to the ClientDOs that have that Session open. Usually that is one tab, not every tab and Mac following the host. When the record lands, the HostDO sends a `session` notice with the new head to every follower, because every sidebar shows it. The ClientDO that has the Session open compares the head with what it sent and reads only the new records. The others update their index and read nothing.

### A notice that fails

A `notify` call throws. The HostDO tries once more at once. If that fails as well, it marks the follower as behind. The next time anything changes, that follower gets the whole index instead of the change. A ClientDO that says it has no socket is dropped.

### Pairing a second Mac

The account adds the Mac and tells every ClientDO following it to list its hosts again. The ClientDOs subscribe to the new HostDO, and their clients see the Mac at once. Before this change they saw it at the next renewal, up to 30 seconds later.

### A Mac's heartbeat

axod sends `axo.host.heartbeat` every 10 seconds. The HostDO answers it and renews its route, as before. It tells the account only when the account's last-seen time is more than ten minutes old.

## Reference-level explanation

### The rule

A Durable Object may run because:

- a frame arrived on one of its WebSockets;
- an RPC call or an HTTP request arrived;
- an alarm fired for a deadline that exists because something is in flight or overdue: a pending call's timeout, a fragment's reassembly timeout, or a host route whose heartbeats stopped.

It never sets an alarm to renew, poll, retry later or re-check state that hasn't changed. A retry happens in the invocation that saw the failure, while the object is awake anyway.

The HostDO's route alarm already follows the rule. Every heartbeat moves the alarm later, so it fires only when heartbeats stop. It stays.

### ClientDO

- **No alarm.** `alarm()` is removed. The ClientDO never calls `setAlarm`.
- **Subscribing.** `hello` and `refresh` call `AxoAccountDirectory.clientHosts(clientDO)`, which also records the ClientDO as a follower of the account. Then they call `HostDO.subscribe(clientDO)` on each host. A failed `subscribe` is retried once at once. `subscribe` takes no lease.
- **Letting go.** When the socket closes, the ClientDO calls `HostDO.unsubscribe(clientDO)` on each host it follows, and `AxoAccountDirectory.unfollow(clientDO)`.
- **Opening a Session.** `open` calls `HostDO.watch(clientDO, sessionId)`, which records the watch and returns the Session's current progress. It replaces `sessionProgress`. A Mac reading back its own archived Session (RFD0027) doesn't watch: it follows no HostDO for itself.
- **Closing a Session.** `close` calls `HostDO.unwatch(clientDO, sessionId)`.
- **Reads.** `pump(sessionId, head?)` reads from the SessionDO only when one of these holds:
  - the epoch moved;
  - no batch is outstanding, and the known head is past `sent`, or the head is unknown;
  - a batch has been outstanding for longer than `SYNC.stallMs` (30 s), which counts as a stall: it is sent again.

  A `session` notice carries the Session's head, so a ClientDO woken from hibernation by a notice knows the head without reading. An acknowledgement, an open, or an `older` request may still read: the client asked for it.
- **Read ids** live in memory. A read in flight keeps the object in memory, so a superseded reply can only arrive while the map is there. No row is written before a read.

### HostDO

- **Followers.** The `subscribers` table and its leases are replaced by:

  ```sql
  CREATE TABLE followers (client_do TEXT PRIMARY KEY, behind INTEGER NOT NULL DEFAULT 0);
  CREATE TABLE watchers (client_do TEXT NOT NULL, session_id TEXT NOT NULL, PRIMARY KEY (client_do, session_id));
  ```

  `subscribe` inserts a follower and returns the index, as before. `unsubscribe` deletes the follower and its watches. Rows are removed when the socket closes, or when `notify` answers `false` (the ClientDO has no socket, or no longer follows this host).
- **Routing notices.** `session`, `presence` and `label` notices go to every follower. `progress` and `epoch` notices go only to followers watching that Session. A follower with nothing to hear in a batch is not called.
- **Failed notices.** A `notify` that throws is retried once in the same flush. If the retry throws too, the follower is marked `behind`. The next flush to a behind follower carries every Session in the index, presence, and the progress of the Sessions it watches, then clears the mark.
- **Heartbeats.** `storeHostHeartbeat` answers locally. It calls `AxoAccountDirectory.touchHost` only when the last call for this connection is more than `SYNC.lastSeenMs` (10 minutes) old. That is the account's `lastSeenAt` resolution, and presence comes from the HostDO anyway.

### AxoAccountDirectory

- `clientHosts(clientDO?)` records the caller in a `followers` table.
- `unfollow(clientDO)` removes it.
- When a host is paired for the first time, or revoked, the account calls `AxoClientDO.hostsChanged()` on each follower. The ClientDO lists the account's hosts again, exactly as `refresh` does, and tells its client. A follower that answers `false` or throws is removed.

### Protocol constants

`SYNC.leaseMs` and `SYNC.renewMs` are removed. `SYNC.stallMs` (30 s) and `SYNC.lastSeenMs` (10 minutes) are added. The client protocol does not change: no client needs an update.

### Failure semantics, revisited

These rows replace the corresponding rows of RFD0018's table.

| Failure | Behaviour |
|---|---|
| A notice is lost (the call throws) | The HostDO retries at once. If that fails too, the follower gets the full index with the next notice. |
| A notice's ClientDO has no socket | `notify` answers `false`, and the HostDO drops the follower and its watches. |
| A subscription call throws | The ClientDO retries at once. If that fails too, the client sees that host when it next says hello or refreshes, or when the account says the hosts changed. |
| A frame on the client's socket is lost | The socket is gone. The client reconnects and reopens with `have`, as in RFD0018. |
| A client's acknowledgement is lost but its socket stays up | Not a WebSocket failure mode. If it happens, the batch is sent again the next time that Session's head moves or the client sends anything, once it is older than `SYNC.stallMs`. |
| A Mac is paired after hello | The account calls `hostsChanged` on its followers. |
| The ClientDO is evicted without its socket closing | The next notice finds no socket and answers `false`. |

### Invariants

RFD0018's invariants hold. Two are added:

1. **Idle is free:** with no frames from hosts or clients, no Durable Object runs.
2. **Reads follow changes:** a ClientDO reads a Session only when its head or epoch moved past what the client has, or when the client asks.

## Testing

- `specs/client-delivery.ts`: the renewal and the lease timer are removed. Lost WebSocket frames are modelled as a dropped socket that the tab reconnects. Failed notices, reads and subscriptions are retried at once. Progress goes only to a watching ClientDO. The properties are unchanged, `catchesUp` included.
- `specs/planned-restart.ts`: presence notices are calls that are retried, not renewed.
- `packages/axo-api-worker/tests/session-sync.test.ts`:
  - a connected client's ClientDO has no alarm;
  - progress reaches only the client with the Session open;
  - a Mac paired after hello reaches connected clients without `refresh`;
  - a heartbeat doesn't move the account's `lastSeenAt` within ten minutes.

## Drawbacks

- **A double failure leaves a client stale until the next change.** A notice that fails twice reaches its client with the next notice, or at the next reconnect, not within 30 seconds.
- **The account keeps a list of followers.** It is small (one row per open client) and cleaned up on close, or when a call answers `false`.
- **`lastSeenAt` is coarser:** up to ten minutes old while a Mac is online. Presence comes from the HostDO, so nothing that shows online or offline changes.

## Rationale and alternatives

- **Keep renewal, slower (10-minute leases).** This cuts the renewal cost but keeps the reads and notices that are the bulk, and still wakes every client's object 144 times a day for nothing.
- **Poll from the client.** The client would wake its ClientDO instead, with the same cost.
- **One socket per account instead of per client.** This would remove ClientDOs, but it is a much larger change to RFD0018, and every client would hear every Session's progress.
- **Do nothing.** About $2 a month today. It grows with every connected client: rows written alone reach the paid tier at about nine always-open clients.

## Unresolved questions

- Could a host's heartbeat skip waking the HostDO entirely, using `setWebSocketAutoResponse`, with liveness taken from the last automatic response? It needs a heartbeat axod sends as a fixed frame. Out of scope here.
