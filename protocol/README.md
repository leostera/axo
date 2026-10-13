# @axo/protocol

`@axo/protocol` contains the shared TypeScript and Swift contracts for Axod's addressed API. It is private, built as ESM with generated declarations, and is not published to npm. The TypeScript client/server interfaces use [`json-rpc-2.0`](https://www.npmjs.com/package/json-rpc-2.0); domain schemas and boundary validation remain explicit.

The authority contract is [Accepted RFD0012](../docs/rfds/RFD0012-sqlite-desired-state-and-session-materialization.md). Axod owns desired work, runtime materialization, Pi admission, and submitted-operation originals. Native clients read revision- and source-fenced views and send addressed mutations. There is no second client-owned catalog or legacy work/chat RPC fallback.

## Source layout

- [`src/contracts.ts`](src/contracts.ts): shared envelope, machine/runtime, central-state methods, results, and limits.
- [`src/state-contracts.ts`](src/state-contracts.ts): closed central catalog, operation, observation, input, history, and tool-output schemas.
- [`src/pi-history.ts`](src/pi-history.ts): bounded Pi-owned history projection shared by central history contracts.
- [`src/rpc.ts`](src/rpc.ts): typed method interfaces and bounded JSON-RPC message adapter.
- [`Sources/AxoProtocol/Central*.swift`](Sources/AxoProtocol): native central requests, captured targets, and result parsing.
- [`schemas.json`](schemas.json): generated language-neutral envelope, parameter, and result schemas.
- [`fixtures/envelopes.json`](fixtures/envelopes.json): shared codec cases used by Rust and TypeScript.

From the repository root:

```sh
npm --prefix protocol ci
npm --prefix protocol test
npm --prefix protocol run schema:check
swift test --package-path protocol
```

Run `cd protocol && npx tsx generate-schema.ts` to regenerate JSON Schema. The test and schema-check scripts reject drift. The private API and Axod integration lanes live in [`sites/api.axo.leostera.dev`](../sites/api.axo.leostera.dev/README.md) and [`axod/tests`](../axod/tests/README.md).

## Addressed central contract

Remote discovery and read methods include:

| Method | Purpose |
| --- | --- |
| `axo.state.get` | Negotiate the current central store generation and schema. |
| `axo.state.workspace.list`, `axo.state.session.list`, `axo.state.session.get` | Read desired records and bounded materialized observations using exact store/host targets. |
| `axo.state.chat.observe`, `axo.state.chat.get` | Observe Pi admission and read the exact current live binding; neither starts Pi. |
| `axo.state.chat.history`, `axo.state.chat.tool.get` | Read bounded live/stopped canonical history and exact tool output with source/head-bound cursors. |
| `axo.state.chat.command.get` | Reconcile a frozen submitted-input capture read-only. |
| `axo.state.operation.get` | Observe the original of an addressed desired-state operation. |

The mutation set uses one-operation graph creation, revision-captured Rename/lifecycle/pane changes, and frozen Pi-input captures. Only local callers may select a filesystem path for initial workspace creation. The exact current contract and role partition are the exported `remoteMethods`, `localMethods`, `results`, and `stateMutationMethods` in [`src/contracts.ts`](src/contracts.ts).

Each target carries the machine/host and current store generation as appropriate. Cursors are bound to source, revision, domain, and exact continuation. Read/refresh/disconnect does not mutate work. Missing runtime or a transport error is not evidence of completion or safe retry. Only an exact immutable original acknowledges a mutation; uncertain submitted input is never replayed or retargeted.

The obsolete `axo.workspace.*`, `axo.session.*`, `axo.command.get`, and `axo.chat.*` work/Pi wrappers and their duplicate result models have been removed from this package. There are no compatibility aliases for those method names. Public runtime/host transport methods remain distinct from central session lifecycle and do not replace central desired-state operations.

## Native API

The Swift package exposes transport types, closed `CentralRequest` values, central source/revision identities, parsers, and bounded volatile command captures. Codable model shapes are supplemented by strict validators; decoding alone is not domain validation. `CentralRequest` binds method parameters and result parsing to the same captured target, so callers cannot silently validate a reply against a later selection.

The native Mac coordinator now reads central catalogs, creates complete central graphs, and consumes central Pi observations/history. The displayed conversation editor and full primary-phone conversation cutover remain unfinished; shared contracts and parser tests are not rendered UI or end-to-end client acceptance.

## Transport boundaries

The API forwards addressed calls; it is not an executor or durable session authority. JSON-RPC transport IDs correlate one exchange and are not durable command IDs. A missing reply after forwarding is outcome-unknown. Reconnect does not replay work. The service's durable hop correlation is separate from Axod's durable original operation/input record.

Control frames are bounded to 65,536 encoded UTF-8 bytes and batches to eight calls. Mutation notifications do not execute. Errors, diagnostics, and result validation do not expose prompt bodies, credentials, canonical paths, or raw upstream exceptions. Local discovery is a boot-fenced endpoint descriptor, not a credential; loopback access is not authentication against other local users/processes.

The existing Access-protected API is a cloud edge gate, not application account storage. API deployment, installed-helper activation, physical-device installation, and stronger crash/VT recovery are separate authorization and acceptance gates.
