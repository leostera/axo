# RFD0025 - Axo: AXP, the Agent Xchange Protocol

- Feature Name: `axp`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-02
- Updated: 2026-11-02 (see As specified)
- Document Type: Proposal

## Summary

I propose a protocol of its own for what Axo's pieces do between them: **AXP, the Agent Xchange Protocol**. AXP moves live agent Sessions between the machine that runs them and everyone who watches or steers them. It is written the way ATXF is (`github.com/leostera/atxf`): a normative `SPEC.md` with RFC 2119 keywords and numbered sections, JSON Schemas at stable URLs, examples, conformance fixtures, TypeScript and Rust implementations that must agree byte for byte, Feynman models, and a specification site at `axp.leostera.dev`.

- **Designed, not transcribed.** AXP takes what RFD0013–RFD0024 learned (one writer per log, hash-chained replication, commands with receipts, pairing codes) and states it as a protocol, without carrying over Axo's names, version numbers or accidents.
- **A small core.** Names, connection, trust and pairing, the directory of hosts and Sessions, logs, commands and ephemeral state. Nothing about terminals, Pi or Cloudflare.
- **ATXF logs.** A Session's log is an ATXF transcript with integrity. AXP replicates it; ATXF says what it means. Clients render any agent's Session from ATXF alone.
- **Extensions for the rest.** `pi`, `terminal`, `connections`, `share`, `upgrade`, `local`, each with its own document, schema and version, negotiated per connection.
- **Axo moves much later.** AXP is finished first: specified, modelled, tested, with packages. Moving axod, the API Worker and the apps onto it is a separate RFD once AXP is ready. Nothing in Axo changes with this one.
- **Its own directory.** `axp/` at the root of this repository, laid out like the ATXF repository, so it can move to a repository of its own later.

## Motivation

1. **The protocol is not written down as one.** Axo's wire is spread over `schemas/axo.leostera.dev/` (61 identifiers; the code uses about 130), Zod in `packages/axo-api`, Rust in `crates/axo-protocol` and `crates/axo-relay`, Swift in `apple/AxoProtocol` and `apple/AxoClient`, and prose in RFD0016, RFD0018, RFD0019, RFD0022 and RFD0024. No one can implement it from documents.
2. **It mixes layers.** Session listing, Pi prompts, PTY bytes and tool connections share one namespace and one version. A host that runs another agent, or has no terminal, cannot say which parts it implements.
3. **Clients know Pi.** Records travel as Pi's lines (`format: "pi3"`), and every client carries a Pi adapter. A client that shows a Codex or Claude Code Session would need another adapter each time.
4. **The ideas are good and general.** One writer per log, resuming from a hash chain, commands that run at most once and are confirmed by the log, and short pairing codes are not specific to a terminal app. They are what any system that runs agents on one machine and steers them from another needs.
5. **ATXF already defines half of it.** ATXF is how a transcript is stored and exchanged at rest: a tree of records, hashes that commit to content and references, seals with a count, a chain and heads. RFD0018's upload state is already `{count, chain, heads}`. AXP is how the same transcript is exchanged live.
6. **Doing it in place would be slower.** Formalizing while keeping every Axo peer working would tie each decision to a migration. Designing AXP on its own, then moving Axo once, keeps the two problems apart.

## Goals

- A specification someone outside Axo can implement from the documents: a host that is not a Mac, a hub that is not Cloudflare, a client that is not Apple.
- A core that is small enough to implement in a day; extensions that each stand alone.
- ATXF as the log format, so AXP adds replication and control, not another transcript format.
- Reference implementations in TypeScript and Rust that agree byte for byte, and a Swift binding, all running one conformance suite.
- A reference hub, host and client, so the suite exercises whole exchanges, not only messages.
- Feynman models of the core's distributed behaviour.
- A specification site at `axp.leostera.dev`, built from `axp/`.

## Non-goals

- Changing Axo. Axo's migration to AXP is its own RFD.
- Compatibility with Axo's current wire. AXP has its own names; a mapping is the migration RFD's concern.
- Specifying sign-in. How the first device of an account gets in (Cloudflare OAuth, RFD0013, RFD0020) is the hub's choice.
- Changing ATXF. Where AXP needs something ATXF does not have, it is proposed to ATXF.
- Hub-to-hub federation.

## Guide-level explanation

### Roles

- A **host** runs agent Sessions and is the only writer of each Session's log.
- A **hub** connects hosts and clients that cannot reach each other. It holds an account, keeps a replica of each Session's log, and routes commands to the host that runs the Session.
- A **client** shows Sessions and sends commands.

A client may connect to a host directly (over a local socket) or through a hub. The messages are the same. A hub is a replica that a client cannot tell from the host, except that it still answers when the host is offline.

### A connection

Every connection is JSON-RPC 2.0, newline-delimited over a stream or one message per WebSocket text frame. It starts with `axp.hello`:

```json
{"jsonrpc":"2.0","id":1,"method":"axp.hello","params":{"axp":"0.1","role":"client","device":"dev_7Kq…","extensions":{"pi":"0.1","terminal":"0.1"}}}
{"jsonrpc":"2.0","id":1,"result":{"axp":"0.1","role":"hub","account":"acc_9f…","challenge":"q3Zp…","extensions":{"pi":"0.1"},"limits":{"messageBytes":65536,"batchRecords":64}}}
{"jsonrpc":"2.0","id":2,"method":"axp.auth","params":{"signature":"…"}}
```

The device proves it holds its key by signing the challenge. The reply to hello names the extensions both sides speak; a peer MUST NOT send a method of any other.

### Pairing

A new device joins an account with a code made by a device already in it:

1. A signed-in device asks the hub for a code: `axp.pair.create` → `{"uri":"axp://hub.example/pair/0123-ABCD","expiresAt":"…"}`.
2. The new device generates an Ed25519 key, connects without credentials, and calls `axp.pair.redeem` with the code, its public key, its role, kind and label. That is the only method an unauthenticated connection may call.
3. The hub binds the key to the account and closes the connection. From then on the device connects with `axp.hello` and `axp.auth`.

No secret crosses the wire after pairing, and the hub stores only public keys. A device is removed with `axp.device.revoke`, which closes its connections.

### Logs are ATXF transcripts

A Session's log is an ATXF transcript with integrity declared. The header's `id` is the `sessionId`. The host writes records; ATXF's hashes commit each record to its content and the records it references.

A replica, whether a hub or a client, says what it holds as an ATXF seal's values, `{count, chain, heads}`, and the other side sends what follows:

```json
{"jsonrpc":"2.0","id":7,"method":"axp.log.open","params":{"host":"…","session":"…","have":{"count":120,"chain":"sha256:…"},"window":{"last":20}}}
```

The same exchange runs in both directions of the hub: the host pushes to the hub, the hub pushes to clients. The receiver checks the chain, so a hub cannot insert or drop a record without being caught.

A Pi host converts Pi's session file to ATXF as Pi writes it, with ATXF's Pi converter, carrying each Pi line in `native`. A phone renders ATXF. pi-axo, which draws Pi's own screen, reads the Pi lines back from `native`, losslessly.

### Commands

A client asks the host to do something with `axp.command`, naming an extension method and a `commandId`. The host runs it at most once per `commandId` and answers `accepted`, `rejected` or `unknown`. A record the command produces carries `ext.axp.commandId`; because `ext` is covered by the record's hash, a client knows its prompt landed, and no hub can fake it.

### Extensions

| Extension | Roles | Adds |
| --- | --- | --- |
| `pi` | host, client | commands `pi.prompt`, `pi.stop`, `pi.answer`, `pi.restart`; how Pi's records map to ATXF and back |
| `terminal` | host, client | shells, panes, layouts, viewports; `terminal.input`, `resize`, `screen`; a lossy output stream |
| `connections` | hub, host | tools a Session calls through the hub: list, search, execute, bash, log, add, remove, sign-in |
| `share` | hub, host | publishing a redacted, read-only copy of a Session |
| `upgrade` | host, client | a planned restart, so clients wait instead of failing |
| `local` | host, client | host control over a local socket: health, config, creating and closing Sessions |

A host that runs Codex headless implements the core and its own agent extension; the phone shows its Sessions without changes.

### The repository

```text
axp/
├── README.md                     # what AXP is, design in one screen, contents, status
├── PRODUCT.md                    # the brief for the site
├── SPEC.md                       # AXP core, normative
├── extensions/
│   ├── README.md                 # registry: identifier, version, status, document
│   ├── pi.md
│   ├── terminal.md
│   └── …
├── schema/v0.1/
│   ├── axp.schema.json
│   └── ext/<extension>/<version>/<extension>.schema.json
├── examples/                     # whole exchanges, one message per line with its direction
├── fixtures/                     # valid and invalid messages, chains, pairing vectors
├── specs/                        # Feynman models
├── packages/
│   ├── axp-ts/                   # types, validators, reference hub, host and client
│   ├── axp-rs/                   # the same API, the same bytes and hashes
│   └── axp-swift/                # types, validators, client
└── scripts/cross-check.sh
```

`sites/axp.leostera.dev` is the same Astro and Kumo site as `atxf.leostera.dev`: RFC front matter, numbered sections, a contents sidebar, the extension registry, schemas and examples, rendered from `axp/` with no content of its own.

## Reference-level explanation

### `SPEC.md`

1. **Model.** Roles; accounts, devices, hosts, Sessions, logs, commands; what each role stores.
2. **Conventions.** RFC 2119; JSON and UTF-8; identifiers (UUIDs for hosts and Sessions, opaque strings for devices and commands); times.
3. **Transports.** Stream and message framing. A transport with a frame limit MUST fragment larger messages (`axp.fragment`, `axp.discard`) and send them by priority class: control, then durable, then ephemeral. RFD0016 and RFD0018's fragments, made core because every message transport has a limit.
4. **Connection.** `axp.hello`, `axp.auth`, version and extension negotiation, limits, `axp.bye`, closing.
5. **Trust.** Accounts and devices. Local peers are trusted by the operating system (the socket's owner) and skip `axp.auth`. Pairing codes: Crockford base32 `XXXX-XXXX`, single use, at most ten minutes, rate limited by the hub globally and per source, stored only as a keyed hash. Pairing URIs `axp://<hub>/pair/<code>`. Device keys (Ed25519), challenges, revocation, what an open connection does when its device is revoked.
6. **Hosts.** `hostId`, `generation` (new on every start, so nothing routes to a process that is gone), `kind` (an open slug), label, presence, leases.
7. **Sessions.** `sessionId`, metadata and its version (name, created and last-activity times, archived; anything else under `ext`), status (`starting`, `ready`, `working`, `needsAttention`, `unavailable`), removal.
8. **Logs.** An ATXF transcript with integrity. The replication exchange: offer `{count, chain, heads}`, send what follows in batches, acknowledge each batch, page older records, verify the chain. Windows and flow control. Recovery when a host has lost records a replica holds (see Unresolved questions).
9. **Commands.** `axp.command`, `commandId`, at most once, receipts, `ext.axp.commandId` on the records a command produces, routing through a hub, timeouts.
10. **Ephemeral state.** Per-Session slots that hold only their latest value and are never stored. The reply being written is a slot whose value is the ATXF record it will become.
11. **Notifications.** What is pushed (directory changes, new records, slots), coalescing, ordering per connection.
12. **Errors.** Reserved JSON-RPC codes and what each means for a retry: `retryable`, `unknown`, `never`.
13. **Limits.** Every bound, its default, and whether it is negotiated.
14. **Extensions.** Identifiers (lowercase slugs; reverse-DNS for private ones), versions, negotiation, namespacing (an extension's methods start with its identifier), what an extension may add and what it may not change.
15. **Versioning.** `0.x` may break; from `1.0` minor versions only add. AXP 0.1 requires ATXF 0.1.
16. **Security.** One writer per log; hubs cannot forge records or receipts; command authorization; replay; resource exhaustion.
17. **Privacy.** A hub stores logs and metadata, never terminal bytes or ephemeral slots; retention is the hub's to declare.

Each extension document has front matter (identifier, version, status, requires, roles) and the sections it needs.

### What AXP needs from ATXF

- **Incremental conversion.** A host converts its agent's records as they are written, not a whole file at once. ATXF's roadmap has streaming converters; AXP needs at least the Pi converter in Rust to work line by line, with stable ids.
- **Seals without a seal record.** A replica's offer is the values a seal would have after its last record, computed without writing one. ATXF §17.2 defines them; AXP uses the definition, not the record.
- **`ext.axp`.** A namespace for AXP's fields on records, starting with `commandId`.

### Implementations and conformance

- **`axp-ts`**: types, validators, the replication exchange, and a reference hub, host and client that run in memory. Depends on `@leostera/atxf`.
- **`axp-rs`**: the same API, depending on the `atxf` crate. Encodes the same values to the same bytes.
- **`axp-swift`**: types, validators and a client, checked against the same fixtures.
- **Conformance**: every implementation parses every fixture and rejects the invalid ones for the stated reason; the reference peers run every example exchange, mixing TypeScript and Rust peers.
- **Models**: Feynman specs for replication (one writer, chain verification, a lost host), delivery to clients, commands (at most once across reconnects and hub restarts), fragments, pairing (a code redeemed once, a revoked device cut off). They start from today's `specs/session-sync.ts`, `client-delivery.ts`, `relay-fragments.ts` and `remote-sessions.ts`.

### Bazel

`axp/` builds and tests with the rest of the repository: `bazel test //axp/...` runs schema checks, conformance, cross-check and the models; `bazel build //sites/axp.leostera.dev:site` builds the site. Packages here are not used by Axo until the migration RFD.

## Rollout

1. **Core and site.** `README.md`, `SPEC.md`, `schema/v0.1/axp.schema.json`, examples, the site. Deploy `axp.leostera.dev` with the spec marked as a draft.
2. **Reference implementations.** `axp-ts` and `axp-rs` with the reference peers, fixtures, cross-check and the core models. The ATXF changes they need land in ATXF first.
3. **Extensions.** `pi` and `terminal` first, since Axo needs them; then `connections`, `share`, `upgrade`, `local`. Each with its schema, examples and fixtures.
4. **Swift.** `axp-swift` against the same fixtures.
5. **Axo migration.** Well after AXP 0.1 is complete and has settled, and in a new RFD: which Axo pieces implement which role, the order, and the cutover.

## Testing

- `bazel test //axp/...`: schemas valid; examples and fixtures against the schemas; conformance on each implementation; cross-check; reference peers through every example exchange; the Feynman models.
- The site's test builds it and checks that every schema is served at its `$id` with `application/schema+json`, and every method has an anchor.

## Drawbacks

- **Two protocols for a while.** Until Axo moves, the repository holds Axo's wire and AXP side by side, and fixes to one do not reach the other.
- **The design can drift from reality.** A protocol designed apart from its only user can make choices Axo then fights. The reference peers and models reduce this; the migration RFD is where it is paid.
- **ATXF becomes a dependency of the wire.** A breaking ATXF change is a breaking AXP change, and every host converts its agent's format to ATXF as it writes.
- **More documents to keep.** Every method needs prose, a schema, an example and two implementations.
- **A public draft invites outside readers.** The site must say plainly that AXP is 0.x.

## Rationale and alternatives

- **Document Axo's wire as it is.** Cheaper and changes nothing, but writes down one product's wire, not a protocol, and keeps Pi in every client.
- **Formalize Axo's wire in place, extension by extension.** Ties every design decision to a live migration. Designing first and moving once is less work in total.
- **Keep `pi3` as the log format, with ATXF as an option.** Keeps the host simple, but every client needs one adapter per agent, and AXP would need a hash chain of its own that ATXF already defines.
- **Bearer credentials, as Axo has today.** Simpler, but the secret crosses the wire on every connection and the hub stores verifiers of it. With no compatibility to keep, device keys cost little more.
- **A separate repository now.** Cleaner, but AXP and its first user would change in two places at once. `axp/` is laid out to move.
- **Protobuf or another IDL.** Every peer speaks JSON, and ATXF is JSON Schema.
- **MCP or ACP.** MCP connects a model to tools; ACP connects an editor to an agent on the same machine. Neither has hosts, hubs, replicated logs with one writer, or commands that survive a reconnect. MCP appears in AXP as a tool source in `connections`.

## Unresolved questions

Before acceptance:

- ~~When a host has lost records a replica holds, does the host recover them from the replica, or does the log start a new epoch?~~ Recovery; see As specified.
- Is `upgrade` core? Every client benefits from knowing a host is restarting on purpose.
- Is `local` an extension or out of AXP? It is the least general part.
- Are the packages published (`@leostera/axp`, the `axp` crate) from the start, as ATXF's are, or private until 1.0?

During implementation:

- How much of a hub's account model (accounts, devices, revocation) the spec fixes, and how much it leaves to the hub.
- Whether slots carry whole values or patches, given that a reply being written can be large.

Out of scope:

- Signing seals with the host's device key, so a replica can prove who wrote a log.
- Handing a Session's writer from one host to another; continuing elsewhere is a new Session whose ATXF header names the old one as its parent.

## Future possibilities

- A conformance kit that drives a host, hub or client from outside.
- Hosts other than axod: a headless Linux host running Codex or Claude Code.
- Reconciling Sessions continued on two hosts with ATXF §18.
- Signed seals, from the device keys pairing already creates.

## As specified

`axp/` (SPEC.md, extensions/, schema/v0.1, examples/) and `sites/axp.leostera.dev` implement rollout step 1 and the documents of step 3. Where writing the spec changed this RFD's design:

- **No `axp.command` envelope.** A hub forwards any extension method whose params carry `hostId` to that host without understanding it (SPEC §10.1). A routed call that carries a `commandId` is a command (SPEC §10.2). `pi.prompt` is sent as itself, not wrapped.
- **One exchange for replication.** The hub reads each log from its host with the same `axp.log.open`/`records`/`ack` a client uses to read from the hub (SPEC §9.2, §9.3). There is no separate upload method set.
- **Recovery, not epochs.** Logs are append-only and never truncated. A host that lost records a replica holds reads them back and rebuilds its log as the common prefix, the replica's records, then its own; ATXF record hashes do not depend on position (SPEC §9.4).
- **A `sessions` extension** for creating, renaming and archiving Sessions remotely, which the core leaves out; `local` keeps only health, configuration, the hub link and the viewport.
- **An `assets` extension**, from RFD0030: files named by the SHA-256 of their bytes, uploaded and read in band or through a URL the hub hands out, attached to commands such as `pi.prompt`, and referred to from logs by RFC 6920 `ni:` URIs.
