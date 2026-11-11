# RFD0043 - Axo: moving Axo onto AXP

- Feature Name: `axo-on-axp`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-11
- Updated: 2026-11-11
- Document Type: Proposal
- Amends: [RFD0025](RFD0025-agent-xchange-protocol.md) (rollout steps 2 and 5), [RFD0034](RFD0034-axod-as-an-axp-server.md) (the `axp` crate, deleting `axo-protocol`), [RFD0035](RFD0035-session-records-in-atxf.md) (the wire), [RFD0036](RFD0036-retiring-protocol-2.md) (folded into the last phase)

## Summary

Axo's peers speak protocol 3, an `axo.*` wire that AXP was designed from but that implements none of AXP's messages. This RFD moves every Axo peer onto AXP 0.2 in five phases, each one or more releases. First the spec takes what Axo has learned since 0.1. Then come the libraries the products use: `axp` in Rust, `@leostera/axp` in TypeScript, and later `AxpKit` in Swift. axod and the Mac app move the local socket in one release. Then axod moves its hub connection to a new `/axp` endpoint, writing ATXF as Pi writes, authenticated by a device key and replicated the way §9 says. The web app moves with the Worker, and the phone in its own release. Protocol 3 and protocol 2 are removed together, once the evidence shows nothing speaks them. The relay becomes AXP transport and routing, and the features it now hand-routes become extensions of axod and the hub.

## Motivation

AXP exists so that Axo's guarantees hold by construction, and are written down where any peer can implement them. Protocol 3 has most of the mechanisms but not all of the guarantees.

- **Nobody checks what the hub sends.** Records carry hashes and logs carry chains (RFD0018), but no client checks them: not `@axo/app`, not the web app, not `AxoClient`. AXP §17 rests "only the host writes" on readers verifying every batch (§9.2). Today that guarantee is only as strong as the Worker.
- **Hosts authenticate with a bearer secret.** axod sends `Authorization: Bearer <credential>` on every connection (`crates/axo-relay/src/relay/socket.rs`), and the Worker stores a verifier of it (`credential_verifier` in `packages/axo-api-worker/src/auth/account-manager.ts`). AXP §6.2 has each device sign a fresh challenge with a key it never exports.
- **A divergence deletes the cloud's records.** When the Mac and the cloud disagree, the Mac wins and the cloud is cut back (`axo.host.session.truncate`, `SessionStore.truncate`). AXP §9.4 never removes records: the hub sets the forked ones aside, and a host that lost records recovers them from the replica. Our way loses data in exactly the case AXP handles: a Mac restored from an old backup.
- **The log is Pi's, and the cloud translates it.** Hosts send `pi/3` lines. The SessionDO translates each to ATXF as it commits it (RFD0035), so every client that wants ATXF depends on the Worker's translation, and nothing ties it to what the Mac holds.
- **Every feature is routed by hand.** The HostDO and the relay know each `axo.remote.*` and `axo.host.*` method. AXP §10.1 lets a hub forward any extension method that names a `hostId` without understanding it, so a new host feature needs no hub change.
- **Two protocols, three wires.** Protocol 2 is still served (RFD0036), protocol 3 is what everyone speaks, and AXP is specified beside them with no user. RFD0025's drawbacks section predicted this: "fixes to one do not reach the other", and "the design can drift from reality". It has. AXP's `sessions` extension still has Workspaces, which RFD0038 removed, and AXP has no home for questions to the person, computer use, or one Mac following another's Sessions.

How far protocol 3 is from AXP today, area by area:

| AXP | Protocol 3 |
| --- | --- |
| §3 messages; unknown members rejected | JSON-RPC. Unknown members rejected in most places, not all. No `ext`. |
| §4.1 fragments, priority classes | Same mechanism (`axo.transport.fragment`), other names and sizes (46,080-byte chunks, 16 MiB). Priority classes in axod's outbox. |
| §5 `axp.hello`, negotiated extensions and limits | `axo.client.hello` with `protocolVersion: 3`. Nothing negotiated. |
| §6.1 local peers by user | A private socket directory. No peer user check. |
| §6.2 device keys and challenges | Bearer credential for hosts; OAuth cookies for browsers. P-256 device keys exist, for answers to questions only. |
| §6.3 pairing codes | Same code format and lifetime. `axo://pair/`, redeemed over HTTPS, no `O`/`I`/`L` mapping. |
| §7–8 hosts, presence, directory, status | Close. The same five status values, versioned metadata. |
| §9 ATXF logs, offers, chains | `pi/3` logs. Offers and chains as AXP has them, `chainAt` at 32 positions. |
| §9.2 readers verify every batch | Not done. |
| §9.3 the hub reads from the host | The host pushes (`axo.host.session.append`). |
| §9.4 divergence keeps every record | The cloud is truncated. |
| §10.1 generic routing with generation | Hand-routed `axo.remote.*`, with generation checks. |
| §10.2 commands, `ext.axp.commandId` | At most once by `commandId`, remembered through the log; the receipt is an `axo.command` entry, not a field of the records the command made. |
| §11 slots | Progress slots, the same model. |
| §13 errors with `data.retry` | Axo's own codes, no `retry`. |
| §15 extensions | None; apps, terminal and questions are part of the wire. |

## Goals

- Every Axo peer speaks AXP: axod, the Mac app, pi-axo's calls into axod, `axod mcp`, the Worker, the web app and the phone.
- Readers verify every batch. Hosts and clients authenticate with device keys. No record is ever deleted to settle a divergence.
- Hosts write ATXF. The hub replicates what hosts wrote and translates nothing new.
- The hub routes extension methods it does not understand. Adding a host feature needs no change to the Worker.
- Nobody re-pairs. Every linked Mac, signed-in phone and browser keeps working across every release.
- AXP's libraries are the ones Axo runs. RFD0025's reference peers come from production code, not beside it.
- At the end, one wire: protocols 2 and 3 removed, `axo-protocol` and the relay's hand routing deleted.

## Non-goals

- Hosts other than axod, or agents other than Pi. AXP allows both; this RFD does not build them.
- Direct Mac-to-Mac connections. A Mac that follows another's Sessions does it as a client of the hub, as it does today.
- Changing the Pi bridge (RFD0015; `packages/pi-axo/src/bridge-server.ts`, `crates/axo-agent/src/pi/`). It is the agent's side of the host, not AXP.
- Changing the Worker's account model beyond what §6 needs. Signing in with Cloudflare OAuth stays "not specified by AXP" (§6.4).
- Publishing the packages. Whether `axp` and `@leostera/axp` are published is RFD0025's open question, not this one's.

## Guide-level explanation

### What changes for people

Nothing, except that a few failures get better. A Mac restored from an old backup gets its records back from the cloud instead of erasing them. A tampering or broken hub is caught by every client, which closes the log instead of showing it. The Mac's link to the account no longer rests on a secret that crosses the wire.

### The picture at the end

```text
 Mac                                   Cloud (axo.leostera.dev)          Phone, web, other Macs
 ┌──────────────────────────┐          ┌─────────────────────────┐       ┌──────────────────────┐
 │ axod                     │  /axp    │ Worker = AXP hub        │ /axp  │ AXP clients          │
 │  axp (Rust): transport,  │◀────────▶│  @leostera/axp: core    │◀─────▶│  @leostera/axp (web) │
 │   hello, auth, logs      │  host    │  routes ext methods by  │ client│  AxpKit (phone, Mac  │
 │  extensions: sessions,   │  role    │   hostId, unread        │ role  │   app)               │
 │   agent, terminal, local,│          │  extensions it serves:  │       │  verify every batch  │
 │   questions, computer    │          │   apps, assets, share   │       └──────────────────────┘
 │  local socket: AXP       │          │  replicas: ATXF, as the │
 └──────────┬───────────────┘          │   host wrote them       │
            │ AXP, client role         └─────────────────────────┘
   Mac app, pi-axo, axod mcp
```

- **axod is an AXP host.** On its local socket it serves AXP to the Mac app, pi-axo and `axod mcp`. On `/axp` it is a host of the hub and serves its logs to it. When it follows another Mac's Sessions it is also a client of the hub, on a second connection.
- **The Worker is an AXP hub.** The HostDO holds the host's connection and routes routed calls to it. The SessionDO holds each replica as the host wrote it. The ClientDO serves each client the directory and its open logs. The apps, assets and share extensions are the hub's own.
- **Every client verifies.** The web app, the phone and the Mac app check each record's ATXF hash and each batch's chain before showing it.

### A prompt from the phone, at the end

1. The phone sends `agent.prompt` `{ hostId, generation, sessionId, commandId, text }` on its `/axp` connection.
2. The ClientDO checks that the account owns the host and that the host negotiated `agent`, then forwards the call to the HostDO, adding `from: { device }`. It does not parse the rest.
3. axod answers `{ "receipt": "accepted" }` once pi-axo holds the prompt, or `{ "receipt": "accepted", "duplicate": true }` if it has seen that `commandId`.
4. Pi writes the user message. axod converts it to ATXF, sets `ext.axp.commandId`, hashes it, appends it to its log, and pushes it on every open log: the hub's, then the hub's to the phone.
5. The phone checks the record's hash and the batch's chain, and sees its prompt land by its `commandId`.

Today steps 2 and 4 are hand-written for this one method, and step 5 checks nothing.

### A restored Mac, at the end

A Mac restored from last week's backup comes back with a log 40 records shorter than the cloud's replica, and has already written 3 new records past it. On `axp.host.announce` the hub answers with its Offer. axod finds that its chain at the replica's count does not match, so it has lost records. It stops appending to that log, finds the common prefix with `axp.log.chains`, and reads the 40 records back with `axp.log.open`. It rebuilds its log as the prefix, the 40, then its own 3, and appends again. Today the same Mac cuts the cloud's copy back to its own, and the 40 records are gone everywhere.

### What a release looks like

Each phase below ships as ordinary releases through the installer. In every release, every combination of peers that can be running at once keeps working: new Worker with old Mac, new Mac with old phone, and so on. The Worker serves protocol 3 and AXP side by side from phase 3 until phase 5.

## Reference-level explanation

### Phase 0: AXP 0.2, from what Axo learned

AXP 0.1 was written before RFD0038 and RFD0041–RFD0042 and before the WhatsApp, computer-use and questions work. AXP 0.2 fixes the spec first. No Axo code changes in this phase. Each change is a spec edit with its schema and examples, checked by `bazel test //axp:test`:

- **`sessions` without Workspaces.** `sessions.create` takes a folder or another Session to start beside (`like`), as RFD0038 does. `sessions.workspaces.list` goes.
- **A `questions` extension.** RFD0029's elicitations as AXP has them: asked by a Session, answered by a person on a device, with the answer's device proof (§6.2's key, not a separate one) and form values sealed to the host's input key (RFD0029, `crates/axo-seal`). AXP 0.1 left this "still being designed" (RFD0025, As specified).
- **A `computer` extension.** RFD0028's routed computer calls, the gate's questions going through `questions`, and screenshots as `assets`.
- **`hosts.bash`**, or `bash` in `apps`, for the account's scripts running commands on a Mac (`axo.apps.bash`). Which one is a phase 0 decision.
- **Device key algorithms.** §6.2 requires Ed25519, but the Secure Enclave only has P-256, and the phone's and browser's device keys are already P-256 (`SecureEnclaveDeviceSigner` in `apple/AxoProtocol/Sources/AxoProtocol/InputSeal.swift`, `packages/axo-app/src/seal.ts`). AXP 0.2 names the algorithm at pairing (`"alg": "ed25519" | "p256"`) and allows both, so a device key can live in hardware where the platform has it.
- **Archived logs that live in the hub only.** RFD0027 deletes an archived Session's log on the Mac once the cloud acknowledged it, and fetches it back when the Session reopens. In AXP terms the host evicts its copy and reads it back from the hub's replica, which §9.2 already allows ("any peer that holds a replica MAY serve it"). 0.2 says so, and gives the host an Offer it keeps for an evicted log, so `axp.host.announce` still describes it.
- **ATXF 0.2.** The Worker's translations are made with `@leostera/atxf@0.2.0` (`ATXF_CONVERTER` in `packages/axo-api-worker/src/session-atxf.ts`); AXP 0.1 names ATXF 0.1 (§16).

### Phase 1: the libraries

The libraries are written for the peers that use them and are AXP's reference implementations at once. They replace RFD0025 step 2's separate reference peers.

- **`axp` (Rust, `axp/rust/`)**: the core's types with serde that rejects unknown members; stream and message framing; fragments with priority classes (moving `crates/axo-relay/src/fragments.rs` and `outbound.rs`); `axp.hello` and negotiation; `axp.auth` signing and checking; errors with `data.retry`; Offers, chains and batch verification; a log server and a log reader, independent of transport. Built on axod's runtime, with boxed futures, not `async_trait`.
- **`@leostera/axp` (TypeScript, `axp/ts/`)**: the same, for the Worker and the web app.
- **Fixtures and cross-checks (`axp/fixtures/`)**: byte-for-byte expected messages, chains and signatures, run against both libraries, so the Rust host and the TypeScript hub cannot disagree on a hash.
- **ATXF, in ATXF first.** axod has to write the ATXF records the hub already holds, or every replica diverges at once. `atxf-rs` converts whole files; the hub uses `atxf-ts`'s `pi.stream`. Before phase 3, `atxf-rs` gets a streaming Pi converter that `scripts/cross-check.sh` in the ATXF repository proves identical to `pi.stream` on the same lines.

`AxpKit` (Swift) comes in phase 2, for the Mac app, and is reused by the phone in phase 4.

### Phase 2: the local socket

The local socket's peers all ship in the Mac app's bundle (the Mac app, pi-axo, `axod mcp`), so it moves in one release with no compatibility layer.

- axod serves AXP on `axod.sock`: `axp.hello` with `role: "client"`, no `axp.auth` (§6.1), and the extensions the host has. axod checks each connection's user with `getpeereid` and refuses any other user. Today only the directory's permissions keep others out.
- `axp.hello` replaces `axo.protocol.negotiate`. `local` replaces `axo.daemon.*`, `axo.relay.*`, `axo.config.*` and `axo.client.viewport.set`. `sessions`, `agent`, `terminal`, `questions` and `computer` replace `axo.session.*`, `axo.shell.*`, `axo.terminal.*`, `axo.elicitation.*` and `axo.computer.*`. The terminal attach protocol becomes `terminal.attach` and `terminal.output`. `apps` and `assets` keep their methods under AXP's names (`axo.apps.*`, `axo.assets.fetch`), still forwarded to the hub.
- A Mac reading another Mac's Session uses `axo.peer.*` today (`axo.peer.session.watch`, and `axo.peer.command` wrapping `axo.remote.session.*`, in `packages/pi-axo/src/remote-view.ts`). Those become the core's `axp.log.*` and the extensions' routed calls, sent to axod on the local socket, which relays them on its hub connection. The Pi bridge between pi-axo and axod (RFD0015) does not change.
- `axod mcp`'s tools call the AXP methods in process (`axo_ipc::Local`), as they call `axo.*` now.
- `crates/axod/tests/conformance/` is rewritten against AXP and becomes the host conformance suite: the "conformance kit that drives a host from outside" RFD0025 lists under Future possibilities.

The Mac app and axod upgrade together through the installer, so there is no window in which one speaks AXP and the other does not. A Mac app from an older bundle cannot talk to a newer axod; it is never left running, because the installer quits it.

### Phase 3: the hub connection

This is where most of the guarantees arrive, and most of the risk. It ships in several releases.

**3a. The Worker serves `/axp`**, beside protocol 3's endpoints, for hosts and clients. It implements hello, negotiation, `axp.auth` and pairing (`axp.pair.create`, `axp.pair.redeem`, codes normalized as §6.3 says). Routing is generic: the ClientDO forwards any request of a negotiated extension whose params carry `hostId` to the HostDO, which forwards it to the host, adding `from`. The hub's own extensions (`apps`, `assets`, `share`) are modules of the Worker, with the methods they own.

**3b. Device keys without re-pairing.** A Mac linked today has a bearer credential and no device key. In 3b, axod generates its device key and enrolls the public half once, over its authenticated protocol 3 connection (a new `axo.host.device.enroll`). From then on it connects to `/axp` and signs challenges, and the Worker stops accepting its bearer credential. A Mac linked after 3b redeems its code with `axp.pair.redeem` and never has a credential. The phone and the browser enroll their existing P-256 device keys the same way, once signed in, in phase 4.

**3c. Shadow chains.** Before any log moves, axod computes the ATXF chain of every log it uploads and sends it with each protocol 3 append, as an extra field. The SessionDO compares it with the chain of its own translations and logs `atxf_chain_mismatch` with the position. Phase 3d waits for 7 days with no mismatch on any Session, the same kind of evidence gate as RFD0036's.

**3d. Logs move.** axod connects to `/axp` as a host and announces. The hub's Offer for each log is its ATXF chain, which phase 3c showed equal to the host's. The hub opens every log that is behind and reads it as §9.3 says, acknowledging each batch after it is durable. From here on:

- axod writes ATXF as Pi writes, keeping each Pi line in `native`. The SessionDO stores what the host sent and stops translating. The translations it already made stay as the replica.
- `ext.axp.commandId` is set on each record a command made. pi-axo's `axo.command` receipt entries remain in the Pi log, where they are what makes a command run at most once across Pi restarts (`packages/pi-axo/src/remote-commands.ts`). axod's converter reads the receipt and sets `ext.axp.commandId` on the record of the user message after it.
- `axo.host.session.truncate` goes. A divergence is handled as §9.4 says: the hub keeps its records past the common prefix in a side table and reads from the prefix; a host that lost records stops appending, recovers from the replica, and marks the Session `unavailable` if it cannot.
- RFD0027's evictions and restores become the host reading back its own log from the hub (phase 0).

**3e. The relay thins.** `crates/axo-relay` keeps the transport: the socket, hello, auth, fragments, priority classes and pacing (`FrameBudget`), heartbeats, and reconnecting with backoff. Everything it dispatches by method name today moves to axod's extensions: the account's calls (`crates/axo-server/src/remote.rs`), jobs, sign-ins, bash and computer calls. The relay forwards every routed call to the one AXP router axod's local socket uses, so a call is the same call whether it came locally or through the hub. That is RFD0034's "relay as a transport", finished. The HostDO likewise stops knowing `axo.host.*` and `axo.remote.*`.

Until phase 5, the Worker serves both: protocol 3 for Macs that have not upgraded, AXP for those that have. A Mac speaks one or the other, never both.

### Phase 4: the remote clients

- **The web app** moves with the Worker release that ships it, since the Worker serves it. It uses `@leostera/axp`, verifies every batch, and enrolls its device key.
- **The phone** moves in its own release, using `AxpKit`. Until then it speaks protocol 3 to the same Worker. It verifies every batch, and its device key is the Secure Enclave key it already has.
- **A Mac following another's Sessions** (`crates/axo-relay/src/peers/`) connects to `/axp` as a client, with the same device key as its host connection. Protocol 3's peer follower goes.

### Phase 5: one wire

The Worker logs `client_hello` and host connections by protocol (RFD0036 built the logging for clients). After 7 days in which every host and client connection was AXP, a release removes protocol 3 and protocol 2 together. That covers the Worker's protocol 3 endpoints and both DOs' code for them, axod's protocol 3 connection and peers follower, the bearer credentials and their verifiers, `@axo/app`'s protocol 3 client, `AxoClient`'s `AccountConnection`, and `crates/axo-protocol`. RFD0036's two releases fold into this one.

### Invariants through the migration

- **One writer.** At every step, only the host appends to a log. No phase lets the hub write a record, and phase 3d's switch from the hub's translation to the host's ATXF happens only where the two agree (phase 3c).
- **At most once.** A `commandId` runs at most once whatever protocol carried it, and across the switch: pi-axo's receipts in the Pi log are the record, and they do not change.
- **No record lost.** No phase deletes a record to settle a divergence. The truncate path is removed in phase 3d, not before the side table exists.
- **No re-pairing.** Every device enrolls its key over the connection it already has.
- **Every mixed state works.** Before each release, the Worker end-to-end suites run with both the previous and the new axod, and the phone against both Worker versions.

### Testing

- `bazel test //axp/...`: the schemas, examples and fixtures against both libraries.
- The host conformance suite (phase 2) on every axod change, against AXP.
- Worker end-to-end suites (`packages/axo-api-worker/tests/*-e2e.test.ts`) with both axods through phases 3 and 4.
- Feynman models for what this RFD adds: enrolling a device key (no window in which a Mac has neither credential nor key), the shadow-chain gate, and §9.4 recovery (`specs/relay/`), tied to the code with `sources`.
- A regression test for each mixed state the invariants name.

## Drawbacks

- **It is long.** Five phases and a dozen releases, with the Worker serving two protocols through most of them, and every fix to delivery made twice until phase 5.
- **Phase 3 can fail all at once.** If the Rust and TypeScript conversions differ on one record, every Session past it diverges. Phase 3c's gate is the defence, and it delays the phase by at least a week.
- **The hub pulls.** §9.3 has the hub open each log and acknowledge each batch. That is about as many messages as today's appends, but the HostDO has to act on every announce (RFD0031 keeps DOs asleep when nobody watches), and its cost must be measured in phase 3d.
- **The spec moves under its only user.** AXP 0.2 is shaped by Axo's needs. That is what RFD0025 asked for, but it makes AXP look more like one product's wire.
- **Device keys are another secret to lose.** A Mac whose key is gone from its Keychain has to pair again; today the same is true of its credential.

## Alternatives

- **Do nothing.** Keep protocol 3 and leave AXP a specification. The guarantees above stay missing, and the spec keeps drifting from the code that should prove it.
- **Get the guarantees on protocol 3, then stop.** Clients could verify `pi/3` hashes and chains, hosts could sign challenges, and truncation could keep a side table, all without a new wire. That is most of phase 3's work, done for a wire that is then removed, and it leaves the hand routing and the translation in the Worker. It is the fallback if AXP stalls.
- **Rename protocol 3 to AXP's names, and change nothing else.** Cheap, and conforming on paper, but it leaves out exactly the verification, authentication and divergence behaviour that AXP exists for.
- **One cutover release.** Move every peer at once. The phone ships on its own schedule, and a Mac may not be upgraded for days, so some peers would stop working. Phase 2 is the only part where every peer ships together.
- **Hub first, then local.** Phase 3 carries the guarantees, so doing it first gets them sooner. Phase 2 first is cheaper, though: its peers ship together, it settles the extension shapes against the existing conformance suite, and it builds `AxpKit` before the phone needs it.

## Unresolved questions

Before acceptance:

- Ed25519 and P-256 side by side (phase 0), or P-256 alone, which every platform Axo runs on has in hardware?
- `bash` as `hosts.bash` in the core directory, or as a tool of `apps`?
- Does phase 3c's shadow chain need 7 days, or does a backfill check of every stored Session give the same evidence at once?

During implementation:

- Whether the side table for forked records (§9.4) has a retention limit, and who can read it.
- How `ext.axp.commandId` reaches the record when a prompt is steered into a running turn, where the receipt is not the entry before the user message.
- Whether the SessionDO keeps the `pi/3` line after phase 3d, or only `native` (RFD0035 left this open).

Out of scope:

- Hosts other than axod, and agents other than Pi.
- Signing seals with the host's device key (RFD0025).

## Future possibilities

- A conformance kit for hosts that are not axod, from phase 2's suite.
- A headless Linux host, which AXP and the libraries would make mostly a matter of packaging.
- Clients that reach a Mac directly on the local network, with the same AXP and the same verification.
