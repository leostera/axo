# RFD0025 - Axo: AXP, the Agent Xchange Protocol

- Feature Name: `axp`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-02
- Updated: 2026-11-02
- Document Type: Proposal

## Summary

I propose that we take the protocol axod, the Mac app, the phone, the web app, pi-axo and the API speak to each other, and make it a protocol of its own: **AXP, the Agent Xchange Protocol**. AXP is written the way ATXF is (`github.com/leostera/atxf`): a normative `SPEC.md` with RFC 2119 keywords and numbered sections, JSON Schemas at stable URLs, examples, conformance fixtures, implementations in more than one language that must agree, Feynman models of its distributed behaviour, and a specification site at `axp.leostera.dev`.

- **A small core.** The core says how hosts, hubs and clients find each other, open a connection, agree on a version and on extensions, list hosts and Sessions, keep a copy of a Session's log, and send commands with receipts. It knows nothing about terminals, Pi, or Cloudflare.
- **Extensions for the rest.** Terminals and panes, Pi's record format and its commands, connections and tools, sharing, pairing, planned upgrades and large-message fragments are each an extension with its own document, schema and version. A peer says in its hello which extensions it speaks.
- **Axo is one implementation.** axod is a host, the API Worker is a hub, AxoMac, AxoPhone, the web app and pi-axo are clients. A mapping document records how today's `axo.*` wire maps onto AXP, the way ATXF's `docs/mappings.md` maps Pi and Codex.
- **A clean cutover on the wire.** AXP has its own method names. Axo's peers move to them together and the `axo.*` names are deleted, rather than carried as a second dialect.
- **Its own directory.** `axp/` at the root of this repository is laid out like the ATXF repository, so it could move to a repository of its own without changes.

## Motivation

The protocol has outgrown the place it was written down, and it is worth more than one product's wire format.

1. **Most of it is not specified.** `schemas/axo.leostera.dev/README.md` describes the first design: local RPC, the host relay and events. Since then RFD0016, RFD0018, RFD0019, RFD0022 and RFD0024 added the client socket, transcript sync, fragments, planned restarts, the peers socket and remote commands. Those exist as Zod in `packages/axo-api/src/session-sync.ts` and `fragments.ts`, Rust in `crates/axo-relay/`, Swift in `apple/AxoClient/`, and prose in five RFDs. The schemas name 61 wire identifiers; the code uses about 130.
2. **It is in five places with three names.** `schemas/`, `specs/`, `crates/axo-protocol`, `apple/AxoProtocol`, and `@axo/protocol` in a directory called `packages/axo-api`.
3. **Drift is caught by hand.** `crates/axo-protocol/src/conformance.rs` and `packages/axo-api/scripts/check-schemas.mjs` check the fixtures that exist. Nothing notices a method that has none, and the Swift binding does not read the shared fixtures at all.
4. **Versions are confusing.** The schema directory is `v1`, the negotiated `protocolVersion` is 2, and the retired `/v1` HTTP API (`axo.machine.*`, `axo.runtime.*`, `axo.state.*`) is a third thing called v1.
5. **Everything is mixed together.** Session listing, Pi prompts, PTY bytes and tool connections share one namespace and one version. A host that runs a different agent, or has no terminal, cannot say which parts it implements. `hostKind` is already an open slug, and records already carry a `format` (`pi3`), so the design is half way to a core with extensions; the documents are not.
6. **The pieces fit ATXF.** ATXF is how an agent transcript is stored and exchanged at rest. AXP is how a live Session is exchanged between machines. A Session log in AXP can be an ATXF transcript: same tree, same hash chain, same seals. Writing both the same way makes that a design choice rather than an accident.

## Goals

- A protocol specification that someone outside Axo can implement from the documents alone: a host that is not a Mac, a hub that is not Cloudflare, a client that is not Apple.
- A core that is small enough to implement in a day, and extensions that each stand alone.
- Every message any two Axo components exchange is in the core or in an extension, with a schema and an example.
- Two implementations that must agree, as ATXF's TypeScript and Rust do, checked by a shared conformance suite; Swift checked against the same fixtures.
- A specification site at `axp.leostera.dev`, built from `axp/` by Bazel, in the style of `atxf.leostera.dev`.

## Non-goals

- Changing behaviour. Moving to AXP renames and regroups messages; limits, ordering and failure semantics stay what RFD0016–RFD0024 made them. Bugs found while specifying are fixed in their own changes.
- Generating the bindings from the schemas. They stay handwritten (parse, don't validate) and are tested against the schemas.
- Specifying sign-in. How a peer gets a credential (Cloudflare OAuth, RFD0013, RFD0020) is outside AXP; AXP says where the credential goes and what the hub checks.
- Replacing Pi's session file. The `pi` extension carries Pi's lines as they are.
- Splitting `axp/` into its own repository now.

## Guide-level explanation

### Roles

AXP has three roles.

- A **host** runs agent Sessions. It is the only writer of each Session's log. axod is a host.
- A **hub** connects hosts and clients that cannot reach each other. It keeps a durable copy of each Session's log, fans out what changes, and routes commands to the host that runs the Session. The API Worker (HostDO, SessionDO, ClientDO) is a hub.
- A **client** shows Sessions and sends commands. AxoPhone, the web app, AxoMac and pi-axo are clients.

A client may speak to a host directly (AxoMac and pi-axo over axod's Unix socket) or through a hub (the phone). The core messages are the same either way; a hub adds host routing and durable copies.

### The core

Every connection is JSON-RPC 2.0 over a transport the core defines: newline-delimited over a stream (a Unix socket), or one message per text frame (a WebSocket). It begins with `axp.hello`:

```json
{"jsonrpc":"2.0","id":1,"method":"axp.hello","params":{"axp":"0.1","role":"client","peerId":"c_4Fh2kQ9x","extensions":{"pi":"0.1","terminal":"0.1"}}}
{"jsonrpc":"2.0","id":1,"result":{"axp":"0.1","role":"hub","extensions":{"pi":"0.1","terminal":"0.1"},"limits":{"messageBytes":65536,"batchRecords":64}}}
```

The reply names the extensions both sides speak. A peer MUST NOT send a method of an extension that is not in the reply.

After hello, the core has three things:

1. **Hosts and Sessions.** `axp.hosts` and `axp.sessions` list them; `axp.hosts.changed` and `axp.sessions.changed` notify. A host has a stable `hostId` and a `generation` that changes on every restart, so nothing routes to a host process that is gone. A Session has a `sessionId` (a UUID, RFD0017), metadata, and a status.
2. **Logs.** A Session's log is a list of opaque records with a hash chain, in a declared `format`. A host uploads it (`axp.log.sync`, `axp.log.append`, `axp.log.chainAt`, `axp.log.truncate`). A client opens a window on it, receives batches and acknowledges each one before it gets the next (`axp.log.open`, `axp.log.records`, `axp.log.ack`, `axp.log.older`, `axp.log.close`). Ephemeral `progress` (the reply being written) travels beside the log and is never stored. This is RFD0018, written as a protocol.
3. **Commands.** A client asks a host to do something with `axp.command`, naming an extension method and a `commandId`. A host runs a command at most once per `commandId` and reports `accepted`, `rejected` or `unknown`. A hub routes commands and never runs them. This is RFD0024's receipts, made general.

The core does not know what a record means or what a command does. Extensions do.

### Extensions

Each extension is a document with an identifier, a version, and a status, and says which roles implement it and what it adds: record formats, command methods, connection methods, notifications, capabilities.

| Extension | Adds | Axo today |
| --- | --- | --- |
| `pi` | record format `pi3`; commands `pi.prompt`, `pi.stop`, `pi.answer`, `pi.restart` | `axo.remote.*` Pi commands, `axo.session.prompt`, RFD0019, RFD0024 |
| `atxf` | record format `atxf/0.1`, whose hashes and seals are the log's chain | not yet |
| `terminal` | shells, panes, layouts, viewports; `terminal.input`/`resize`/`output`/`screen` | `axo.shell.*`, `axo.terminal.*`, `axo.session.layout.set`, `axo.client.viewport.set`, `axo.remote.terminal.*` |
| `fragments` | messages larger than one frame; `fragments.part`, `fragments.discard`, priority classes | `axo.transport.*`, RFD0016, RFD0018 |
| `connections` | tools a Session may call through the hub; `connections.list`/`search`/`execute`/`bash`/`log`/`add`/`remove`/`signIn` | `axo.connections.*`, RFD0016 |
| `share` | publishing a redacted, read-only copy of a Session | `axo.host.share.publish`, `/api/public-sessions` |
| `pairing` | binding a host to an account with a one-time code | pairing routes, `axo.host.register`, RFD0013 |
| `upgrade` | a host announcing a planned restart so clients wait instead of failing | `axo.host.prepareUpgrade`, RFD0019, RFD0023 |
| `peers` | a host acting as a client of the hub on behalf of its local clients | `axo.peer.*`, RFD0022, RFD0024 |
| `local` | host control a local client needs: health, config, creating and closing Sessions | `axo.daemon.*`, `axo.config.*`, `axo.session.create`/`close`/`reopen` |

`terminal` and `local` are the ones that make Axo Axo. A host that runs agents headless can implement the core, `pi` and nothing else, and the phone still shows its Sessions.

### The repository

`axp/` is laid out like the ATXF repository:

```text
axp/
├── README.md                     # what AXP is, design in one screen, contents, status
├── PRODUCT.md                    # the brief for the site
├── SPEC.md                       # AXP core, normative
├── extensions/
│   ├── README.md                 # the registry: identifier, version, status, document
│   ├── pi.md
│   ├── terminal.md
│   ├── fragments.md
│   └── …
├── docs/
│   └── axo-mapping.md            # informative: today's axo.* wire → AXP, and how Axo implements each role
├── schema/v0.1/
│   ├── axp.schema.json           # core messages
│   └── ext/<extension>/<version>/<extension>.schema.json
├── examples/                     # whole exchanges, one message per line with its direction
├── fixtures/                     # conformance vectors: valid, invalid, and hash-chain vectors
├── specs/                        # Feynman models: log sync, delivery, commands, fragments, upgrades
├── packages/
│   ├── axp-ts/                   # @leostera/axp: types, validators, a reference hub and client
│   ├── axp-rs/                   # the axp crate: the same API, the same bytes and hashes
│   └── axp-swift/                # the AXP Swift module
└── scripts/cross-check.sh        # the TypeScript and Rust implementations must agree byte for byte
```

`sites/axp.leostera.dev` is the specification site, the same Astro and Kumo site as `atxf.leostera.dev`: RFC front matter (designator, status, version, updated), numbered sections, a contents sidebar, the extension registry, schemas and examples. It renders the files in `axp/` and has no content of its own.

### Adding a method

A contributor adding a Pi command:

1. writes it in `axp/extensions/pi.md`, in the section for commands, with its params, result, errors and its at-most-once rule;
2. adds it to `axp/schema/v0.1/ext/pi/0.1/pi.schema.json`, and an exchange to `axp/examples/`;
3. implements it in `axp-ts` and `axp-rs`, and in axod and the clients;
4. runs `bazel test //axp/...`, which fails if the examples do not validate, if the two implementations disagree, or if any code in the repository names a method no document defines.

## Reference-level explanation

### The specification documents

`SPEC.md` is normative and numbered, like ATXF's. Its sections:

1. **Model.** Roles, hosts, Sessions, logs, commands; what each role stores.
2. **Conventions.** RFC 2119 keywords; JSON; UTF-8; identifiers (UUIDs for hosts and Sessions, opaque strings for peers and commands); times.
3. **Transports.** Stream framing (newline-delimited JSON) and message framing (one JSON-RPC message per WebSocket text frame). Maximum message size is negotiated; larger messages need `fragments`.
4. **Connection lifecycle.** `axp.hello`, version and extension negotiation, `limits`, `axp.bye`, what a peer does on close.
5. **Authentication.** A credential is presented by the transport (a bearer token on the WebSocket upgrade, or the Unix socket's owner). The hub checks that a host serves the account it claims and that a client belongs to the account. AXP does not define how credentials are issued.
6. **Hosts.** `hostId`, `generation`, `kind` (an open slug), label, presence, leases and heartbeats, what offline means.
7. **Sessions.** `sessionId`, metadata and its version, status, the snapshot a host publishes, removal.
8. **Logs.** Records, formats, the hash chain, epochs and truncation, upload (`sync`, `append`, `chainAt`, `truncate`), delivery (`open`, `records`, `ack`, `older`, `reset`, `close`), windows, flow control, progress. This is the largest section and the one most carefully modelled (`specs/log-sync.ts`, `specs/log-delivery.ts`, from today's `specs/session-sync.ts` and `specs/client-delivery.ts`).
9. **Commands.** `axp.command`, `commandId`, at-most-once, receipts, how a receipt is matched to the record it produced, routing through a hub, timeouts.
10. **Subscriptions and notifications.** Which changes are pushed, coalescing, ordering per connection.
11. **Errors.** JSON-RPC codes AXP reserves, and what each means for a retry (`retryable`, `unknown`, `never`).
12. **Limits.** Every bound, its default, and whether it is negotiated.
13. **Extensions.** How an extension is identified, versioned, negotiated and namespaced; what it may add (methods, notifications, record formats, capabilities, fields under `ext`); what it may not change in the core.
14. **Versioning.** `0.x` drafts may break; from `1.0`, minor versions only add optional fields, methods and extensions, and a major version is negotiated.
15. **Security.** One writer per log; a hub cannot forge records (the chain is the host's); command authorization; replay; resource exhaustion.
16. **Privacy.** What a hub stores (logs, metadata) and what it must not (terminal bytes, progress); retention is the hub's to declare.

Each extension document has a fixed front matter (identifier, version, status, requires, roles) and the sections it needs: model, methods, notifications, record formats, errors, limits, security.

### Wire names

Core methods are `axp.<noun>.<verb>`. Extension methods are `<extension>.<noun>.<verb>`, and an extension's identifier is its namespace, so no two extensions can collide and a peer can reject a method by its prefix. Extension identifiers are lowercase slugs; a private extension uses a reverse-DNS identifier (`dev.leostera.axo.debug`).

The old names are not kept. `docs/axo-mapping.md` has one row per `axo.*` identifier in the code today: its AXP name, or *retired* with the reason (the `/v1` HTTP API's `axo.machine.*`, `axo.runtime.*` and `axo.state.*` are retired, not mapped).

### Versions

AXP starts at **0.1**, a draft, as ATXF does. The schema lives at `https://axp.leostera.dev/schema/v0.1/axp.schema.json`, and each extension's at `https://axp.leostera.dev/schema/v0.1/ext/<extension>/<version>/<extension>.schema.json`; each file's `$id` is its URL and the site serves it there. Extensions version independently of the core. Axo's current `protocolVersion` 2 has no successor number: a peer that sends `axo.protocol.negotiate` or `axo.client.hello` after the cutover is told to upgrade.

### Implementations and conformance

- **`axp-ts`** replaces the wire parts of `packages/axo-api` (`v1.ts`, `session-sync.ts`, `fragments.ts`, `pi3.ts`, `connections.ts`, `pairing.ts`, `share.ts`, `identity.ts`). It has types, Zod validators, the hash chain, and a small in-memory hub and client used by the conformance suite. The API Worker, the web app and pi-axo import it.
- **`axp-rs`** replaces `crates/axo-protocol` and the wire types now in `crates/axo-relay` (sync, fragments, peers, pi3). axod and axo-relay import it.
- **`axp-swift`** replaces `apple/AxoProtocol` and the wire models in `apple/AxoClient/Sources/AxoClient/Remote`. AxoClient, AxoMac and AxoPhone import it.
- **Fixtures** in `axp/fixtures/` are the shared vectors: messages that must parse, messages that must be rejected and why, hash chains and their expected values. Every implementation runs every fixture.
- **Cross-check**, as in ATXF: the TypeScript and Rust implementations encode the same values to the same bytes and compute the same hashes.
- **Coverage**: `//axp:coverage_test` scans the repository for method-name literals and fails on one that no document defines.
- **Models**: the Feynman specs that model the protocol move to `axp/specs/` and are renamed after the core section or extension they check.

### The site

`sites/axp.leostera.dev` follows `atxf.leostera.dev` (Astro, Kumo, fully prerendered, Workers Static Assets, a custom domain on the `leostera.dev` zone, no bindings), with three differences: it is built by Bazel like the rest of this repository, its pages are the core plus one page per extension, and `/extensions/` is the registry. `bazel run //:publish` deploys it from a clean main, with the checks it applies to the Mac app.

## Rollout

Each phase leaves main green and the apps working.

1. **Documents and site.** Create `axp/` with `README.md`, `SPEC.md`, the extension documents, `docs/axo-mapping.md`, schemas and examples, written from the code and RFD0013–RFD0024 as they are. Add `sites/axp.leostera.dev` and deploy it. Nothing in Axo changes yet, so the mapping document is the bridge.
2. **Implementations.** Create `axp-ts` and `axp-rs` with the AXP names, the fixtures, cross-check and the conformance suite. Then `axp-swift`.
3. **Cutover.** Move axod, the API Worker, the web app, pi-axo, AxoMac and AxoPhone to the AXP names and the new packages, in one coordinated change per surface: local (axod, AxoMac, pi-axo, released together in the app bundle), then host link and client (axod, the Worker, the phone, the web app). Delete `schemas/axo.leostera.dev`, `crates/axo-protocol`, `apple/AxoProtocol` and the wire parts of `packages/axo-api`. Turn on the coverage test.
4. **Models.** Move the protocol's Feynman specs to `axp/specs/` and link them from the site.

## Testing

- `bazel test //axp/...`: schema validity, examples and fixtures against the schemas, the conformance suite on each implementation, cross-check, the coverage test.
- The site's test builds it and checks that every schema is served at its `$id` with `application/schema+json`, and every method in a schema has an anchor on its page.
- Cutover is covered by the existing suites (axod, the API Worker, AxoClient, AxoPhone, pi-axo), which keep running against the new names, and by running the phone and the web app against a preview of the Worker before deploying.

## Drawbacks

- **A cutover.** Hubs, hosts and clients have to move at once per surface, and a phone with an old build stops working until it is updated. Today that is Leo's devices; it will not stay that cheap, which is an argument for doing it now.
- **More documents to keep.** A method now needs prose, a schema, an example and two implementations before it lands. That is the point, but small protocol changes get slower.
- **Abstraction cost.** Splitting `terminal` from the core and `pi` from the log means generic envelopes (`axp.command` naming an extension method) where today there are direct calls. One more layer to read in every trace.
- **A public spec invites outside readers.** The site must say plainly that AXP is a 0.x draft and changes when Axo needs it to.

## Rationale and alternatives

- **Do nothing.** The protocol keeps working and stays readable only to someone who knows where its five homes are. Every RFD that touches it keeps adding prose to itself.
- **Document the `axo.*` wire as it is.** The first draft of this RFD: move the schemas, write the missing ones, keep every name. Cheaper and no cutover, but it writes down one product's wire, not a protocol: no core, no extensions, nothing another host or client could implement in part.
- **Core and extensions, but keep `axo.*` names.** Avoids the cutover, but extension namespaces are what let a peer reject what it does not speak, and they cannot be retrofitted onto `axo.remote.*`, which mixes Pi and terminal methods.
- **A separate repository now**, like ATXF. Cleaner, but every change to AXP during the cutover would be two changes in two repositories. `axp/` is laid out to be moved later.
- **Protobuf or another IDL.** Every peer speaks JSON-RPC today, Pi's records are JSON lines, and ATXF is JSON Schema. A different encoding would add a toolchain for no gain at these message rates.
- **Use MCP or ACP.** The Model Context Protocol connects a model to tools, and the Agent Client Protocol connects an editor to an agent on the same machine. Neither has hosts, hubs, durable logs with one writer, or commands that survive a reconnect. AXP's `connections` extension is where MCP shows up, as a tool source.

## Unresolved questions

Before acceptance:

- Is the log's hash chain AXP's own (RFD0018's chain) or ATXF's (§17)? Adopting ATXF's would make `atxf` the natural record format and `pi3` a legacy one; keeping RFD0018's leaves the core independent of ATXF.
- Is `local` an extension, or Axo's private API outside AXP? It is the least general part, but AxoMac speaks it over the same socket as everything else.
- Do `pairing` and `share` belong in AXP, or are they Axo's hub features?
- Is the TypeScript package `@leostera/axp`, published like `@leostera/atxf`, or private to this repository until 1.0?

During implementation:

- Which of the TypeScript legacy contracts are still reachable, and can they be deleted with the `/v1` routes?
- Whether the coverage test can stay a regex over sources, or needs each implementation to export its method table.

Out of scope:

- Signing records or seals, so a hub can prove what a host wrote.
- Hub-to-hub federation.

## Future possibilities

- A conformance kit: fixtures and a driver that exercises a host, hub or client from the outside, so another implementation can check itself.
- Hosts other than axod: a headless Linux host that implements the core and `pi`, or one that runs another agent with its own record format.
- An `atxf`-native log, so a Session synced through AXP is an ATXF transcript at rest, reconcilable with ATXF §18 when a Session continues on two hosts.
