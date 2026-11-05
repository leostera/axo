# AXP v0.1 specification

**Status:** draft. The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119.

## 1. Introduction

### 1.1 The problem

Coding agents run in isolation. A session lives in one process, on one machine, usually in one terminal, and only the person at that terminal can see or steer it. Once a session ends, a transcript file can be shared, and [ATXF](https://atxf.leostera.dev) makes those files portable between agents. A transcript, though, is a record of the past. What is missing is a way to work with a session while it is still running:

- **Controlling a session from elsewhere is hard.** Sending a prompt from a phone, stopping a turn from a browser, answering the question an agent is waiting on from another computer: each needs a path to the machine running the agent, and an answer to "did it run?" when the network drops at the wrong moment. Resending a prompt whose outcome is unknown can run it twice; not resending can lose it.
- **Replicating a live session is hard.** Everyone watching a session needs the same log, in the same order, as it is written. A copy has to resume after any disconnect from exactly where it stopped, page back through history it never fetched, and detect a relay that drops or alters records.
- **Knowing what is running where is hard.** Which machines exist, which sessions run on each, which are working and which are waiting for a person, and whether a machine that went quiet crashed or is restarting on purpose.
- **Machines cannot reach each other.** Laptops sit behind NAT and phones change networks, so something in the middle has to relay. That relay should be able to keep copies and route commands without being able to forge what an agent said.
- **Letting a new device in is hard to do safely.** Pairing a phone or a second computer with an account should take a short code, not a password or a shared secret that then travels on every connection.
- **Every tool solves this alone.** Each product that steers agents remotely invents its own wire format, tied to one agent and one product, so nothing works with anything else.

### 1.2 The approach

AXP solves these once, for any agent:

- A Session's log is an ATXF transcript with integrity. Only the machine running the Session writes it. Every copy describes what it holds with the values of an ATXF seal and receives exactly what it is missing, and every reader verifies every record, so a relay cannot forge, reorder or drop records unnoticed (§9).
- Commands carry an id and run at most once, so a client can always resend after an unknown outcome. The records a command produces carry that id, covered by their hashes, so the client knows when it took effect (§10).
- A hub relays between machines that cannot reach each other, keeps a copy of every log, and routes commands it does not need to understand (§2, §10.1).
- Devices join an account with a single-use code and prove themselves with keys they never export (§6).
- A small core carries all of this. Everything specific to an agent, a terminal or a product is an extension, negotiated per connection (§15).

The JSON Schema in [`schema/v0.1/axp.schema.json`](schema/v0.1/axp.schema.json) defines the parameters and results of every core method. This document defines everything a schema cannot express: who may send what, in which order, what each side stores, and what happens when things fail. Extensions are specified in [`extensions/`](extensions/).

## 2. Model

AXP moves live agent Sessions between the machine that runs them and the people and programs that watch and steer them.

| Role | Does | Stores |
| --- | --- | --- |
| **Host** | Runs agent Sessions. Is the only writer of each Session's log. Runs commands. | Its Sessions' logs. |
| **Hub** | Holds accounts. Connects hosts and clients that cannot reach each other. Routes calls to hosts. | Accounts, devices, the directory, a replica of every log. |
| **Client** | Shows Sessions. Sends commands. | Whatever it chooses to cache. |

- An **account** is a set of devices that trust each other. It exists at a hub.
- A **device** is a host or a client that has been paired with an account (§6). It holds an Ed25519 key.
- A **Session** is one agent conversation running on one host. Its state is a **log**: an ATXF transcript (§9) that only its host appends to.
- A **replica** is any copy of a log other than the host's. A hub keeps one of every log; a client MAY keep any.
- A **command** is a call that changes a Session (§10). It runs at most once and its effect shows up in the log.
- **Ephemeral state** is per-Session data that matters only while it is current, such as the reply being written (§11). It is never stored.

A client MAY talk to a host directly, for example over a local socket, or through a hub. Every core message means the same in both cases. A hub serves a client the same methods a host would, from its replicas and by routing to hosts, so a client cannot tell the two apart except that a hub still answers while a host is offline.

## 3. Conventions

- Messages are [JSON-RPC 2.0](https://www.jsonrpc.org/specification), encoded as UTF-8 JSON.
- Object members not defined by this specification or a negotiated extension MUST be rejected, except under `ext` (§15).
- Identifiers:
  - `hostId`, `generation`, `sessionId`, `account` and `device` are lowercase UUIDs ([RFC 9562](https://www.rfc-editor.org/rfc/rfc9562)). Hosts generate `hostId`, `generation` and `sessionId` themselves, with version 4 or version 7 UUIDs.
  - `commandId` is 8 to 64 characters from `A-Z a-z 0-9 _ -`. Clients generate it, with at least 96 bits of randomness.
  - Extension identifiers are described in §15.
- Times are [RFC 3339](https://www.rfc-editor.org/rfc/rfc3339) strings in UTC, as in ATXF. Receivers MUST NOT rely on clocks for ordering.
- Binary data is base64url without padding ([RFC 4648 §5](https://www.rfc-editor.org/rfc/rfc4648#section-5)) unless a field says otherwise.
- Hashes are ATXF hashes: `"sha256:"` followed by 64 lowercase hex digits.
- In this document `→` reads "sends to". `client → hub` means the client sends the request and the hub answers it.

## 4. Transports

AXP runs over any reliable, ordered transport. Two framings are defined:

- **Stream framing**, for byte streams such as Unix domain sockets and TCP: each message is one line of JSON terminated by `\n` (LF). A message MUST NOT contain a raw LF.
- **Message framing**, for message transports such as WebSocket: each message is one text frame. Batches (JSON-RPC arrays) MUST NOT be used.

Either side of a connection MAY send requests; a host that connected to a hub answers the hub's requests on the same connection. Responses MAY arrive in any order and are matched by `id`. Notifications MUST be processed in the order they arrive.

### 4.1 Message size and fragments

Each side announces `limits.messageBytes` in `axp.hello` (§5), the largest message it accepts whole. A message larger than the receiver's limit MUST be sent in fragments:

1. The sender serializes the message, takes its UTF-8 bytes, and cuts them into parts of at most `limits.fragmentBytes` bytes.
2. Each part travels as an `axp.fragment` notification: `{ "message": <id>, "part": <0-based index>, "parts": <total>, "priority": <class>, "data": <base64url bytes> }`. `message` is a string the sender has not used on this connection.
3. The receiver concatenates the parts of a message in index order and processes the result as if it had arrived whole.

A sender that gives up on a fragmented message part-way MUST send `axp.discard` `{ "message": <id> }`. A receiver MUST drop a partial message that receives no part for 60 seconds, MUST ignore parts of messages it dropped, and MUST close the connection if a message would exceed `limits.maxMessageBytes` once assembled.

Every message has a **priority class**: `control` (responses, errors, connection and trust methods), `durable` (log records) or `ephemeral` (slots, terminal output). A sender SHOULD send queued messages in class order, and MAY interleave the fragments of messages of different classes, so that a large log batch never holds back a response. Within one class, messages MUST be sent in order.

## 5. Connections

A connection starts with `axp.hello` from the side that opened it. No other method MAY be sent before the hello response, except `axp.pair.redeem` (§6.3).

```json
{"jsonrpc":"2.0","id":1,"method":"axp.hello","params":{"axp":"0.1","role":"client","device":"7a4c1f0e-2b1d-4c0a-9a55-0d2f6c8e1b3a","extensions":{"agent":"0.1","terminal":"0.1"},"limits":{"messageBytes":1048576}}}
```

- `axp` is the protocol version the sender speaks. A receiver that does not speak it MUST answer with error `-32100` (§13) carrying the versions it does speak in `data.versions`, and close.
- `role` is `host`, `client` or `hub`. Only a hub accepts `host` and `client`; a host accepts only `client` on a local socket (§6.1).
- `device` names the paired device. It is omitted on local sockets.
- `host` is present when `role` is `host`: `{ "hostId", "generation", "kind", "label" }` (§7).
- `extensions` maps each extension identifier the sender implements to its version.
- `limits` holds the sender's limits (§14). Omitted limits take their defaults.

The response:

```json
{"jsonrpc":"2.0","id":1,"result":{"axp":"0.1","role":"hub","challenge":"rK3nY0b8Q2m5vX1cT7hZ4uW9eA6sD0fG2jL8pN5qR1o","extensions":{"agent":"0.1"},"limits":{"messageBytes":65536}}}
```

- `extensions` in the response is the **negotiated set**: each extension both sides implement, at a version both speak. A peer MUST NOT send a method, notification or field of an extension outside the negotiated set; the receiver MUST answer such a request with `-32601` (method not found).
- `challenge` is 32 random bytes, present when the receiver requires `axp.auth` (§6.2). Until `axp.auth` succeeds the only method the sender may call is `axp.auth`.
- Each side applies the other's `limits` to what it sends.

`axp.bye` `{ "reason": <string> }` is a notification either side MAY send before closing. `axp.ping` (empty params, empty result) MAY be sent by either side at any time after hello to check the connection.

When a connection closes, every request without a response on it has an unknown outcome. Subscriptions, open logs (§9.3) and partial fragments of that connection end with it.

## 6. Trust

### 6.1 Local peers

On a Unix domain socket, the host trusts a client whose effective user is the host's own user, as reported by the operating system (for example `SO_PEERCRED` or `getpeereid`). The socket MUST be created with permissions that prevent other users from connecting. Local clients skip `axp.auth` and act on behalf of the account the host is paired with, if any.

### 6.2 Device authentication

Every device holds an Ed25519 key pair ([RFC 8032](https://www.rfc-editor.org/rfc/rfc8032)) that it generated itself and never exports. The hub knows each device's public key from pairing.

After the hello response carries a `challenge`, the device signs the octets of

```text
"axp/0.1/auth\n" || challenge || "\n" || device || "\n" || hub
```

where `challenge` is the 32 decoded bytes, `device` the device UUID as ASCII, and `hub` the hub's origin as the device dialled it (for example `wss://hub.example`), and sends `axp.auth` `{ "signature": <base64url, 64 bytes> }`. The hub verifies the signature with the device's public key and answers `{ "account", "device", "role" }`. A failed `axp.auth` is answered with `-32001` and the connection closed. Binding the signature to the hub's origin stops a malicious hub from relaying a challenge to another hub.

A hub MUST NOT accept a `role: "host"` connection from a device paired as a client, nor the reverse, and MUST NOT accept a `host.hostId` other than the one bound to that device at pairing.

### 6.3 Pairing

A new device joins an account with a **pairing code** issued by a device already in it.

1. A device of the account calls `axp.pair.create` `{ "role": "host" | "client", "label"? }` → hub. The hub answers `{ "code", "uri", "expiresAt" }`.
2. The new device generates its key pair and opens a connection to the hub named in the URI. Its first and only request is `axp.pair.redeem` `{ "code", "publicKey", "role", "kind", "label", "hostId"? }`. `hostId` is required when `role` is `host`.
3. The hub checks the code, creates the device, binds `publicKey` (and `hostId`) to it, answers `{ "account", "device", "pairedAt" }`, and closes the connection.
4. The device stores `account`, `device` and the hub's origin with its key, and connects again with `axp.hello` and `axp.auth`.

Codes:

- A code is 8 characters from Crockford's base32 alphabet (`0-9 A-H J K M N P-T V-Z`), shown as two groups of four separated by `-`, for example `7KQ2-M9XD`. That is 40 bits.
- Receivers MUST accept lowercase letters and MUST map `O` to `0` and `I` and `L` to `1` before checking.
- A code MUST expire within 10 minutes of issue and MUST be accepted at most once, whether or not the redemption succeeds after the code is matched.
- A hub MUST store a code only as a keyed hash (for example HMAC-SHA-256 under a hub secret), MUST rate-limit redemptions globally and per network source, and MUST rate-limit issuance per account. Failed redemptions are answered with `-32040` and do not reveal whether a code exists.
- The **pairing URI** is `axp://<hub-authority>/pair/<code>`. A device that opens it connects to `wss://<hub-authority>/axp` unless it has been configured otherwise.

An unauthenticated connection MUST be closed after `axp.pair.redeem` is answered, and after 30 seconds if it has not sent one.

### 6.4 Devices and revocation

- `axp.devices.list` (any device → hub) answers `{ "devices": [Device] }`, each `{ "device", "role", "kind", "label", "hostId"?, "pairedAt", "lastSeenAt" }`.
- `axp.device.revoke` `{ "device" }` (any device → hub) removes a device from the account. The hub MUST forget its public key, MUST close its open connections with `-32002`, and MUST answer later `axp.auth` attempts from it with `-32001`. A revoked host's Sessions stay in the directory with `presence: "offline"` until the account removes them.

How the first device of an account is created (for example by signing in with an identity provider in a browser) is not specified by AXP.

## 7. Hosts

A host has:

- `hostId`: stable for one installation, bound to the host's device at pairing.
- `generation`: new every time the host process starts. Every routed call names the generation it expects (§10.1), so nothing reaches a process that has since restarted.
- `kind`: an open slug matching `^[a-z][a-z0-9-]{0,63}$` that names the kind of machine, such as `macos` or `linux`. Clients MUST NOT reject unknown kinds.
- `label`: what people call it, 1 to 128 characters with no control characters.

A host connected to a hub sends `axp.host.announce` once after `axp.auth`, and again whenever it wants the hub to recheck everything:

```json
{"jsonrpc":"2.0","id":3,"method":"axp.host.announce","params":{"sessions":[{"sessionId":"…","metadataVersion":4,"metadata":{…},"status":"ready","log":{"count":120,"chain":"sha256:…"}}]}}
```

The hub answers `{ "sessions": [{ "sessionId", "log": Offer | null }] }`: for each Session, what its replica holds (§9.1). The hub then opens each log whose replica is behind (§9.3). Sessions the hub knows that are missing from the announcement are kept, with metadata `archived: true`. The announcement replaces the host's directory entry atomically.

**Presence** is `online` while the host has an authenticated connection, `offline` otherwise, or a value an extension defines (such as `restarting`, see the `upgrade` extension). The hub records `lastSeenAt` when a host disconnects. An offline host keeps its directory entry and its replicas.

`axp.host.rename` `{ "hostId", "label" }` (client → hub) sets the label shown to the account. An empty `label` returns to the host's own.

## 8. Sessions and the directory

A Session has:

- `hostId` and `sessionId`. `sessionId` is the `id` of its log's ATXF header.
- `metadata`, owned by the host:
  - `name`: string of 1 to 80 characters, or `null`.
  - `createdAt`: time.
  - `lastActivityAt`: time of the last completed user or agent message, or `null`.
  - `archived`: boolean. Sessions are never deleted through AXP.
  - `agent`: the ATXF `source.agent` of its log, or `null` before the log exists.
  - `ext`: extension metadata (§15).
- `metadataVersion`: a positive integer the host increases on every metadata change. A receiver MUST ignore metadata whose version is not greater than the one it holds.
- `status`: `starting`, `ready` (waiting for input), `working`, `needsAttention` (waiting for a person, such as a question or an approval) or `unavailable` (the agent is not running).
- `log`: the host's Offer (§9.1), or `null` while the log does not exist.

The host reports changes with `axp.session.update` `{ "sessionId", "metadataVersion"?, "metadata"?, "status"?, "log"? }` → hub, answered with `{ "applied": boolean }`.

Clients read the directory with:

- `axp.hosts.list` → `{ "hosts": [Host] }`, each `{ "hostId", "generation" | null, "kind", "label", "presence", "lastSeenAt", "extensions" }`.
- `axp.sessions.list` `{ "hostId"? }` → `{ "sessions": [Session] }`.
- `axp.subscribe` `{}` → `{}`. After it, the hub sends `axp.hosts.changed` `{ "hosts": [Host] }` and `axp.sessions.changed` `{ "hostId", "sessions": [Session] }` whenever a host or Session changes. Notifications carry only what changed. A hub MAY coalesce changes for up to 250 ms. `axp.unsubscribe` `{}` stops them.

A client that reconnects MUST list again rather than assume it missed nothing.

## 9. Logs

A Session's log is an [ATXF](https://atxf.leostera.dev) transcript:

- The header MUST declare `integrity: {"alg": "sha256", "canon": "jcs"}`, and its `id` MUST equal the `sessionId`.
- Every record MUST carry its ATXF `hash`. Records travel as JSON objects, exactly as they appear in the transcript.
- The log is append-only. Nothing is ever removed or rewritten; rewinds and branches are ATXF `leaf` records and parent links. `seal` records MAY appear and are ordinary records.
- The host is the only writer. Replicas append only records that the host wrote, in the host's order.

A host whose agent stores its sessions in another format converts them to ATXF as they are written, and SHOULD carry each source record in `native` so that a client that needs the agent's own format can recover it. The conversion is described by an agent extension (for example `pi`).

### 9.1 Offers

A replica describes what it holds with an **Offer**: the values an ATXF seal (ATXF §17.2) would carry after its last record.

```json
{"count":120,"chain":"sha256:…","heads":["sha256:…"]}
```

- `count` is the number of records after the header.
- `chain` starts as the header hash and folds in each record's hash in order. With `count: 0` it is the header hash.
- `heads` is OPTIONAL. When present it is the sorted list of the hashes of records that no other record references.

Two copies of a log agree up to `count` exactly when their chains at `count` are equal.

### 9.2 Serving and reading

Every log has a **server** and **readers**. The host serves its logs to the hub and to direct clients. The hub reads every log from its host and serves it to clients. Any peer that holds a replica MAY serve it. The methods are the same in each case.

A reader opens a log with `axp.log.open` → server:

```json
{"jsonrpc":"2.0","id":9,"method":"axp.log.open","params":{"hostId":"…","sessionId":"…","have":{"count":120,"chain":"sha256:…"},"window":64}}
```

- `have` is the reader's Offer, or absent if it holds nothing.
- `window` is the number of records the reader wants before the end when it holds nothing, so a client can show the latest messages first. Absent means from the start.

The server answers:

```json
{"jsonrpc":"2.0","id":9,"result":{"header":{…}|null,"from":120,"records":[…],"have":{"count":184,"chain":"sha256:…"},"older":null,"slots":[…]}}
```

- `header` is the ATXF header when the reader sent no `have`, otherwise `null`.
- `records` are the records after position `from`, at most `limits.batchRecords` of them and at most `limits.batchBytes` bytes of JSON, except that a single record larger than that is sent alone.
- `have` is the Offer after those records.
- `older` is the position below which records exist that were not sent (because of `window`), or `null`.
- `slots` are the Session's current ephemeral slots (§11).

If the reader's `have` does not match the server's chain at `have.count`, or `have.count` is beyond the server's count, the server answers `-32020` (diverged) with its own Offer in `data.have`. Readers handle this as described in §9.4.

While a log is open, the server pushes everything that follows as `axp.log.records` notifications `{ "hostId", "sessionId", "from", "records", "have" }`. The reader acknowledges each with `axp.log.ack` `{ "hostId", "sessionId", "count" }`. A server MUST NOT have more than `limits.batchesInFlight` unacknowledged batches per log on one connection, and MUST NOT send a batch whose `from` is not the `have.count` of the batch before it.

A reader MUST verify every batch: each record's ATXF hash, and that folding the records into its chain gives the batch's `have.chain`. A batch that fails is a protocol error: the reader MUST close the log with `axp.log.close` and SHOULD close the connection. This is what prevents a hub from altering, inserting or dropping records.

`axp.log.older` `{ "hostId", "sessionId", "before", "limit" }` → server answers `{ "from", "records", "older" }`: up to `limit` records ending just before position `before`, oldest first. A reader that opened with `window` pages back with it. Readers verify paged records against the chain once they hold the start of the log.

`axp.log.close` `{ "hostId", "sessionId" }` stops the pushes. Closing the connection closes every log open on it.

### 9.3 Replication to a hub

After a host's `axp.host.announce`, the hub opens with `axp.log.open` every log for which the host's Offer is ahead of the hub's replica, using its replica's Offer as `have`, and keeps them open. The hub thereby receives every record the host appends. The hub MUST make a batch durable before acknowledging it.

The hub serves a client's `axp.log.open` from its replica, whether or not the host is online, and pushes records to the client as they arrive from the host.

### 9.4 Divergence

Because a log has one writer, two copies differ only when one is a prefix of the other, unless a host lost records it had already served (a restored disk, a crash before its own write was durable) and then wrote different ones.

When a reader receives `-32020`:

- **The reader is behind or forked, the server is the host.** A client discards its copy and opens again without `have`. A hub finds the longest common prefix with `axp.log.chains` (below), keeps its records up to there, and keeps the records past it, which are no longer the host's, in a side store for recovery; it then opens from the common prefix.
- **The reader is the host.** The host has lost records the replica holds. It MUST NOT append to the log until it recovers: it finds the common prefix with `axp.log.chains`, reads the replica's records past it with `axp.log.open` and `axp.log.older`, and rebuilds its log as the common prefix, then the replica's records, then its own records past the common prefix that the replica does not hold (by hash), in their order. ATXF record hashes do not depend on position, so every record keeps its hash; only the chain changes. A host that cannot recover MUST set the Session's status to `unavailable`.

`axp.log.chains` `{ "hostId", "sessionId", "positions": [count] }` → server answers `{ "chains": [hash | null] }`: its chain after each position, or `null` past its count. At most `limits.chainPositions` positions per request. A binary search over positions finds the common prefix in a logarithmic number of round trips.

## 10. Routed calls and commands

### 10.1 Routing

Extensions define methods that act on a host, such as sending a prompt or writing to a terminal. Such a method's params MUST include `hostId`, and SHOULD include `generation` when the call only makes sense for one host process.

A hub that receives a request whose method belongs to an extension and whose params carry `hostId`:

1. checks that the caller's account owns the host and that the host negotiated the extension;
2. answers `-32010` (host offline) if the host has no connection, or `-32011` (stale generation) if `generation` is present and is not the host's current one;
3. otherwise forwards the request on the host's connection with a new `id`, adding `from: { "device" }` to the params, and relays the host's response, error included, with the caller's `id`.

A hub MUST NOT change the params otherwise and need not understand them. Notifications with `hostId` are forwarded the same way in both directions, to the host from a client, and from the host to the clients the extension says should receive them.

If the host's connection closes before it responds, the hub answers `-32012` (outcome unknown).

### 10.2 Commands

A **command** is a routed call whose params carry a `commandId`. The host MUST run a command at most once per `(sessionId, commandId)`, or per `(hostId, commandId)` when it names no Session:

- The first time, the host validates it and answers `{ "receipt": "accepted" }` once it has taken responsibility for it, or an error if it never will run it. An error from the host means the command did not run and will not.
- A repeat of a `commandId` the host has already accepted is answered `{ "receipt": "accepted", "duplicate": true }` and not run again. A host MUST remember accepted `commandId`s for at least 24 hours and SHOULD remember every one that appears in a log.
- A client that gets `-32010`, `-32012` or a timeout SHOULD send the same command again with the same `commandId`. That is always safe.

A receipt does not mean the command has had its effect. Every record a command produces MUST carry the command's id in `ext.axp.commandId`. Because `ext` is covered by the record's hash, a client knows its command took effect when such a record reaches it, and a hub cannot pretend otherwise.

## 11. Ephemeral state

A Session has named **slots**, each holding one current value that is never stored and never replayed. An agent writing a reply uses a slot for it; an extension defines which slots exist and what their values mean. Where a slot's value will become a log record, its value SHOULD be that ATXF record without `hash`.

- A host sets a slot with the notification `axp.slot` `{ "hostId", "sessionId", "slot", "value" | null, "at" }`. `null` clears it. Slot names are 1 to 128 characters.
- A hub keeps only the latest value of each slot of an online host in memory, forwards each `axp.slot` to the readers that have the Session's log open, and returns the current slots in `axp.log.open`.
- `axp.slot` notifications are in the `ephemeral` priority class (§4.1). A sender MAY drop a queued value when a newer one for the same slot is queued.
- When a host disconnects, the hub clears its slots and sends `null` for each.

## 12. Ordering and delivery

- On one connection, notifications and pushed batches arrive in the order sent. Across connections nothing is ordered.
- A client MAY see the records a command produced before the command's receipt arrives.
- After a reconnect a reader reopens with its Offer and receives exactly what it is missing.
- Directory notifications are hints of change; `axp.hosts.list` and `axp.sessions.list` are the truth.

## 13. Errors

AXP errors are JSON-RPC errors whose `data` has `retry`:

- `safe`: the request did not take effect; sending it again is safe.
- `unknown`: it may have taken effect. Only a command (§10.2) is safe to resend.
- `never`: sending the same request again will fail the same way.

`data.retryAfterMs` MAY say how long to wait.

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32700, -32600, -32601, -32602, -32603 | JSON-RPC | `never` (`-32603`: `unknown`) | As in JSON-RPC 2.0. `-32601` also answers methods of extensions outside the negotiated set. |
| -32001 | `unauthenticated` | `never` | No valid `axp.auth`, or authentication failed. |
| -32002 | `forbidden` | `never` | The device may not do this, or has been revoked. |
| -32010 | `hostOffline` | `safe` | The host has no connection to the hub. |
| -32011 | `staleGeneration` | `never` | The host restarted; refresh the directory. |
| -32012 | `outcomeUnknown` | `unknown` | The host's connection closed before it answered. |
| -32013 | `unknownSession` | `never` | No such host or Session in this account. |
| -32020 | `diverged` | `never` | The reader's Offer is not a prefix of the server's log; `data.have` is the server's Offer. |
| -32030 | `limitExceeded` | `never` | The request breaks a limit; `data.limit` names it. |
| -32031 | `rateLimited` | `safe` | Try again after `retryAfterMs`. |
| -32040 | `pairingFailed` | `never` | The code is wrong, used or expired. |
| -32100 | `unsupportedVersion` | `never` | `data.versions` lists the versions the receiver speaks. |

Extensions use codes from -32200 to -32999, in the range their registry entry reserves.

## 14. Limits

| Limit | Default | Negotiated | Meaning |
| --- | --- | --- | --- |
| `messageBytes` | 1 MiB (stream), 64 KiB (message) | yes | Largest message accepted whole (§4.1). |
| `fragmentBytes` | 48 KiB | yes | Largest fragment payload before base64url. |
| `maxMessageBytes` | 32 MiB | yes | Largest message accepted after reassembly. |
| `batchRecords` | 64 | yes | Records per batch (§9.2). |
| `batchBytes` | 512 KiB | yes | Bytes of records per batch. |
| `batchesInFlight` | 4 | yes | Unacknowledged batches per log per connection. |
| `chainPositions` | 32 | no | Positions per `axp.log.chains`. |
| `announceSessions` | 4096 | no | Sessions per `axp.host.announce`. |
| `requestTimeoutMs` | 10000 | no | How long a peer waits for a response before treating its outcome as unknown. |
| pairing code lifetime | 10 minutes | no | §6.3. |

A peer MAY announce a lower value for any negotiated limit. It MUST NOT exceed the other side's.

## 15. Extensions

An extension adds to AXP without changing the core. It has:

- an **identifier**: a lowercase slug `^[a-z][a-z0-9-]{0,31}$` for extensions listed in the [registry](extensions/README.md), or a reverse-DNS name (`dev.leostera.axo.debug`) for private ones;
- a **version**, `major.minor`, independent of the core's;
- a document with front matter (identifier, version, status, requires, roles) and the sections it needs.

An extension MAY add:

- methods and notifications whose names start with `<identifier>.`;
- slots (§11) and record conventions for logs (§9);
- fields under `ext.<identifier>` in Session metadata, Hosts and log records;
- presence values (§7) and error codes in its reserved range.

An extension MUST NOT change the meaning of a core method, field or error, and MUST NOT require a hub to understand its routed calls (§10.1). An extension MAY require others; a peer negotiating it MUST also negotiate those.

`ext.axp` in log records is reserved for the core and currently holds only `commandId`.

## 16. Versioning

- The protocol version is `major.minor`. `0.x` versions are drafts and MAY change incompatibly.
- From `1.0`, a minor version only adds optional fields, methods, notifications, errors and limits. A major version is negotiated in `axp.hello`.
- AXP 0.1 uses ATXF 0.1. A log's ATXF version is its header's `atxf` field; a reader that does not support it MUST NOT render the log as current but MAY still replicate it.

## 17. Security

- **One writer.** Only the host writes a log, and readers verify every batch (§9.2), so a hub or a client can neither forge records nor reorder, insert or drop them without detection. A hub can withhold records; a reader that also reaches the host directly can detect that by comparing Offers.
- **Commands.** A hub checks that the caller's account owns the host; the host decides what each device may do and MAY reject a command with `-32002`. Receipts are not proof of effect; records carrying `ext.axp.commandId` are.
- **Credentials.** No secret crosses the wire after pairing. A stolen pairing code is useful for at most 10 minutes and once. A device's private key SHOULD be kept in hardware-backed storage where available.
- **Replay.** `axp.auth` signatures are bound to a fresh challenge and to the hub's origin.
- **Exhaustion.** Every list, batch and message is bounded (§14). A receiver MUST close a connection that exceeds them rather than buffer without limit.
- **Local sockets.** Anyone who can connect as the host's user can control the host. That is the same trust the operating system already grants that user.

## 18. Privacy

Logs contain source code, command output, file paths and whatever people type, including credentials pasted by mistake. A hub stores every log in full. A hub:

- MUST NOT store ephemeral slots or extension streams that their extension marks as ephemeral (such as terminal output);
- MUST declare how long it keeps logs and how an account deletes them;
- MUST NOT serve one account's logs to another account's devices. Sharing a Session publicly is a separate, explicit act (see the `share` extension).

Hosts SHOULD offer people a way to keep a Session off the hub entirely.
