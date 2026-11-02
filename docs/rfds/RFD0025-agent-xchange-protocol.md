# RFD0025 - Axo: AXP, the Agent Xchange Protocol

- Feature Name: `axp`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-02
- Updated: 2026-11-02
- Document Type: Proposal

## Summary

I propose that the protocol axod, the Mac app, the phone, the web app, pi-axo and the API speak to each other becomes a thing of its own, named AXP (Agent Xchange Protocol), with its own top-level directory `axp/` and its own site at `axp.leostera.dev`.

- **One home.** `axp/` holds the normative spec (prose), the JSON Schemas, the fixtures, the Feynman models of the protocol, and the three bindings (Rust, Swift, TypeScript). Today these live in `schemas/axo.leostera.dev/`, `specs/`, `crates/axo-protocol/`, `apple/AxoProtocol/` and `packages/axo-api/`.
- **Every surface written down.** The schemas cover 61 wire identifiers; the code uses about 130. The client socket (`axo.client.*`), the Mac-to-Mac peers calls (`axo.peer.*`), transcript upload (`axo.host.sync`, `axo.host.session.*`), sharing and the transport layer (`axo.transport.*`) have no schema at all. AXP v1 describes what is deployed, all of it.
- **One conformance suite.** Each binding runs the same fixtures, and a method in the code with no schema fails the build.
- **No change on the wire.** Method names keep their `axo.` prefix and the negotiated `protocolVersion` stays 2. AXP is a new name for the contract, not a new protocol. Installed phones and Macs keep working.
- **A site.** `sites/axp.leostera.dev` is a static site that renders the spec, lists every method by surface, and serves the schemas at the URLs their `$id`s name.

## Motivation

The protocol has outgrown the place it was written down.

1. **Most of it is not specified.** `schemas/axo.leostera.dev/README.md` describes the first design (local RPC, host relay, events). Since then RFD0016, RFD0018, RFD0019, RFD0022 and RFD0024 added the client socket, transcript sync, fragments, planned restarts, the peers socket and remote commands. Those exist only as Zod schemas in `packages/axo-api/src/session-sync.ts` and `fragments.ts`, Rust in `crates/axo-relay/`, Swift in `apple/AxoClient/`, and prose spread across five RFDs. A reader who wants to know what `axo.client.session.open` takes has to read three implementations and hope they agree.
2. **It is in five places.** Schemas, models, and three bindings live in different trees with different names (`axo-protocol`, `AxoProtocol`, `@axo/protocol` in a directory called `axo-api`). Nothing says they are one thing.
3. **Drift is caught by hand.** `crates/axo-protocol/src/conformance.rs` and `packages/axo-api/scripts/check-schemas.mjs` check the fixtures that exist, but nothing notices a method that has none. The Swift binding does not read the shared fixtures at all.
4. **Versions are confusing.** The schema directory is `v1`, the negotiated `protocolVersion` is 2, and the legacy `/v1` HTTP API (`axo.machine.*`, `axo.runtime.*`, `axo.state.*` in `packages/axo-api/src/contracts.ts` and `state-contracts.ts`) is a third thing called v1 that is now fail-closed.
5. **It is worth naming.** The protocol is not about a terminal app: it moves agent Sessions, their logs, their commands and their tools between hosts and clients. Other hosts (`hostKind` is already an open slug) and other clients could speak it. A name and a spec make that possible to talk about.

## Goals

- One directory, `axp/`, that is the source of truth for every message any two Axo components exchange.
- A written spec for each surface: who talks to whom, over what transport, with what framing, authentication, ordering, limits and failure semantics.
- Every wire identifier in the code has a schema and at least one fixture, enforced by a test.
- The Rust, Swift and TypeScript bindings are checked against the same fixtures.
- A public, static site at `axp.leostera.dev` built from `axp/` by Bazel.

## Non-goals

- Renaming wire identifiers (`axo.*` → `axp.*`). See Unresolved questions.
- Changing any message, limit or behaviour. Bugs found while writing the spec get their own changes.
- Generating the bindings from the schemas. They stay handwritten (parse, don't validate) and are tested against the schemas.
- Specifying the HTTP sign-in flow (OAuth with Cloudflare). AXP v1 describes the pairing and account routes it depends on, and refers to RFD0013 and RFD0020 for the rest.
- Specifying Pi's own transcript format beyond what crosses the wire (`pi3` lines are opaque records with a hash chain).

## Guide-level explanation

AXP is what Axo's components say to each other. It has four surfaces, named by who is on each end:

| Surface | Ends | Transport | Today's prefixes |
| --- | --- | --- | --- |
| **Local** | AxoMac, pi-axo ↔ axod | newline-delimited JSON-RPC 2.0 over a Unix socket | `axo.protocol.*`, `axo.daemon.*`, `axo.session.*`, `axo.shell.*`, `axo.terminal.*`, `axo.client.viewport.set`, `axo.relay.*`, `axo.peer.*`, `axo.config.*` |
| **Host link** | axod ↔ HostDO | JSON-RPC 2.0 over a WebSocket, with fragments | `axo.host.*`, `axo.transport.*`, `axo.remote.*`, `axo.connections.*` |
| **Client** | AxoPhone, web app, axod's peers socket ↔ ClientDO | JSON-RPC 2.0 over a WebSocket | `axo.client.*` |
| **Account HTTP** | any client ↔ the API Worker | HTTPS, JSON bodies | `/api/auth/*`, `/api/v1/account/*` |

Each surface has a page in the spec, and each page has the same parts: the ends and their roles, the transport and framing, how a connection starts (negotiate or hello), authentication, the methods and events, limits, ordering and failure. Shared values (IDs, `HostRef`, `SessionSnapshot`, layouts, viewports, `pi3` records) are in a common page.

A contributor adding a method now:

1. writes it in `axp/spec/<surface>.md` and adds its params and result to `axp/schemas/v1/<surface>.schema.json`,
2. adds a call and a result fixture under `axp/fixtures/v1/`,
3. implements it in the bindings that need it, and
4. runs `bazel test //axp/...`, which fails if a binding parses a fixture differently from the schema, or if any binding names a method the schemas do not.

A reader opens `https://axp.leostera.dev`, picks a surface, and sees each method with its schema and an example.

### Layout

```text
axp/
├── README.md                 # what AXP is, versioning rules, how to change it
├── BUILD.bazel               # //axp:schemas, //axp:fixtures, //axp:coverage_test
├── spec/                     # normative prose, one page per surface
│   ├── overview.md
│   ├── common.md
│   ├── local.md
│   ├── host-link.md
│   ├── transport.md          # fragments, discard, priorities (RFD0016, RFD0018)
│   ├── client.md
│   ├── account-http.md
│   └── legacy.md             # protocolVersion < 2 and /v1, fail-closed
├── schemas/v1/               # from schemas/axo.leostera.dev/v1, plus the missing surfaces
├── fixtures/v1/
├── models/                   # the Feynman specs that model protocol behaviour, from specs/
└── bindings/
    ├── rust/                 # crate `axp`, from crates/axo-protocol
    ├── swift/                # module `AXP`, from apple/AxoProtocol
    └── typescript/           # package `@axo/axp`, the wire part of packages/axo-api
```

`sites/axp.leostera.dev` sits beside `sites/axo.leostera.dev` and reads `//axp:spec` and `//axp:schemas` as Bazel inputs.

## Reference-level explanation

### Versions

AXP has one version number: the `protocolVersion` that `axo.protocol.negotiate` and `axo.client.hello` already carry. It is **2** today. The schema directory follows it: what is now `v1/` is published as AXP 2 under `axp/schemas/v1/` for this RFD, and renamed only if we cut a new version (see Unresolved questions). The rules in `schemas/axo.leostera.dev/README.md` stay: adding an optional field, method or event is compatible; changing the meaning, requiredness or shape of one needs a new version and a negotiated path.

`protocolVersion` 1 and the `/v1` HTTP API (`axo.machine.*`, `axo.runtime.*`, `axo.state.*`) are described in `legacy.md` as retired. They are listed so the coverage test can tell retired identifiers from missing ones, and are not specified further.

### Schemas

Each surface gets one schema file. The existing files map like this:

| Today | AXP |
| --- | --- |
| `common.schema.json` | `common.schema.json` |
| `local-rpc.schema.json` | `local.schema.json` (adds `axo.peer.*`, `axo.session.prompt`, `axo.session.reopen`, `axo.session.share`, `axo.terminal.screen`/`write`) |
| `host-relay.schema.json`, `pairing.schema.json` | `host-link.schema.json` (adds `axo.host.sync`, `axo.host.session.*`, `axo.host.share.publish`, `axo.host.prepareUpgrade`) |
| — | `transport.schema.json` (`axo.transport.fragment`, `.discard`, `.ack`) |
| — | `client.schema.json` (`axo.client.*`) |
| `connections.schema.json` | `connections.schema.json` |
| `events.schema.json` | `events.schema.json` |
| — | `account-http.schema.json` (pairing, host metadata, Pi event history routes) |

`$id`s move from `https://schemas.axo.leostera.dev/v1/…` to `https://axp.leostera.dev/v1/…`, and the site serves each file at its `$id`. `$id`s are not on the wire, so this changes no message.

The Zod schemas in `packages/axo-api` remain the runtime validators in TypeScript; the JSON Schema is the reference, and the coverage test parses every fixture with both.

### Coverage test

`//axp:coverage_test` extracts every string literal that matches `axo.<segment>.<segment>…` from the bindings and from axod, AxoClient, pi-axo and the API Worker, and fails if one is neither a method or event in a schema nor listed as retired in `legacy.md`. It also fails if a schema method has no call fixture, or a method with a result has no result fixture. The extraction is deliberately dumb (a regex over sources); a false positive is fixed by adding an entry to an explicit list of non-method strings (`axo.leostera.dev`, `axo.pid`, …) in the test.

### Bindings

The bindings move under `axp/bindings/` and get the protocol's name:

- **Rust:** `crates/axo-protocol` becomes `axp/bindings/rust`, crate `axp`. Callers change `axo_protocol::` to `axp::`. The wire types now in `crates/axo-relay` (sync, fragments, peers, pi3) move into it; axo-relay keeps the connection logic.
- **Swift:** `apple/AxoProtocol` becomes `axp/bindings/swift`, module `AXP`. The wire models in `apple/AxoClient/Sources/AxoClient/Remote` (`Fragments.swift`, the hello and session records) move into it. `apple/Package.swift` and the Xcode project generation point at the new path.
- **TypeScript:** the wire parts of `packages/axo-api` (`v1.ts`, `session-sync.ts`, `fragments.ts`, `pi3.ts`, `connections.ts`, `pairing.ts`, `share.ts`, `identity.ts`) become `@axo/axp` at `axp/bindings/typescript`. `packages/axo-api` keeps the JSON-RPC client and server helpers and re-exports nothing; callers import `@axo/axp`. The legacy contracts (`contracts.ts`, `state-contracts.ts`, `runtime-contracts.ts`) stay in `packages/axo-api-worker` with the legacy `/v1` routes, or are deleted with them.

This is a clean cutover: no re-exports from the old names, every caller is changed in the same commit as its binding moves.

### The site

`sites/axp.leostera.dev` is a Vite build deployed with Workers Static Assets, configured like `sites/axo.leostera.dev/cloudflare.config.ts` but with no Worker code and no bindings:

- `/` the overview; `/<surface>` each spec page rendered from `axp/spec/*.md`;
- `/<surface>#<method>` each method with its params, result, errors and fixtures, generated from the schema;
- `/v1/<file>.schema.json` the raw schemas, at their `$id`s, `content-type: application/schema+json`;
- `/models` the Feynman models rendered as their diagrams, next to an interactive playground like `docs/explainers/remote-access`.

Bazel builds it (`bazel build //sites/axp.leostera.dev:site`) from `//axp:spec` and `//axp:schemas`, so the site cannot show a schema that the tests did not check. `bazel run //:publish` is extended to deploy it, with the same clean-checkout checks it applies to the Mac app.

## Rollout

Each phase is one change that leaves main green.

1. **Spec and site.** Create `axp/` with the README, the spec pages for the surfaces that have schemas, move `schemas/axo.leostera.dev/v1` to `axp/schemas/v1` and `fixtures`, update the references (`crates/axo-protocol`, `crates/axo-relay`, `packages/axo-api` BUILD files, RFD0017), and add `sites/axp.leostera.dev`. Deploy it.
2. **The missing surfaces.** Write `client.md`, `transport.md`, the sync half of `host-link.md`, the peers half of `local.md`, their schemas and fixtures, from the code and RFD0016/18/19/22/24. Add the coverage test, with the gaps it still finds listed as known.
3. **Bindings.** Move Rust, then TypeScript, then Swift under `axp/bindings/`, one change each, and run every binding against every fixture.
4. **Models.** Move the Feynman specs that model the protocol (`session-sync`, `client-delivery`, `relay-fragments`, `remote-sessions`, `planned-restart`) to `axp/models/`, and render them on the site.
5. **Close the gaps.** Empty the coverage test's known-gaps list.

## Testing

- `bazel test //axp/...` runs the schema check (every schema is valid, every fixture is valid against its schema), the coverage test, and each binding's conformance test.
- The site's test builds it and checks that every schema `$id` is served at its URL with the right content type, and that every method in a schema has an anchor.
- Phases 1, 3 and 4 change no wire bytes; `bazel test //...` passing before and after, including the axod, API Worker and AxoClient suites, is the check.

## Drawbacks

- **Churn.** Moving three bindings touches most crates, packages and Apple targets, and every open branch (`feat/apps-gmail`, `exp/computer-cua`) has to rebase over the moves.
- **A name that does not match the wire.** Methods are called `axo.*` in a protocol called AXP. Until a v3 there is no fixing that without breaking installed apps.
- **More to keep up.** A method now needs prose, a schema and fixtures before it lands. That is the point, but it makes small protocol changes slower.
- **A public spec.** Publishing it invites the idea that the protocol is stable for outsiders. The site must say plainly that it is a working protocol, versioned, and changes when Axo needs it to.

## Rationale and alternatives

- **Do nothing.** The protocol keeps working, and stays readable only to someone who knows where all five places are. Every RFD that touches it keeps adding prose to itself instead of to a spec.
- **Spec only, bindings stay put.** Do phases 1, 2 and 4, and leave the bindings where they are. Much cheaper, and it gets most of the value: one spec, one coverage test. It leaves the protocol spread over the tree and named three ways. A reasonable first stop, and the rollout allows stopping there.
- **Generate the bindings.** Fewer handwritten types, but the Rust and Swift types parse into domain types (positive IDs, valid layouts) that generators produce poorly, and we would trade drift between bindings for drift between generator output and what we want.
- **Rename the wire to `axp.*` now**, accepting both names during a transition. Every peer would carry two names for every method until every phone and Mac updated. Not worth it for a name.
- **Keep it under `schemas/`.** The directory name says JSON Schema, which is the smallest part of the protocol.

## Unresolved questions

Before acceptance:

- Do we move the bindings (phase 3) or stop after the spec, site and coverage test?
- Does the schema directory stay `v1` while `protocolVersion` is 2, or do we rename it `v2` during the move, since no `$id` is on the wire?
- Is `@axo/axp` the right package name, or `@axp/protocol` so the protocol carries no product name?

During implementation:

- Which of the TypeScript legacy contracts are still reachable, and can they be deleted with the `/v1` routes instead of moved?
- How much of the Account HTTP surface belongs in AXP, given that sign-in is OAuth and specified in RFD0013/RFD0020?

Out of scope:

- Whether and when to rename wire identifiers to `axp.*`, in a future protocol version.

## Future possibilities

- A conformance kit: the fixtures and a script that drives a host or a client, so another host provider (`hostKind` other than `mac`) can check itself against AXP.
- A `v3` that renames methods to `axp.*`, merges `axo.remote.*` into the client surface, and drops the long-poll local events in favour of the subscription the client socket uses.
- Generated reference pages for limits (`SYNC`, `FRAGMENTS`, `LIMITS`) from the bindings, so the site and the code cannot disagree on a number.
